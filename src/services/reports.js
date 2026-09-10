import { db } from '../db.js';
import {
  compareRecentPosts,
  topPerformersThisWeek,
  saveRateCommonality,
  detectViewSpikes,
  followerAndPublishingTimeline,
  recommendNextTopics,
} from './analytics.js';

const insertReport = db.prepare(`
  INSERT INTO reports (type, generated_at, payload)
  VALUES (@type, @generatedAt, @payload)
`);

function followerDelta() {
  const rows = db
    .prepare(
      `SELECT date(captured_at) AS day, MAX(captured_at) AS captured_at, follower_count
       FROM follower_snapshots GROUP BY day ORDER BY day DESC LIMIT 2`,
    )
    .all();
  const [latest, previous] = rows;
  return {
    followerCount: latest?.follower_count ?? 0,
    previousFollowerCount: previous?.follower_count ?? null,
    delta: latest && previous ? latest.follower_count - previous.follower_count : null,
  };
}

function shortCaption(caption) {
  return (caption || '').split('\n')[0];
}

export function generateDailyBrief() {
  const { followerCount, delta } = followerDelta();
  const recent = compareRecentPosts(5);
  const spikes = detectViewSpikes();
  const top = topPerformersThisWeek(1)[0] || null;

  const lines = [];
  lines.push(`팔로워 ${followerCount.toLocaleString()}명${delta != null ? ` (전일 대비 ${delta >= 0 ? '+' : ''}${delta})` : ''}`);
  if (top) {
    lines.push(`이번 주 최고 성과: "${shortCaption(top.caption)}" (조회 ${top.metrics.views.toLocaleString()}, 저장 ${top.metrics.saves.toLocaleString()})`);
  }
  if (spikes.length) {
    lines.push(`조회수 급상승 콘텐츠 ${spikes.length}건 감지: ${spikes.map((s) => `"${shortCaption(s.caption)}" (+${s.growthPct}%)`).join(', ')}`);
  } else {
    lines.push('오늘은 급상승한 콘텐츠가 없습니다.');
  }

  const payload = {
    generatedAt: new Date().toISOString(),
    followerCount,
    followerDelta: delta,
    recentPosts: recent,
    topPerformer: top,
    viewSpikes: spikes,
    summaryText: lines.join('\n'),
  };

  insertReport.run({ type: 'daily', generatedAt: payload.generatedAt, payload: JSON.stringify(payload) });
  return payload;
}

export function generateWeeklyReport() {
  const timeline = followerAndPublishingTimeline();
  const weekFollowers = timeline.followers.slice(-7);
  const followerGrowth =
    weekFollowers.length >= 2
      ? weekFollowers[weekFollowers.length - 1].followerCount - weekFollowers[0].followerCount
      : null;

  const top3 = topPerformersThisWeek(3);
  const saveRateInsights = saveRateCommonality();
  const recommendations = recommendNextTopics(3);
  const postsPublished = timeline.publishing
    .filter((p) => new Date(p.date).getTime() >= Date.now() - 7 * 24 * 60 * 60 * 1000)
    .reduce((sum, p) => sum + p.postCount, 0);

  const lines = [];
  lines.push(`지난 7일간 게시물 ${postsPublished}건 발행${followerGrowth != null ? `, 팔로워 ${followerGrowth >= 0 ? '+' : ''}${followerGrowth}명 증가` : ''}`);
  if (top3.length) {
    lines.push(`이번 주 TOP ${top3.length}: ${top3.map((p, i) => `${i + 1}) "${shortCaption(p.caption)}"`).join(', ')}`);
  }
  if (saveRateInsights.commonHashtags.length) {
    lines.push(`저장률 높은 콘텐츠 공통 해시태그: ${saveRateInsights.commonHashtags.map((h) => `#${h.tag}`).join(', ')}`);
  }
  if (recommendations.length) {
    lines.push(`다음 주 추천 주제: ${recommendations.map((r) => r.topic).join(', ')}`);
  }

  const payload = {
    generatedAt: new Date().toISOString(),
    periodStart: weekFollowers[0]?.date ?? null,
    periodEnd: weekFollowers[weekFollowers.length - 1]?.date ?? null,
    postsPublished,
    followerGrowth,
    topPerformers: top3,
    saveRateInsights,
    recommendations,
    timeline,
    summaryText: lines.join('\n'),
  };

  insertReport.run({ type: 'weekly', generatedAt: payload.generatedAt, payload: JSON.stringify(payload) });
  return payload;
}

export function getLatestReport(type) {
  const row = db
    .prepare('SELECT * FROM reports WHERE type = ? ORDER BY generated_at DESC LIMIT 1')
    .get(type);
  return row ? JSON.parse(row.payload) : null;
}

export function listReports(type, limit = 10) {
  const rows = db
    .prepare('SELECT * FROM reports WHERE type = ? ORDER BY generated_at DESC LIMIT ?')
    .all(type, limit);
  return rows.map((row) => JSON.parse(row.payload));
}
