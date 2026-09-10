import { db } from '../db.js';
import { config } from '../config.js';
import { instagramClient, extractHashtags } from '../instagram/client.js';
import { createMockClient } from '../instagram/mock.js';

const DAY_MS = 24 * 60 * 60 * 1000;

const upsertPost = db.prepare(`
  INSERT INTO posts (id, caption, media_type, permalink, posted_at, hashtags)
  VALUES (@id, @caption, @mediaType, @permalink, @postedAt, @hashtags)
  ON CONFLICT(id) DO UPDATE SET
    caption = excluded.caption,
    media_type = excluded.media_type,
    permalink = excluded.permalink,
    hashtags = excluded.hashtags
`);

const insertPostMetric = db.prepare(`
  INSERT INTO post_metric_snapshots (post_id, captured_at, views, reach, saves, shares, likes, comments)
  VALUES (@postId, @capturedAt, @views, @reach, @saves, @shares, @likes, @comments)
`);

const insertFollowerSnapshot = db.prepare(`
  INSERT INTO follower_snapshots (captured_at, follower_count)
  VALUES (@capturedAt, @followerCount)
`);

const persistTx = db.transaction((capturedAt, followerCount, posts) => {
  insertFollowerSnapshot.run({ capturedAt, followerCount });
  for (const post of posts) {
    const hashtags = post.hashtags || extractHashtags(post.caption);
    upsertPost.run({
      id: post.id,
      caption: post.caption,
      mediaType: post.mediaType,
      permalink: post.permalink,
      postedAt: post.postedAt,
      hashtags: JSON.stringify(hashtags),
    });
    insertPostMetric.run({
      postId: post.id,
      capturedAt,
      views: post.metrics.views,
      reach: post.metrics.reach,
      saves: post.metrics.saves,
      shares: post.metrics.shares,
      likes: post.metrics.likes,
      comments: post.metrics.comments,
    });
  }
});

export async function collectSnapshot() {
  const capturedAt = new Date().toISOString();
  const followerCount = await instagramClient.getFollowerCount();
  const posts = await instagramClient.getRecentPosts(25);
  persistTx(capturedAt, followerCount, posts);
  return { capturedAt, followerCount, postCount: posts.length };
}

// Demo mode starts with an empty database, which makes day-over-day spike
// detection and the growth graph meaningless until real history accumulates.
// Backfill synthetic snapshots (pinned to past instants) so those features
// have something to show immediately.
export async function seedDemoHistory(days = 14, pointsPerDay = 2) {
  if (!config.demoMode) return;
  const existing = db.prepare('SELECT COUNT(*) AS c FROM follower_snapshots').get().c;
  if (existing > 0) return;

  const now = Date.now();
  for (let d = days; d >= 0; d -= 1) {
    for (let p = 0; p < pointsPerDay; p += 1) {
      const atTime = now - d * DAY_MS + p * (DAY_MS / pointsPerDay);
      if (atTime > now) continue;
      const client = createMockClient(() => atTime);
      const capturedAt = new Date(atTime).toISOString();
      const followerCount = await client.getFollowerCount();
      const posts = await client.getRecentPosts(25);
      persistTx(capturedAt, followerCount, posts);
    }
  }
}
