#!/usr/bin/env python3
"""Fetch Instagram follower/engagement stats and post a daily report to Discord.

Required environment variables:
  IG_ACCESS_TOKEN     Instagram Graph API access token (long-lived, with
                       instagram_basic + instagram_manage_insights scopes).
  IG_USER_ID           Instagram Business/Creator account ID (numeric).
  DISCORD_WEBHOOK_URL   Discord channel Incoming Webhook URL.

Optional:
  GRAPH_API_VERSION    Defaults to "v21.0".

History of daily follower counts is kept in data/follower_history.json so
each run can compare against yesterday's snapshot.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HISTORY_PATH = os.path.join(REPO_ROOT, "data", "follower_history.json")
GRAPH_API_VERSION = os.environ.get("GRAPH_API_VERSION", "v21.0")
GRAPH_API_BASE = f"https://graph.facebook.com/{GRAPH_API_VERSION}"

TOP_POSTS_LIMIT = 3
COMMENTS_PER_POST = 3
RECENT_MEDIA_LIMIT = 25


def graph_get(path, params):
    query = urllib.parse.urlencode(params)
    url = f"{GRAPH_API_BASE}/{path}?{query}"
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Instagram Graph API error ({e.code}) for {path}: {body}") from e


def load_history():
    if not os.path.exists(HISTORY_PATH):
        return []
    with open(HISTORY_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def save_history(history):
    os.makedirs(os.path.dirname(HISTORY_PATH), exist_ok=True)
    with open(HISTORY_PATH, "w", encoding="utf-8") as f:
        json.dump(history, f, ensure_ascii=False, indent=2)
        f.write("\n")


def upsert_today(history, date_str, followers_count, now_iso):
    for entry in history:
        if entry["date"] == date_str:
            entry["followers_count"] = followers_count
            entry["timestamp"] = now_iso
            return history
    history.append({"date": date_str, "followers_count": followers_count, "timestamp": now_iso})
    history.sort(key=lambda e: e["date"])
    return history


def find_by_date(history, date_str):
    for entry in history:
        if entry["date"] == date_str:
            return entry
    return None


def fetch_account_stats(access_token, ig_user_id):
    return graph_get(ig_user_id, {"fields": "followers_count,username", "access_token": access_token})


def fetch_recent_media(access_token, ig_user_id, since_dt):
    data = graph_get(
        f"{ig_user_id}/media",
        {
            "fields": "id,caption,timestamp,like_count,comments_count,permalink,media_type",
            "limit": RECENT_MEDIA_LIMIT,
            "access_token": access_token,
        },
    )
    posts = []
    for item in data.get("data", []):
        ts = datetime.fromisoformat(item["timestamp"].replace("Z", "+00:00")).astimezone(KST)
        if ts >= since_dt:
            item["_timestamp_kst"] = ts
            posts.append(item)
    return posts


def fetch_top_comments(access_token, media_id, limit=COMMENTS_PER_POST):
    try:
        data = graph_get(
            f"{media_id}/comments",
            {"fields": "text,username,like_count", "limit": limit, "access_token": access_token},
        )
    except RuntimeError:
        return []
    return data.get("data", [])[:limit]


def build_discord_payload(username, today_str, followers_count, diff, recent_posts, access_token):
    if diff is None:
        follower_line = f"**{followers_count:,}명** (어제 데이터 없음 — 비교 불가)"
    else:
        sign = "+" if diff >= 0 else ""
        arrow = "🔼" if diff > 0 else ("🔽" if diff < 0 else "➡️")
        follower_line = f"**{followers_count:,}명** ({sign}{diff:,} {arrow})"

    total_likes = sum(p.get("like_count", 0) or 0 for p in recent_posts)
    total_comments = sum(p.get("comments_count", 0) or 0 for p in recent_posts)

    fields = [
        {"name": "팔로워 수", "value": follower_line, "inline": False},
        {
            "name": "최근 24시간 반응 요약",
            "value": f"새 게시물 {len(recent_posts)}건 · 좋아요 {total_likes:,} · 댓글 {total_comments:,}"
            if recent_posts
            else "최근 24시간 내 새 게시물 없음",
            "inline": False,
        },
    ]

    top_posts = sorted(
        recent_posts,
        key=lambda p: (p.get("like_count", 0) or 0) + (p.get("comments_count", 0) or 0),
        reverse=True,
    )[:TOP_POSTS_LIMIT]

    for post in top_posts:
        caption = (post.get("caption") or "").strip().replace("\n", " ")
        if len(caption) > 60:
            caption = caption[:57] + "..."
        comments = fetch_top_comments(access_token, post["id"])
        comment_lines = [f"> {c.get('username', '익명')}: {c.get('text', '')}" for c in comments]
        value = (
            f"좋아요 {post.get('like_count', 0):,} · 댓글 {post.get('comments_count', 0):,}\n"
            f"{post.get('permalink', '')}\n" + ("\n".join(comment_lines) if comment_lines else "_댓글 없음_")
        )
        fields.append({"name": f"📌 {caption or '(캡션 없음)'}", "value": value[:1024], "inline": False})

    embed = {
        "title": f"📊 {username or 'Instagram'} 팔로워 일일 리포트 ({today_str})",
        "color": 0xE1306C,
        "fields": fields,
    }
    return {"embeds": [embed]}


def post_to_discord(webhook_url, payload):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Discord webhook error ({e.code}): {body}") from e


def post_error_to_discord(webhook_url, message):
    try:
        post_to_discord(webhook_url, {"content": f"⚠️ 팔로워 리포트 생성 실패: {message}"})
    except Exception:
        pass


def main():
    access_token = os.environ.get("IG_ACCESS_TOKEN")
    ig_user_id = os.environ.get("IG_USER_ID")
    webhook_url = os.environ.get("DISCORD_WEBHOOK_URL")

    missing = [
        name
        for name, val in (
            ("IG_ACCESS_TOKEN", access_token),
            ("IG_USER_ID", ig_user_id),
            ("DISCORD_WEBHOOK_URL", webhook_url),
        )
        if not val
    ]
    if missing:
        print(f"Missing required environment variables: {', '.join(missing)}", file=sys.stderr)
        return 1

    now_kst = datetime.now(KST)
    today_str = now_kst.strftime("%Y-%m-%d")
    yesterday_str = (now_kst - timedelta(days=1)).strftime("%Y-%m-%d")
    since_dt = now_kst - timedelta(hours=24)

    history = load_history()
    yesterday_entry = find_by_date(history, yesterday_str)

    try:
        account = fetch_account_stats(access_token, ig_user_id)
        followers_count = account["followers_count"]
        username = account.get("username")
        recent_posts = fetch_recent_media(access_token, ig_user_id, since_dt)
    except Exception as e:
        post_error_to_discord(webhook_url, str(e))
        print(str(e), file=sys.stderr)
        return 1

    diff = followers_count - yesterday_entry["followers_count"] if yesterday_entry else None

    payload = build_discord_payload(username, today_str, followers_count, diff, recent_posts, access_token)

    try:
        post_to_discord(webhook_url, payload)
    except Exception as e:
        print(str(e), file=sys.stderr)
        return 1

    history = upsert_today(history, today_str, followers_count, now_kst.isoformat())
    save_history(history)
    print(f"Report sent. followers={followers_count} diff={diff}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
