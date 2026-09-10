"""누적된 데이터(CSV/JSON)로 자기완결 대시보드 HTML을 생성한다.

- 외부 CDN/인터넷 없이 열리도록 CSS/JS를 모두 인라인으로 넣는다.
- 썸네일은 thumbs/<id>.jpg 상대경로로 참조한다 (별도 파일, 만료되는 서명 URL을 쓰지 않음).
- 결과 파일은 임시파일에 쓴 뒤 os.replace() 로 교체한다 (원자적 쓰기).

단독 실행: python build.py  (생성 후 기본 브라우저로 연다)
"""
from __future__ import annotations

import json
import sys
import webbrowser
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional

from common import (
    atomic_write_text,
    data_dir,
    load_json,
    log,
    project_dir,
    read_csv_rows,
    reports_dir,
    thumbs_dir,
)

WEEKDAY_KR = ["월", "화", "수", "목", "금", "토", "일"]
FORMAT_LABELS = {
    "REELS": "릴스",
    "CAROUSEL_ALBUM": "캐러셀",
    "VIDEO": "동영상",
    "IMAGE": "이미지",
}

DASHBOARD_FILE = "dashboard.html"


def _to_date(s: str) -> date:
    return date.fromisoformat(s)


def _num(v):
    if v in (None, ""):
        return None
    try:
        if isinstance(v, str) and "." not in v:
            return int(v)
        return float(v)
    except (TypeError, ValueError):
        return None


def build_effective_followers(follower_rows: list) -> dict:
    """official 기록을 기준으로 내부 공백만 선형 보간한다. 앞뒤 경계 밖은 보간하지 않는다."""
    known = []
    for r in follower_rows:
        v = _num(r.get("followers_count"))
        if v is None:
            continue
        known.append((_to_date(r["date"]), int(v)))
    known.sort(key=lambda t: t[0])

    effective: dict = {}
    for d, v in known:
        effective[d.isoformat()] = {"value": v, "source": "official"}

    for i in range(len(known) - 1):
        d0, v0 = known[i]
        d1, v1 = known[i + 1]
        gap = (d1 - d0).days
        if gap > 1:
            for step in range(1, gap):
                dd = d0 + timedelta(days=step)
                interp = v0 + (v1 - v0) * step / gap
                effective[dd.isoformat()] = {"value": round(interp), "source": "interpolated"}

    return effective


def media_format_label(m: dict) -> str:
    if m.get("media_product_type") == "REELS":
        return FORMAT_LABELS["REELS"]
    mt = m.get("media_type")
    return FORMAT_LABELS.get(mt, mt or "기타")


def caption_first_line(m: dict) -> str:
    cap = (m.get("caption") or "").strip()
    if not cap:
        return "(캡션 없음)"
    first = cap.splitlines()[0].strip()
    return first[:80] + ("…" if len(first) > 80 else "")


def build_posts_by_date(media_store: dict, insights_cache: dict, thumbs_dir_path: Path) -> dict:
    posts_by_date: dict = {}
    for mid, m in media_store.get("media", {}).items():
        ts = m.get("timestamp")
        if not ts:
            continue
        pub_date = ts[:10]
        ins = insights_cache.get(mid, {}).get("metrics", {})
        views = _num(ins.get("views"))
        reach = _num(ins.get("reach"))
        saved = _num(ins.get("saved"))
        save_rate = None
        base = views if views else reach
        if saved is not None and base:
            save_rate = round(saved / base * 100, 1)

        thumb_file = thumbs_dir_path / f"{mid}.jpg"
        post = {
            "id": mid,
            "date": pub_date,
            "title": caption_first_line(m),
            "permalink": m.get("permalink"),
            "thumb": f"thumbs/{mid}.jpg" if thumb_file.exists() else None,
            "format": media_format_label(m),
            "views": views,
            "reach": reach,
            "saved": saved,
            "save_rate": save_rate,
            "likes": _num(m.get("like_count")),
            "comments": _num(m.get("comments_count")),
        }
        posts_by_date.setdefault(pub_date, []).append(post)

    for lst in posts_by_date.values():
        lst.sort(key=lambda p: p["id"])
    return posts_by_date


