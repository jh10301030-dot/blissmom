import { config } from '../config.js';
import { mockClient } from './mock.js';

const GRAPH_API_BASE = 'https://graph.facebook.com/v21.0';

function extractHashtags(caption) {
  if (!caption) return [];
  const matches = caption.match(/#[\p{L}\p{N}_]+/gu) || [];
  return matches.map((tag) => tag.slice(1));
}

async function graphGet(path, params = {}) {
  const url = new URL(`${GRAPH_API_BASE}${path}`);
  url.searchParams.set('access_token', config.instagram.accessToken);
  for (const [key, value] of Object.entries(params)) {
    url.searchParams.set(key, value);
  }
  const res = await fetch(url);
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`Instagram Graph API error ${res.status} for ${path}: ${body}`);
  }
  return res.json();
}

// Metric names vary by media type and API version; each is requested with
// graceful fallback so a single unsupported metric doesn't fail collection
// for the whole post.
const METRICS_BY_TYPE = {
  IMAGE: ['reach', 'saved', 'shares', 'likes', 'comments'],
  CAROUSEL_ALBUM: ['reach', 'saved', 'shares', 'likes', 'comments'],
  VIDEO: ['reach', 'saved', 'shares', 'plays', 'likes', 'comments'],
};

async function fetchInsights(mediaId, mediaType) {
  const metrics = METRICS_BY_TYPE[mediaType] || METRICS_BY_TYPE.IMAGE;
  const result = { views: 0, reach: 0, saves: 0, shares: 0, likes: 0, comments: 0 };
  try {
    const data = await graphGet(`/${mediaId}/insights`, { metric: metrics.join(',') });
    for (const entry of data.data || []) {
      const value = entry.values?.[0]?.value ?? 0;
      switch (entry.name) {
        case 'reach':
          result.reach = value;
          break;
        case 'saved':
          result.saves = value;
          break;
        case 'shares':
          result.shares = value;
          break;
        case 'plays':
        case 'video_views':
        case 'impressions':
          result.views = value;
          break;
        case 'likes':
          result.likes = value;
          break;
        case 'comments':
          result.comments = value;
          break;
        default:
          break;
      }
    }
  } catch (err) {
    console.warn(`[instagram] insights unavailable for ${mediaId}: ${err.message}`);
  }
  if (!result.views) {
    // Photos/carousels have no "plays" metric; reach is the closest proxy for views.
    result.views = result.reach;
  }
  return result;
}

const realClient = {
  async getFollowerCount() {
    const data = await graphGet(`/${config.instagram.businessAccountId}`, { fields: 'followers_count' });
    return data.followers_count ?? 0;
  },

  async getRecentPosts(limit = 25) {
    const data = await graphGet(`/${config.instagram.businessAccountId}/media`, {
      fields: 'id,caption,media_type,permalink,timestamp',
      limit: String(limit),
    });
    const posts = data.data || [];
    return Promise.all(
      posts.map(async (post) => ({
        id: post.id,
        caption: post.caption || '',
        mediaType: post.media_type,
        permalink: post.permalink,
        postedAt: post.timestamp,
        metrics: await fetchInsights(post.id, post.media_type),
      })),
    );
  },
};

export const instagramClient = config.demoMode ? mockClient : realClient;
export { extractHashtags };
