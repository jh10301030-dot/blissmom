import { db } from '../db.js';
import { config } from '../config.js';

function parsePost(row) {
  return { ...row, hashtags: row.hashtags ? JSON.parse(row.hashtags) : [] };
}

function latestMetricsByPost() {
  const rows = db
    .prepare(
      `SELECT pms.*
       FROM post_metric_snapshots pms
       INNER JOIN (
         SELECT post_id, MAX(captured_at) AS max_captured_at
         FROM post_metric_snapshots
         GROUP BY post_id
       ) latest ON latest.post_id = pms.post_id AND latest.max_captured_at = pms.captured_at`,
    )
    .all();
  return new Map(rows.map((row) => [row.post_id, row]));
}

function postsWithLatestMetrics() {
  const posts = db.prepare('SELECT * FROM posts ORDER BY posted_at DESC').all().map(parsePost);
  const latest = latestMetricsByPost();
  return posts
    .map((post) => ({ ...post, metrics: latest.get(post.id) || null }))
    .filter((post) => post.metrics);
}

// Composite score weights saves and shares heaviest since they signal
// stronger intent (bookmarking / passing along) than a passive view or like.
function compositeScore(m) {
  return m.views * 0.1 + m.reach * 0.1 + m.likes * 1 + m.comments * 2 + m.saves * 3 + m.shares * 4;
}

export function compareRecentPosts(limit = 5) {
  return postsWithLatestMetrics()
    .slice(0, limit)
    .map((post) => ({
      id: post.id,
      caption: post.caption,
      mediaType: post.media_type,
      permalink: post.permalink,
      postedAt: post.posted_at,
      views: post.metrics.views,
      reach: post.metrics.reach,
      saves: post.metrics.saves,
      shares: post.metrics.shares,
    }));
}

export function topPerformersThisWeek(limit = 3) {
  const weekAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const posts = postsWithLatestMetrics().filter((post) => new Date(post.posted_at).getTime() >= weekAgo);
  return posts
    .map((post) => ({
      id: post.id,
      caption: post.caption,
      mediaType: post.media_type,
      permalink: post.permalink,
      postedAt: post.posted_at,
      metrics: post.metrics,
      score: Math.round(compositeScore(post.metrics)),
    }))
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}

export function saveRateCommonality() {
  const posts = postsWithLatestMetrics().map((post) => ({
    ...post,
    saveRate: post.metrics.reach > 0 ? post.metrics.saves / post.metrics.reach : 0,
  }));
  if (posts.length === 0) {
    return { highSaveRatePosts: [], commonHashtags: [], averageCaptionLength: 0, mediaTypeBreakdown: {} };
  }

  const sorted = [...posts].sort((a, b) => b.saveRate - a.saveRate);
  const cutoffIndex = Math.max(1, Math.ceil(sorted.length / 2));
  const highGroup = sorted.slice(0, cutoffIndex);

  const hashtagCounts = new Map();
  const mediaTypeBreakdown = {};
  let captionLengthTotal = 0;
  const postingHours = [];

  for (const post of highGroup) {
    for (const tag of post.hashtags) {
      hashtagCounts.set(tag, (hashtagCounts.get(tag) || 0) + 1);
    }
    mediaTypeBreakdown[post.media_type] = (mediaTypeBreakdown[post.media_type] || 0) + 1;
    captionLengthTotal += (post.caption || '').length;
    postingHours.push(new Date(post.posted_at).getHours());
  }

  const commonHashtags = [...hashtagCounts.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5)
    .map(([tag, count]) => ({ tag, count }));

  const avgHour = postingHours.length
    ? Math.round(postingHours.reduce((a, b) => a + b, 0) / postingHours.length)
    : null;

  return {
    highSaveRatePosts: highGroup.map((p) => ({
      id: p.id,
      caption: p.caption,
      mediaType: p.media_type,
      saveRate: Number((p.saveRate * 100).toFixed(2)),
    })),
    commonHashtags,
    mediaTypeBreakdown,
    averageCaptionLength: Math.round(captionLengthTotal / highGroup.length),
    averagePostingHour: avgHour,
  };
}