def compute_kpi(days: list) -> dict:
    with_followers = [d for d in days if d["followers"] is not None]
    today_followers = with_followers[-1]["followers"] if with_followers else None

    period_net = None
    daily_avg_net = None
    if len(with_followers) >= 2:
        period_net = with_followers[-1]["followers"] - with_followers[0]["followers"]
        span_days = (
            _to_date(with_followers[-1]["date"]) - _to_date(with_followers[0]["date"])
        ).days
        if span_days > 0:
            daily_avg_net = round(period_net / span_days, 1)

    best_day = None
    best_delta = None
    for d in days:
        if d["delta_prev"] is not None:
            if best_delta is None or d["delta_prev"] > best_delta:
                best_delta = d["delta_prev"]
                best_day = d["date"]

    post_count = sum(len(d["posts"]) for d in days)

    return {
        "today_followers": today_followers,
        "period_net": period_net,
        "daily_avg_net": daily_avg_net,
        "best_day": best_day,
        "best_day_delta": best_delta,
        "post_count": post_count,
    }


def net_change_3days(effective: dict, pub_date_str: str) -> Optional[int]:
    d0 = _to_date(pub_date_str)
    d3 = d0 + timedelta(days=3)
    v0 = effective.get(d0.isoformat(), {}).get("value")
    v3 = effective.get(d3.isoformat(), {}).get("value")
    if v0 is None or v3 is None:
        return None
    return v3 - v0


def simple_markdown_to_html(md: str) -> str:
    """제목/굵게/목록/문단만 지원하는 최소 마크다운 변환기 (표준 라이브러리만 사용)."""
    import html as _html

    lines = md.splitlines()
    out = []
    in_list = False
    para: list = []

    def flush_para():
        nonlocal para
        if para:
            text = " ".join(para).strip()
            if text:
                out.append(f"<p>{_bold(text)}</p>")
            para = []

    def _bold(text: str) -> str:
        text = _html.escape(text)
        parts = text.split("**")
        res = ""
        for i, p in enumerate(parts):
            res += f"<strong>{p}</strong>" if i % 2 == 1 else p
        return res

    for raw in lines:
        line = raw.rstrip()
        if line.startswith("## "):
            flush_para()
            out.append(f"<h4>{_bold(line[3:])}</h4>")
        elif line.startswith("# "):
            flush_para()
            out.append(f"<h3>{_bold(line[2:])}</h3>")
        elif line.startswith("- ") or line.startswith("* "):
            if not in_list:
                flush_para()
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{_bold(line[2:])}</li>")
            continue
        elif not line.strip():
            if in_list:
                out.append("</ul>")
                in_list = False
            flush_para()
        else:
            if in_list:
                out.append("</ul>")
                in_list = False
            para.append(line.strip())

    if in_list:
        out.append("</ul>")
    flush_para()
    return "\n".join(out)


