// Demo data generator used when no Instagram Graph API credentials are configured.
// Produces a stable set of posts whose metrics grow smoothly over time (based on
// wall-clock elapsed time), so the analytics/reporting pipeline can be exercised
// end-to-end without a live Instagram Business account.

const EPOCH = new Date('2026-08-01T00:00:00Z').getTime();
const DAY_MS = 24 * 60 * 60 * 1000;

const TOPICS = [
  { title: '이유식 초기 레시피 모음', hashtags: ['이유식', '초기이유식', '육아맘'], mediaType: 'CAROUSEL_ALBUM' },
  { title: '신생아 밤중수유 루틴', hashtags: ['신생아', '밤중수유', '육아일상'], mediaType: 'VIDEO' },
  { title: '아기 낮잠 재우는 꿀팁', hashtags: ['낮잠꿀팁', '육아꿀팁', '아기재우기'], mediaType: 'VIDEO' },
  { title: '돌 전 발달 놀이 추천', hashtags: ['발달놀이', '돌전아기', '육아템'], mediaType: 'CAROUSEL_ALBUM' },
  { title: '산후조리원 후기', hashtags: ['산후조리원', '출산후기', '신생아맘'], mediaType: 'IMAGE' },
  { title: '아기 옷 정리 수납 팁', hashtags: ['아기옷정리', '수납템', '육아템추천'], mediaType: 'CAROUSEL_ALBUM' },
  { title: '이유식 거부기 극복기', hashtags: ['이유식거부', '육아공감', '육아맘'], mediaType: 'VIDEO' },
  { title: '워킹맘 아침 루틴 브이로그', hashtags: ['워킹맘', '아침루틴', '육아브이로그'], mediaType: 'VIDEO' },
  { title: '아기 첫 여행 준비물 체크리스트', hashtags: ['아기여행', '여행준비물', '육아템'], mediaType: 'CAROUSEL_ALBUM' },
  { title: '분리불안 시기 대처법', hashtags: ['분리불안', '육아꿀팁', '육아공감'], mediaType: 'IMAGE' },
  { title: '남편과 육아 분담 이야기', hashtags: ['육아분담', '육아일상', '부부육아'], mediaType: 'IMAGE' },
  { title: '돌잔치 셀프 준비 후기', hashtags: ['돌잔치', '셀프돌잔치', '돌잔치준비'], mediaType: 'CAROUSEL_ALBUM' },
];

function hashSeed(str) {
  let h = 2166136261;
  for (let i = 0; i < str.length; i += 1) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0) / 4294967295;
}

function buildPosts() {
  return TOPICS.map((topic, index) => {
    const daysAgo = index * 1.8 + 0.5;
    const postedAt = new Date(Date.now() - daysAgo * DAY_MS);
    const seed = hashSeed(topic.title);
    return {
      id: `demo_${index + 1}`,
      caption: `${topic.title}\n${topic.hashtags.map((h) => `#${h}`).join(' ')}`,
      mediaType: topic.mediaType,
      permalink: `https://www.instagram.com/p/demo${index + 1}/`,
      postedAt: postedAt.toISOString(),
      hashtags: topic.hashtags,
      seed,
      // The most recent post (index 0) is flagged to demonstrate the
      // "sudden view spike" alert with an accelerated growth curve.
      isSurging: index === 0,
      baseReach: 2500 + Math.round(seed * 6000),
    };
  });
}

const POSTS = buildPosts();

function metricsForPost(post, atTime) {
  const ageDays = Math.max((atTime - new Date(post.postedAt).getTime()) / DAY_MS, 0);
  const growth = post.isSurging
    ? 1 - Math.exp(-ageDays / 0.6)
    : 1 - Math.exp(-ageDays / 3);

  const reach = Math.round(post.baseReach * (0.3 + 0.7 * growth));
  const viewsMultiplier = post.mediaType === 'VIDEO' ? 2.4 : post.mediaType === 'CAROUSEL_ALBUM' ? 1.3 : 1.05;
  const views = Math.round(reach * viewsMultiplier * (post.isSurging ? 1 + 0.6 * growth : 1));
  const saveRate = 0.02 + post.seed * 0.09;
  const saves = Math.round(reach * saveRate);
  const shareRate = 0.005 + post.seed * 0.02;
  const shares = Math.round(reach * shareRate);
  const likes = Math.round(reach * (0.08 + post.seed * 0.12));
  const comments = Math.round(reach * (0.005 + post.seed * 0.01));

  return { views, reach, saves, shares, likes, comments };
}

// Factory so historical snapshots can be seeded by pinning "now" to a past
// instant (see services/collector.js#seedDemoHistory), while the live app
// uses the default Date.now()-based client below.
export function createMockClient(getNow = () => Date.now()) {
  return {
    async getFollowerCount() {
      const now = getNow();
      const daysSinceEpoch = (now - EPOCH) / DAY_MS;
      const base = 8200 + daysSinceEpoch * 14.5;
      const wiggle = Math.sin(daysSinceEpoch / 2.3) * 25;
      const postBump = POSTS.filter((p) => new Date(p.postedAt).getTime() <= now).length * 9;
      return Math.round(base + wiggle + postBump);
    },

    async getRecentPosts(limit = 25) {
      const now = getNow();
      return POSTS.filter((p) => new Date(p.postedAt).getTime() <= now)
        .slice(0, limit)
        .map((post) => ({
          id: post.id,
          caption: post.caption,
          mediaType: post.mediaType,
          permalink: post.permalink,
          postedAt: post.postedAt,
          metrics: metricsForPost(post, now),
        }));
    },
  };
}

export const mockClient = createMockClient();
