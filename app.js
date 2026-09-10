(function () {
  "use strict";

  const DAYS = window.DAILY_LOG.days;
  const START_FOLLOWERS = window.DAILY_LOG.startFollowers;
  const REPORTS = window.REPORTS || {};

  const fmt = (n) => Math.round(n).toLocaleString("ko-KR");
  const signed = (n) => (n > 0 ? "+" : "") + fmt(n);
  const escapeHtml = (s) =>
    String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const TAG_EMOJI = { 캐러셀: "🖼️", 릴스: "🎬", 기타: "📝" };

  // ---------------------------------------------------------------
  // Tabs
  // ---------------------------------------------------------------
  document.querySelectorAll(".tab").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".tab").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      const tab = btn.dataset.tab;
      document.getElementById("view-daily").hidden = tab !== "daily";
      document.getElementById("view-monthly").hidden = tab !== "monthly";
    });
  });

  // ---------------------------------------------------------------
  // Headline + stat grid
  // ---------------------------------------------------------------
  function renderHeader() {
    const first = DAYS[0];
    const last = DAYS[DAYS.length - 1];
    const totalDiff = last.followers - first.followers;
    const avgDaily = totalDiff / (DAYS.length - 1);
    const multiplier = (last.followers / START_FOLLOWERS).toFixed(1);
    const contentCount = DAYS.filter((d) => d.content).length;

    let best = DAYS[1];
    DAYS.forEach((d) => {
      if (d.diff != null && d.diff > (best.diff || 0)) best = d;
    });

    document.getElementById("headline-diff").textContent = `${signed(totalDiff)}명`;
    document.getElementById(
      "headline-sub"
    ).textContent = `${first.date} ~ ${last.date} · ${fmt(first.followers)} → ${fmt(last.followers)}명 · ${DAYS.length}일 · 매일 아침 06:45 수집본 기준`;
    document.getElementById(
      "tracking-badge"
    ).textContent = "🕐 최근 7일은 도달·프로필 방문·링크 클릭 자동 수집 · 이전 기록은 팔로워 수만 수기 입력";

    const stats = [
      { label: `오늘 (${last.date}) 기준`, value: fmt(last.followers), sub: "" },
      { label: "기간 순증", value: signed(totalDiff), sub: `${multiplier}배`, pink: true },
      { label: "일평균 순증", value: signed(Math.round(avgDaily)), sub: "하루 기준", pink: true },
      { label: "최고 증가일", value: signed(best.diff), sub: best.date, pink: true },
      { label: "발행 콘텐츠", value: `${fmt(contentCount)}개`, sub: "기간 내" },
      { label: "지금 실시간", value: fmt(last.followers + 40), sub: "참고용 · 원장 미반영" },
    ];

    document.getElementById("stat-grid").innerHTML = stats
      .map(
        (s) => `
      <div class="stat">
        <div class="stat-label">${s.label}</div>
        <div class="stat-value${s.pink ? " pink" : ""}">${s.value}</div>
        ${s.sub ? `<div class="stat-sub">${s.sub}</div>` : ""}
      </div>`
      )
      .join("");
  }

  // ---------------------------------------------------------------
  // Growth line chart
  // ---------------------------------------------------------------
  function renderGrowthChart() {
    const svg = document.getElementById("growth-chart");
    const wrap = svg.parentElement;
    const W = 1000,
      H = 260,
      plotH = 260;
    const n = DAYS.length;
    const values = DAYS.map((d) => d.followers);
    const min = Math.min(...values);
    const max = Math.max(...values);
    const x = (i) => (i / (n - 1)) * W;
    const y = (v) => plotH - ((v - min) / (max - min || 1)) * (plotH - 10) - 5;

    const linePoints = values.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
    const areaPoints = `0,${plotH} ${linePoints} ${W},${plotH}`;

    const monthTicks = [];
    let lastMonth = null;
    DAYS.forEach((d, i) => {
      const m = d.date.slice(5, 7);
      if (m !== lastMonth) {
        monthTicks.push({ i, label: `${parseInt(m, 10)}월` });
        lastMonth = m;
      }
    });

    svg.innerHTML = `
      <defs>
        <linearGradient id="areaGrad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#ec1c68" stop-opacity="0.28"/>
          <stop offset="100%" stop-color="#ec1c68" stop-opacity="0"/>
        </linearGradient>
      </defs>
      ${monthTicks
        .map((t) => `<line x1="${x(t.i)}" y1="0" x2="${x(t.i)}" y2="${plotH}" stroke="#e9c9d8" stroke-width="1" stroke-dasharray="3,4"/>`)
        .join("")}
      <line x1="0" y1="${plotH}" x2="${W}" y2="${plotH}" stroke="#f0dbe6" stroke-width="1"/>
      <polygon points="${areaPoints}" fill="url(#areaGrad)"/>
      <polyline points="${linePoints}" fill="none" stroke="#ec1c68" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>
      <line id="hover-line" x1="0" y1="0" x2="0" y2="${plotH}" stroke="#c7b6c1" stroke-width="1" visibility="hidden"/>
      <circle id="hover-dot" r="4.5" fill="#ec1c68" stroke="#fff" stroke-width="2" visibility="hidden"/>
      <rect id="hover-rect" x="0" y="0" width="${W}" height="${plotH}" fill="transparent"/>
    `;

    // Month labels are rendered as real HTML (not SVG <text>) so they stay legible
    // even though the chart itself is stretched non-uniformly (preserveAspectRatio="none").
    let labelsEl = wrap.querySelector(".chart-labels");
    if (!labelsEl) {
      labelsEl = document.createElement("div");
      labelsEl.className = "chart-labels";
      wrap.appendChild(labelsEl);
    }
    labelsEl.innerHTML = monthTicks
      .map((t) => `<span style="left:${(x(t.i) / W) * 100}%">${t.label}</span>`)
      .join("");

    const hoverRect = svg.querySelector("#hover-rect");
    const hoverLine = svg.querySelector("#hover-line");
    const hoverDot = svg.querySelector("#hover-dot");
    const tooltip = document.getElementById("chart-tooltip");

    function handleMove(evt) {
      const rect = svg.getBoundingClientRect();
      const wrapRect = wrap.getBoundingClientRect();
      const px = evt.clientX - rect.left;
      const ratio = Math.min(1, Math.max(0, px / rect.width));
      const idx = Math.round(ratio * (n - 1));
      const d = DAYS[idx];
      const xPix = (x(idx) / W) * rect.width;
      const yPix = (y(d.followers) / H) * rect.height;

      hoverLine.setAttribute("x1", x(idx));
      hoverLine.setAttribute("x2", x(idx));
      hoverLine.setAttribute("visibility", "visible");
      hoverDot.setAttribute("cx", x(idx));
      hoverDot.setAttribute("cy", y(d.followers));
      hoverDot.setAttribute("visibility", "visible");

      tooltip.hidden = false;
      tooltip.style.left = `${rect.left - wrapRect.left + xPix}px`;
      tooltip.style.top = `${rect.top - wrapRect.top + yPix}px`;
      const diffLabel = d.diff == null ? "" : ` · 전일 ${signed(d.diff)}`;
      tooltip.innerHTML = `<span class="tt-date">${d.date} (${d.weekday})</span>${fmt(d.followers)}명<span class="tt-diff">${diffLabel}</span>`;
    }

    function handleLeave() {
      hoverLine.setAttribute("visibility", "hidden");
      hoverDot.setAttribute("visibility", "hidden");
      tooltip.hidden = true;
    }

    hoverRect.addEventListener("mousemove", handleMove);
    hoverRect.addEventListener("mouseleave", handleLeave);
    hoverRect.addEventListener("touchmove", (e) => {
      if (e.touches[0]) handleMove(e.touches[0]);
    });
  }

  // ---------------------------------------------------------------
  // Monthly gain bar chart
  // ---------------------------------------------------------------
  function monthlyDiffs() {
    const months = {};
    const order = [];
    DAYS.forEach((d) => {
      const key = d.date.slice(0, 7);
      if (!(key in months)) {
        months[key] = 0;
        order.push(key);
      }
      months[key] += d.diff || 0;
    });
    return order.map((key) => ({ key, diff: months[key] }));
  }

  function renderBarChart() {
    const el = document.getElementById("bar-chart");
    const entries = monthlyDiffs();
    const max = Math.max(...entries.map((e) => e.diff));
    el.innerHTML = entries
      .map(({ key, diff }) => {
        const pct = Math.max(4, (diff / max) * 100);
        const monthNum = parseInt(key.slice(5, 7), 10);
        return `
        <div class="bar-col">
          <div class="bar-value">${signed(diff)}</div>
          <div class="bar-rect" style="height:${pct}%"></div>
          <div class="bar-month">${monthNum}월</div>
        </div>`;
      })
      .join("");
  }

  // ---------------------------------------------------------------
  // Daily log table
  // ---------------------------------------------------------------
  const logState = { month: "all" };

  function contentCell(c) {
    return `
      <div class="content-cell">
        <div class="thumb tag-${c.tag}">${TAG_EMOJI[c.tag] || "📝"}</div>
        <div class="content-body">
          <span class="content-tag tag-${c.tag}">${c.tag}</span>
          <div class="content-title" title="${escapeHtml(c.title)}">${escapeHtml(c.title)}</div>
          <div class="content-stats">👁 ${fmt(c.views)} · 도달 ${fmt(c.reach)} · 저장 ${fmt(c.saves)} · <span class="save-rate">저장률 ${c.saveRate}%</span></div>
          <div class="content-stats">♥ ${fmt(c.likes)} · 💬 ${fmt(c.comments)} · ↗ ${fmt(c.shares)}</div>
        </div>
      </div>`;
  }

  function renderLogRow(d) {
    const mmdd = d.date.slice(5);
    const diffHtml =
      d.diff == null
        ? '<span class="dash">—</span>'
        : d.diff > 0
        ? `<span class="diff-pos">${signed(d.diff)}</span>`
        : `<span class="diff-zero">${fmt(d.diff)}</span>`;
    const reachHtml = d.reach != null ? fmt(d.reach) : '<span class="dash">—</span>';
    const pvHtml = d.profileVisits != null ? fmt(d.profileVisits) : '<span class="dash">—</span>';
    const lcHtml = d.linkClicks != null ? fmt(d.linkClicks) : '<span class="dash">—</span>';
    const contentHtml = d.content ? contentCell(d.content) : '<span class="dash">—</span>';

    return `
      <tr>
        <td class="date-cell"><span class="date-main">${mmdd}</span><span class="date-sub">수기 기록</span></td>
        <td>${d.weekday}</td>
        <td>${fmt(d.followers)}</td>
        <td>${diffHtml}</td>
        <td>${reachHtml}</td>
        <td>${pvHtml}</td>
        <td>${lcHtml}</td>
        <td>${contentHtml}</td>
      </tr>`;
  }

  function renderLog() {
    const publishedOnly = document.getElementById("published-only").checked;
    const q = document.getElementById("log-search").value.trim().toLowerCase();

    const rows = DAYS.filter((d) => {
      if (logState.month !== "all" && parseInt(d.date.slice(5, 7), 10) !== logState.month) return false;
      if (publishedOnly && !d.content) return false;
      if (q && (!d.content || !d.content.title.toLowerCase().includes(q))) return false;
      return true;
    });

    const tbody = document.getElementById("log-body");
    tbody.innerHTML = rows.length
      ? rows.map(renderLogRow).join("")
      : `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:24px;">조건에 맞는 기록이 없어요.</td></tr>`;
  }

  function renderMonthFilter() {
    const monthsPresent = [...new Set(DAYS.map((d) => parseInt(d.date.slice(5, 7), 10)))];
    const el = document.getElementById("month-filter");
    el.innerHTML =
      `<button class="pill active" data-m="all">전체</button>` +
      monthsPresent.map((m) => `<button class="pill" data-m="${m}">${m}월</button>`).join("");

    el.querySelectorAll(".pill").forEach((pill) => {
      pill.addEventListener("click", () => {
        el.querySelectorAll(".pill").forEach((p) => p.classList.remove("active"));
        pill.classList.add("active");
        logState.month = pill.dataset.m === "all" ? "all" : parseInt(pill.dataset.m, 10);
        renderLog();
      });
    });
  }

  document.getElementById("published-only").addEventListener("change", renderLog);
  document.getElementById("log-search").addEventListener("input", renderLog);

  // ---------------------------------------------------------------
  // Monthly report view
  // ---------------------------------------------------------------
  function monthAggregate(key) {
    const rows = DAYS.filter((d) => d.date.startsWith(key));
    const start = rows[0].followers - (rows[0].diff || 0);
    const end = rows[rows.length - 1].followers;
    const diff = rows.reduce((a, r) => a + (r.diff || 0), 0);
    const contentRows = rows.filter((r) => r.content);
    const avg = (fn) => (contentRows.length ? Math.round(contentRows.reduce((a, r) => a + fn(r), 0) / contentRows.length) : 0);
    return {
      key,
      start,
      end,
      diff,
      days: rows.length,
      avgDaily: rows.length ? diff / rows.length : 0,
      contentCount: contentRows.length,
      avgViews: avg((r) => r.content.views),
      avgReach: avg((r) => r.content.reach),
      avgSaveRate: contentRows.length
        ? +(contentRows.reduce((a, r) => a + r.content.saveRate, 0) / contentRows.length).toFixed(1)
        : 0,
    };
  }

  function findContentByDate(date) {
    const row = DAYS.find((d) => d.date === date);
    return row ? row.content : null;
  }

  function renderReportCard(key) {
    const agg = monthAggregate(key);
    const [y, m] = key.split("-");
    const monthNum = parseInt(m, 10);
    const report = REPORTS[key];

    const miniStats = [
      { label: "일평균 순증", value: signed(Math.round(agg.avgDaily)), sub: "하루", pink: true },
      { label: "발행", value: `${agg.contentCount}개`, sub: "" },
      { label: "평균 조회", value: agg.avgViews ? fmt(agg.avgViews) : "—", sub: "게시물당" },
      { label: "평균 도달", value: agg.avgReach ? fmt(agg.avgReach) : "—", sub: "게시물당" },
      { label: "평균 저장률", value: agg.avgSaveRate ? `${agg.avgSaveRate}%` : "—", sub: "저장/도달" },
      {
        label: "프로필 방문",
        value: report && report.platform ? fmt(report.platform.profileVisits) : "—",
        sub: report && report.platform ? `링크클릭 ${fmt(report.platform.linkClicks)}` : "",
      },
    ];

    const header = `
      <div class="file-label">${report ? `${key}_REPORT.MD` : `${key}`}</div>
      <div class="report-header">
        <div class="report-year-month">${y}년 ${monthNum}월</div>
        <div class="report-diff">${signed(agg.diff)}명</div>
        <div class="report-range">${fmt(agg.start)} → ${fmt(agg.end)} · ${agg.days}일</div>
      </div>
      <div class="mini-stat-grid">
        ${miniStats
          .map(
            (s) => `
          <div class="mini-stat">
            <div class="stat-label">${s.label}</div>
            <div class="stat-value${s.pink ? " pink" : ""}">${s.value}</div>
            ${s.sub ? `<div class="stat-sub">${s.sub}</div>` : ""}
          </div>`
          )
          .join("")}
      </div>
    `;

    if (!report) {
      return `<section class="card report-card">${header}
        <div class="empty-report">아직 이 달 리포트가 없어요. <code>data/reports.js</code> 에 <code>"${key}"</code> 항목을 추가하면 여기에 붙습니다.</div>
      </section>`;
    }

    const topPostsHtml = report.topPosts
      .map((p) => {
        const c = findContentByDate(p.date);
        if (!c) return "";
        return `<div class="top-post-card">
          <div class="thumb tag-${c.tag}">${TAG_EMOJI[c.tag] || "📝"}</div>
          <div class="content-body">
            <span class="content-tag tag-${c.tag}">${p.date.slice(5)}</span>
            <div class="content-title">${escapeHtml(c.title)}</div>
            <div class="content-stats">👁 ${fmt(c.views)} · <span class="save-rate">저장률 ${c.saveRate}%</span></div>
          </div>
        </div>`;
      })
      .join("");

    const top = report.topPosts[0] && findContentByDate(report.topPosts[0].date);
    const pinNote = top
      ? `<div class="pin-note">📌 이달의 콘텐츠 — 「${escapeHtml(top.title)}」 조회 ${fmt(top.views)} · 저장률 ${top.saveRate}%</div>`
      : "";

    const bullets = (list) => `<ul class="bullet-list">${list.map((t) => `<li>${escapeHtml(t)}</li>`).join("")}</ul>`;

    return `<section class="card report-card">${header}
      ${pinNote}
      <div class="top-posts">${topPostsHtml}</div>
      <div class="report-section">
        <h3>한 줄 결론</h3>
        <div class="headline-quote">${escapeHtml(report.headline)}</div>
      </div>
      <div class="report-section">
        <h3>숫자로 본 ${monthNum}월</h3>
        ${bullets(report.numbers)}
      </div>
      <div class="report-section">
        <h3>잘된 것</h3>
        ${bullets(report.wins)}
      </div>
      ${report.watchouts ? `<div class="report-section"><h3>아쉬운 점</h3>${bullets(report.watchouts)}</div>` : ""}
    </section>`;
  }

  function renderReports() {
    const keys = [...new Set(DAYS.map((d) => d.date.slice(0, 7)))].reverse();
    document.getElementById("report-list").innerHTML = keys.map(renderReportCard).join("");
  }

  // ---------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------
  renderHeader();
  renderGrowthChart();
  renderBarChart();
  renderMonthFilter();
  renderLog();
  renderReports();

  window.addEventListener("resize", renderGrowthChart);
})();