def build_bundle() -> dict:
    ddir = data_dir()
    follower_rows = read_csv_rows(ddir / "daily_followers.csv")
    account_rows = {r["date"]: r for r in read_csv_rows(ddir / "daily_account_metrics.csv")}
    media_store = load_json(ddir / "media.json", {"media": {}})
    insights_cache = load_json(ddir / "media_insights_cache.json", {})
    latest_ref = load_json(ddir / "latest_reference.json", None)

    effective = build_effective_followers(follower_rows)
    posts_by_date = build_posts_by_date(media_store, insights_cache, thumbs_dir())

    if effective:
        start = min(_to_date(k) for k in effective.keys())
        end = max(date.today(), max(_to_date(k) for k in effective.keys()))
    else:
        start = end = date.today()

    days = []
    cur = start
    prev_followers = None
    while cur <= end:
        iso = cur.isoformat()
        eff = effective.get(iso)
        followers = eff["value"] if eff else None
        source = eff["source"] if eff else "missing"
        delta_prev = None
        if followers is not None and prev_followers is not None:
            delta_prev = followers - prev_followers
        if followers is not None:
            prev_followers = followers

        acc = account_rows.get(iso, {})
        posts = posts_by_date.get(iso, [])
        for p in posts:
            p["net_change_3d"] = net_change_3days(effective, iso)

        days.append(
            {
                "date": iso,
                "weekday": WEEKDAY_KR[cur.weekday()],
                "followers": followers,
                "follower_source": source,
                "delta_prev": delta_prev,
                "reach": _num(acc.get("reach")),
                "profile_views": _num(acc.get("profile_views")),
                "website_clicks": _num(acc.get("website_clicks")),
                "accounts_engaged": _num(acc.get("accounts_engaged")),
                "views": _num(acc.get("views")),
                "total_interactions": _num(acc.get("total_interactions")),
                "posts": posts,
            }
        )
        cur += timedelta(days=1)

    kpi_all = compute_kpi(days)

    months: dict = {}
    for d in days:
        mkey = d["date"][:7]
        months.setdefault(mkey, []).append(d)

    month_bundle = {}
    for mkey, mdays in sorted(months.items()):
        kpi = compute_kpi(mdays)

        format_stats: dict = {}
        month_posts = [p for d in mdays for p in d["posts"]]
        for p in month_posts:
            fs = format_stats.setdefault(
                p["format"],
                {"count": 0, "net3_list": [], "views_list": [], "reach_list": [], "rate_list": []},
            )
            fs["count"] += 1
            if p["net_change_3d"] is not None:
                fs["net3_list"].append(p["net_change_3d"])
            if p["views"] is not None:
                fs["views_list"].append(p["views"])
            if p["reach"] is not None:
                fs["reach_list"].append(p["reach"])
            if p["save_rate"] is not None:
                fs["rate_list"].append(p["save_rate"])

        format_summary = {}
        for fmt, fs in format_stats.items():
            def _avg(lst):
                return round(sum(lst) / len(lst), 1) if lst else None

            format_summary[fmt] = {
                "count": fs["count"],
                "avg_net_3d": _avg(fs["net3_list"]),
                "avg_views": _avg(fs["views_list"]),
                "avg_reach": _avg(fs["reach_list"]),
                "avg_save_rate": _avg(fs["rate_list"]),
            }

        top3 = sorted(
            month_posts,
            key=lambda p: (p["total_interactions"] if False else (p["views"] or 0) + (p["reach"] or 0) * 0),
            reverse=True,
        )
        # TOP3: 저장수+조회수 기준(총 인터랙션 지표를 못 받는 게시물 단위 대체 지표)
        top3 = sorted(
            month_posts,
            key=lambda p: ((p["saved"] or 0) + (p["views"] or 0)),
            reverse=True,
        )[:3]

        report_path = reports_dir() / f"{mkey}.md"
        report_html = None
        if report_path.exists():
            report_html = simple_markdown_to_html(report_path.read_text(encoding="utf-8"))

        month_bundle[mkey] = {
            "kpi": kpi,
            "format_summary": format_summary,
            "top3": top3,
            "report_html": report_html,
            "post_count": len(month_posts),
        }

    latest_official = max(
        (r["date"] for r in follower_rows if _num(r.get("followers_count")) is not None),
        default=None,
    )
    days_old = None
    if latest_official:
        days_old = (date.today() - _to_date(latest_official)).days

    return {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "days": days,
        "months": month_bundle,
        "kpi_all": kpi_all,
        "latest_official_date": latest_official,
        "days_old": days_old,
        "latest_reference": latest_ref,
    }