export function detectViewSpikes(thresholdFraction = config.spikeThreshold) {
  const posts = db.prepare('SELECT * FROM posts').all().map(parsePost);
  const today = new Date().toISOString().slice(0, 10);

  const spikes = [];
  for (const post of posts) {
    const snapshots = db
      .prepare('SELECT * FROM post_metric_snapshots WHERE post_id = ? ORDER BY captured_at ASC')
      .all(post.id);
    if (snapshots.length < 2) continue;

    const latest = snapshots[snapshots.length - 1];
    const priorDaySnapshots = snapshots.filter((s) => s.captured_at.slice(0, 10) < today);
    const baseline = priorDaySnapshots.length
      ? priorDaySnapshots[priorDaySnapshots.length - 1]
      : snapshots[0];
    if (baseline.id === latest.id) continue;

    const baselineViews = Math.max(baseline.views, 1);
    const growth = (latest.views - baseline.views) / baselineViews;
    if (growth >= thresholdFraction) {
      spikes.push({
        id: post.id,
        caption: post.caption,
        permalink: post.permalink,
        baselineViews: baseline.views,
        latestViews: latest.views,
        growthPct: Math.round(growth * 1000) / 10,
        baselineDate: baseline.captured_at,
        comparedToYesterday: priorDaySnapshots.length > 0,
      });
    }
  }
  return spikes.sort((a, b) => b.growthPct - a.growthPct);
}

export function followerAndPublishingTimeline() {
  const followerRows = db
    .prepare(
      `SELECT date(captured_at) AS day, follower_count
       FROM follower_snapshots f
       WHERE captured_at = (
         SELECT MAX(captured_at) FROM follower_snapshots f2 WHERE date(f2.captured_at) = date(f.captured_at)
       )
       ORDER BY day ASC`,
    )
    .all();

  const publishRows = db
    .prepare(`SELECT date(posted_at) AS day, COUNT(*) AS count FROM posts GROUP BY day ORDER BY day ASC`)
    .all();

  return {
    followers: followerRows.map((r) => ({ date: r.day, followerCount: r.follower_count })),
    publishing: publishRows.map((r) => ({ date: r.day, postCount: r.count })),
  };
}

export function recommendNextTopics(limit = 3) {
  const posts = postsWithLatestMetrics().map((post) => ({
    ...post,
    score: compositeScore(post.metrics),
  }));
  if (posts.length === 0) return [];

  const sorted = [...posts].sort((a, b) => b.score - a.score);
  const topGroup = sorted.slice(0, Math.max(3, Math.ceil(sorted.length / 2)));

  const hashtagStats = new Map();
  for (const post of topGroup) {
    for (const tag of post.hashtags) {
      const entry = hashtagStats.get(tag) || { tag, totalScore: 0, count: 0, example: post };
      entry.totalScore += post.score;
      entry.count += 1;
      if (post.score > entry.example.score) entry.example = post;
      hashtagStats.set(tag, entry);
    }
  }

  const bestMediaType = Object.entries(
    topGroup.reduce((acc, p) => {
      acc[p.media_type] = (acc[p.media_type] || 0) + 1;
      return acc;
    }, {}),
  ).sort((a, b) => b[1] - a[1])[0]?.[0];

  return [...hashtagStats.values()]
    .sort((a, b) => b.totalScore / b.count - a.totalScore / a.count)
    .slice(0, limit)
    .map((entry, index) => ({
      rank: index + 1,
      topic: `#${entry.tag}`,
      reason: `최근 성과 상위 콘텐츠에서 ${entry.count}회 등장한 주제이며, 관련 게시물 평균 성과가 높습니다.`,
      exampleCaption: entry.example.caption.split('\n')[0],
      recommendedMediaType: bestMediaType,
    }));
}