HTML_TEMPLATE = """<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<title>인스타그램 일별 대시보드</title>
<style>
:root{
  --bg:#f7f7fb; --card:#ffffff; --text:#1c1e26; --muted:#6b7280;
  --accent:#d6336c; --accent-soft:#fbe4ec; --border:#e6e6ee;
  --pos:#0f9960; --neg:#d64545; --gray:#9aa0ac;
}
*{box-sizing:border-box;}
body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;
  background:var(--bg);color:var(--text);}
.wrap{max-width:1100px;margin:0 auto;padding:20px 16px 60px;}
.staleness{background:#fff3cd;border:1px solid #ffe08a;color:#7a5b00;padding:10px 14px;border-radius:8px;
  margin-bottom:16px;font-size:14px;}
.tabs{display:flex;gap:8px;margin-bottom:18px;}
.tab-btn{padding:10px 18px;border-radius:10px;border:1px solid var(--border);background:var(--card);
  cursor:pointer;font-size:15px;font-weight:600;color:var(--muted);}
.tab-btn.active{background:var(--accent);color:#fff;border-color:var(--accent);}
.tab-panel{display:none;} .tab-panel.active{display:block;}
.kpi-row{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-bottom:18px;}
@media (max-width:800px){.kpi-row{grid-template-columns:repeat(2,1fr);}}
.kpi-card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:14px;}
.kpi-label{font-size:12px;color:var(--muted);margin-bottom:6px;}
.kpi-value{font-size:22px;font-weight:700;}
.kpi-sub{font-size:12px;color:var(--muted);margin-top:2px;}
.pos{color:var(--pos);} .neg{color:var(--neg);}
.panel{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:16px;margin-bottom:18px;}
.panel h3{margin:0 0 12px;font-size:15px;color:var(--muted);}
#tooltip{position:fixed;display:none;background:#1c1e26;color:#fff;padding:8px 10px;border-radius:8px;
  font-size:12px;pointer-events:none;z-index:50;max-width:240px;line-height:1.5;}
.controls{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-bottom:14px;}
.controls select,.controls input[type=text]{padding:7px 10px;border-radius:8px;border:1px solid var(--border);
  font-size:13px;}
.controls label{font-size:13px;color:var(--muted);display:flex;align-items:center;gap:5px;}
table{width:100%;border-collapse:collapse;font-size:13px;}
th,td{padding:8px 6px;border-bottom:1px solid var(--border);text-align:left;vertical-align:top;}
th{color:var(--muted);font-weight:600;font-size:12px;}
tr.interp td{color:var(--gray);}
.gray-dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--gray);margin-right:4px;}
.post-item{display:flex;gap:8px;margin-bottom:6px;align-items:flex-start;}
.post-thumb{width:48px;height:48px;border-radius:6px;object-fit:cover;background:#eee;flex-shrink:0;}
.post-thumb.missing{display:flex;align-items:center;justify-content:center;font-size:10px;color:var(--muted);}
.post-title{font-weight:600;font-size:12.5px;color:var(--accent);text-decoration:none;}
.post-title:hover{text-decoration:underline;}
.post-stats{font-size:11px;color:var(--muted);margin-top:2px;}
.month-card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:18px;margin-bottom:16px;}
.month-card h3{margin-top:0;}
.fmt-table{width:100%;font-size:12.5px;border-collapse:collapse;margin:8px 0;}
.fmt-table td,.fmt-table th{padding:5px 6px;border-bottom:1px solid var(--border);}
.top3{display:flex;gap:10px;flex-wrap:wrap;margin-top:8px;}
.top3 .post-item{width:200px;background:var(--accent-soft);padding:8px;border-radius:8px;}
.report-html{margin-top:14px;padding-top:14px;border-top:1px dashed var(--border);font-size:13.5px;}
.report-html h3,.report-html h4{margin:10px 0 6px;}
.no-report{color:var(--muted);font-size:13px;margin-top:10px;}
.footer-note{color:var(--muted);font-size:11.5px;margin-top:30px;text-align:center;}
</style>
</head>
<body>
<div class="wrap">
  <div id="staleness-banner"></div>
  <div class="tabs">
    <button class="tab-btn active" data-tab="daily">일별 지표</button>
    <button class="tab-btn" data-tab="monthly">월간 리포트</button>
  </div>

  <div id="tab-daily" class="tab-panel active">
    <div class="kpi-row" id="kpi-row"></div>
    <div class="panel">
      <h3>팔로워 성장 곡선</h3>
      <div id="growth-chart"></div>
    </div>
    <div class="panel">
      <h3>월별 순증 (클릭하면 그 달만 필터)</h3>
      <div id="monthly-bars"></div>
    </div>
    <div class="panel">
      <div class="controls">
        <select id="month-filter"><option value="">전체 월</option></select>
        <label><input type="checkbox" id="posts-only-toggle"> 발행일만</label>
        <input type="text" id="search-box" placeholder="콘텐츠 검색...">
      </div>
      <div style="overflow-x:auto;">
      <table id="daily-table">
        <thead><tr>
          <th>날짜</th><th>요일</th><th>팔로워</th><th>전일대비</th><th>도달</th>
          <th>프로필방문</th><th>링크클릭</th><th>콘텐츠</th>
        </tr></thead>
        <tbody id="daily-table-body"></tbody>
      </table>
      </div>
    </div>
  </div>

  <div id="tab-monthly" class="tab-panel">
    <div id="monthly-reports"></div>
  </div>

  <div class="footer-note">생성 시각: __GENERATED_AT__</div>
</div>
<div id="tooltip"></div>
<script id="dashboard-data" type="application/json">__DATA_JSON__</script>
<script>
(function(){
  "use strict";
  var DATA = JSON.parse(document.getElementById("dashboard-data").textContent);
  var state = { month: "", postsOnly: false, query: "" };

  function fmtNum(n){
    if(n===null||n===undefined) return "-";
    return Math.round(n).toLocaleString("ko-KR");
  }
  function fmtDelta(n){
    if(n===null||n===undefined) return "-";
    var s = Math.round(n).toLocaleString("ko-KR");
    if(n>0) return '<span class="pos">+'+s+'</span>';
    if(n<0) return '<span class="neg">'+s+'</span>';
    return s;
  }

  // ---- 탭 ----
  document.querySelectorAll(".tab-btn").forEach(function(btn){
    btn.addEventListener("click", function(){
      document.querySelectorAll(".tab-btn").forEach(function(b){b.classList.remove("active");});
      document.querySelectorAll(".tab-panel").forEach(function(p){p.classList.remove("active");});
      btn.classList.add("active");
      document.getElementById("tab-"+btn.dataset.tab).classList.add("active");
    });
  });

  // ---- 오래된 데이터 경고 ----
  (function(){
    var banner = document.getElementById("staleness-banner");
    if(DATA.days_old && DATA.days_old > 0){
      banner.innerHTML = '<div class="staleness">⚠️ 이 화면은 '+DATA.days_old+'일 전 기준 데이터입니다 (마지막 공식 기록: '+DATA.latest_official_date+'). fetch.py 를 실행해 최신화하세요.</div>';
    } else if(!DATA.latest_official_date){
      banner.innerHTML = '<div class="staleness">⚠️ 아직 공식 기록된 팔로워 데이터가 없습니다. fetch.py 를 먼저 실행하세요.</div>';
    }
  })();

  function monthKeys(){
    return Object.keys(DATA.months).sort();
  }

  // ---- 월 필터 select 채우기 ----
  (function(){
    var sel = document.getElementById("month-filter");
    monthKeys().slice().reverse().forEach(function(m){
      var opt = document.createElement("option");
      opt.value = m; opt.textContent = m;
      sel.appendChild(opt);
    });
    sel.addEventListener("change", function(){ state.month = sel.value; renderAll(); });
  })();
  document.getElementById("posts-only-toggle").addEventListener("change", function(e){
    state.postsOnly = e.target.checked; renderAll();
  });
  document.getElementById("search-box").addEventListener("input", function(e){
    state.query = e.target.value.trim().toLowerCase(); renderAll();
  });

  function filteredDays(){
    return DATA.days.filter(function(d){
      if(state.month && d.date.slice(0,7) !== state.month) return false;
      if(state.postsOnly && d.posts.length===0) return false;
      if(state.query){
        var hit = d.posts.some(function(p){ return p.title.toLowerCase().indexOf(state.query) >= 0; });
        if(!hit) return false;
      }
      return true;
    });
  }

  // ---- KPI ----
  function renderKPI(){
    var kpi = state.month && DATA.months[state.month] ? DATA.months[state.month].kpi : DATA.kpi_all;
    var row = document.getElementById("kpi-row");
    var cards = [
      ["오늘 팔로워", fmtNum(kpi.today_followers), ""],
      ["기간 순증", fmtDelta(kpi.period_net), ""],
      ["일평균 순증", kpi.daily_avg_net===null?"-":(kpi.daily_avg_net>0?"+":"")+kpi.daily_avg_net, ""],
      ["최고 증가일", kpi.best_day ? kpi.best_day+" ("+fmtDelta(kpi.best_day_delta)+")" : "-", ""],
      ["발행 수", fmtNum(kpi.post_count)+"건", ""]
    ];
    row.innerHTML = cards.map(function(c){
      return '<div class="kpi-card"><div class="kpi-label">'+c[0]+'</div><div class="kpi-value">'+c[1]+'</div></div>';
    }).join("");
  }

  // ---- 성장 곡선 SVG ----
  function renderGrowthChart(){
    var days = DATA.days.filter(function(d){ return d.followers!==null; });
    var host = document.getElementById("growth-chart");
    if(days.length < 2){ host.innerHTML = '<div style="color:#9aa0ac;font-size:13px;">표시할 데이터가 부족합니다 (최소 2일치 필요)</div>'; return; }
    var W = 1000, H = 220, pad = 30;
    var vals = days.map(function(d){return d.followers;});
    var min = Math.min.apply(null, vals), max = Math.max.apply(null, vals);
    if(min===max){ min -= 1; max += 1; }
    function x(i){ return pad + (W-2*pad) * i/(days.length-1); }
    function y(v){ return H-pad - (H-2*pad) * (v-min)/(max-min); }

    var pathParts = [];
    var circles = [];
    days.forEach(function(d,i){
      var px = x(i), py = y(d.followers);
      pathParts.push((i===0?"M":"L") + px.toFixed(1) + "," + py.toFixed(1));
      var interp = d.follower_source === "interpolated";
      circles.push('<circle data-i="'+i+'" cx="'+px.toFixed(1)+'" cy="'+py.toFixed(1)+'" r="'+(interp?3:4)+'" '+
        'fill="'+(interp?"#9aa0ac":"#d6336c")+'" stroke="#fff" stroke-width="1" style="cursor:pointer;"></circle>');
    });

    var svg = '<svg viewBox="0 0 '+W+' '+H+'" style="width:100%;height:auto;display:block;" preserveAspectRatio="none">'+
      '<path d="'+pathParts.join(" ")+'" fill="none" stroke="#d6336c" stroke-width="2"></path>'+
      circles.join("")+
      '</svg>';
    host.innerHTML = svg;

    var tooltip = document.getElementById("tooltip");
    host.querySelectorAll("circle").forEach(function(c){
      c.addEventListener("mousemove", function(e){
        var d = days[parseInt(c.dataset.i,10)];
        var postsText = d.posts.length ? d.posts.map(function(p){return "· "+p.title;}).join("<br>") : "발행 콘텐츠 없음";
        var flag = d.follower_source==="interpolated" ? " (보간된 추정치)" : "";
        tooltip.innerHTML = "<b>"+d.date+" ("+d.weekday+")</b><br>팔로워 "+fmtNum(d.followers)+"명"+flag+"<br>"+postsText;
        tooltip.style.display = "block";
        tooltip.style.left = (e.clientX+14)+"px";
        tooltip.style.top = (e.clientY+14)+"px";
      });
      c.addEventListener("mouseleave", function(){ tooltip.style.display="none"; });
    });
  }

  // ---- 월별 순증 막대 ----
  function renderMonthlyBars(){
    var host = document.getElementById("monthly-bars");
    var keys = monthKeys();
    if(!keys.length){ host.innerHTML = '<div style="color:#9aa0ac;font-size:13px;">데이터 없음</div>'; return; }
    var nets = keys.map(function(m){ return DATA.months[m].kpi.period_net || 0; });
    var maxAbs = Math.max.apply(null, nets.map(Math.abs).concat([1]));
    var rows = keys.map(function(m,i){
      var net = nets[i];
      var widthPct = Math.abs(net)/maxAbs*100;
      var color = net>=0 ? "#0f9960" : "#d64545";
      var active = state.month===m ? "outline:2px solid #d6336c;" : "";
      return '<div class="month-bar" data-m="'+m+'" style="cursor:pointer;margin-bottom:6px;'+active+'border-radius:6px;padding:4px 6px;">'+
        '<div style="display:flex;justify-content:space-between;font-size:12px;color:#6b7280;margin-bottom:2px;">'+
        '<span>'+m+'</span><span>'+fmtDelta(net)+'</span></div>'+
        '<div style="background:#f0f0f5;border-radius:4px;height:10px;overflow:hidden;">'+
        '<div style="width:'+widthPct+'%;height:100%;background:'+color+';"></div></div></div>';
    }).join("");
    host.innerHTML = rows;
    host.querySelectorAll(".month-bar").forEach(function(el){
      el.addEventListener("click", function(){
        var m = el.dataset.m;
        state.month = state.month===m ? "" : m;
        document.getElementById("month-filter").value = state.month;
        renderAll();
      });
    });
  }

  // ---- 일별 표 ----
  function renderTable(){
    var tbody = document.getElementById("daily-table-body");
    var days = filteredDays();
    tbody.innerHTML = days.map(function(d){
      var interp = d.follower_source==="interpolated";
      var followersCell = (interp ? '<span class="gray-dot" title="보간된 추정치"></span>' : '') + fmtNum(d.followers);
      var postsHtml = d.posts.map(function(p){
        var thumb = p.thumb ? '<img class="post-thumb" src="'+p.thumb+'" loading="lazy">' : '<div class="post-thumb missing">no img</div>';
        var link = p.permalink ? '<a class="post-title" href="'+p.permalink+'" target="_blank" rel="noopener">'+p.title+'</a>' : '<span class="post-title">'+p.title+'</span>';
        var stats = '조회 '+fmtNum(p.views)+' · 저장 '+fmtNum(p.saved)+' ('+(p.save_rate!==null?p.save_rate+"%":"-")+') · 좋아요 '+fmtNum(p.likes)+' · 댓글 '+fmtNum(p.comments);
        return '<div class="post-item">'+thumb+'<div><div>'+link+'</div><div class="post-stats">'+stats+'</div></div></div>';
      }).join("") || '<span style="color:#9aa0ac;">-</span>';
      return '<tr class="'+(interp?"interp":"")+'">'+
        '<td>'+d.date+'</td><td>'+d.weekday+'</td><td>'+followersCell+'</td><td>'+fmtDelta(d.delta_prev)+'</td>'+
        '<td>'+fmtNum(d.reach)+'</td><td>'+fmtNum(d.profile_views)+'</td><td>'+fmtNum(d.website_clicks)+'</td>'+
        '<td>'+postsHtml+'</td></tr>';
    }).join("") || '<tr><td colspan="8" style="text-align:center;color:#9aa0ac;">표시할 데이터가 없습니다</td></tr>';
  }

  function renderAll(){ renderKPI(); renderMonthlyBars(); renderTable(); }
  renderGrowthChart();
  renderAll();

  // ---- 월간 리포트 탭 ----
  (function(){
    var host = document.getElementById("monthly-reports");
    var keys = monthKeys().slice().reverse();
    if(!keys.length){ host.innerHTML = '<div style="color:#9aa0ac;">데이터가 아직 없습니다.</div>'; return; }
    host.innerHTML = keys.map(function(m){
      var mm = DATA.months[m];
      var fmtRows = Object.keys(mm.format_summary).map(function(f){
        var s = mm.format_summary[f];
        return '<tr><td>'+f+'</td><td>'+s.count+'건</td><td>'+(s.avg_net_3d===null?"-":s.avg_net_3d)+'</td>'+
          '<td>'+(s.avg_views===null?"-":s.avg_views)+'</td><td>'+(s.avg_reach===null?"-":s.avg_reach)+'</td>'+
          '<td>'+(s.avg_save_rate===null?"-":s.avg_save_rate+"%")+'</td></tr>';
      }).join("");
      var top3 = mm.top3.map(function(p){
        var thumb = p.thumb ? '<img class="post-thumb" src="'+p.thumb+'" loading="lazy">' : '<div class="post-thumb missing">no img</div>';
        var link = p.permalink ? '<a class="post-title" href="'+p.permalink+'" target="_blank" rel="noopener">'+p.title+'</a>' : p.title;
        return '<div class="post-item">'+thumb+'<div><div>'+link+'</div><div class="post-stats">조회 '+fmtNum(p.views)+' · 저장 '+fmtNum(p.saved)+'</div></div></div>';
      }).join("");
      var reportBlock = mm.report_html ? '<div class="report-html">'+mm.report_html+'</div>' :
        '<div class="no-report">reports/'+m+'.md 파일을 만들면 이 자리에 분석·다음달 계획이 표시됩니다.</div>';
      return '<div class="month-card"><h3>'+m+'</h3>'+
        '<div class="kpi-row" style="grid-template-columns:repeat(4,1fr);">'+
        '<div class="kpi-card"><div class="kpi-label">순증</div><div class="kpi-value">'+fmtDelta(mm.kpi.period_net)+'</div></div>'+
        '<div class="kpi-card"><div class="kpi-label">일평균</div><div class="kpi-value">'+(mm.kpi.daily_avg_net===null?"-":mm.kpi.daily_avg_net)+'</div></div>'+
        '<div class="kpi-card"><div class="kpi-label">발행 수</div><div class="kpi-value">'+mm.post_count+'건</div></div>'+
        '<div class="kpi-card"><div class="kpi-label">최고 증가일</div><div class="kpi-value" style="font-size:14px;">'+(mm.kpi.best_day||"-")+'</div></div>'+
        '</div>'+
        (fmtRows ? '<table class="fmt-table"><thead><tr><th>포맷</th><th>건수</th><th>1건당 3일순증</th><th>평균조회</th><th>평균도달</th><th>평균저장률</th></tr></thead><tbody>'+fmtRows+'</tbody></table>' : '')+
        (top3 ? '<div><b style="font-size:13px;">TOP 3</b><div class="top3">'+top3+'</div></div>' : '')+
        reportBlock+
        '</div>';
    }).join("");
  })();
})();
</script>
</body>
</html>
"""


def render_html(bundle: dict) -> str:
    data_json = json.dumps(bundle, ensure_ascii=False).replace("</script>", "<\\/script>")
    html = HTML_TEMPLATE.replace("__DATA_JSON__", data_json)
    html = html.replace("__GENERATED_AT__", bundle["generated_at"])
    return html


def build(open_browser: bool = True) -> Path:
    bundle = build_bundle()
    html = render_html(bundle)
    out_path = project_dir() / DASHBOARD_FILE
    atomic_write_text(out_path, html)
    log(
        f"대시보드 생성 완료: {out_path} "
        f"(일수 {len(bundle['days'])}, 최근기록 {bundle['latest_official_date']})"
    )
    if open_browser:
        webbrowser.open(out_path.as_uri())
    return out_path


def main() -> int:
    build(open_browser=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
