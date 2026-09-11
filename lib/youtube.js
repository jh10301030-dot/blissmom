const ID_PATTERNS = [
  /(?:youtube\.com\/watch\?v=)([\w-]{11})/,
  /(?:youtu\.be\/)([\w-]{11})/,
  /(?:youtube\.com\/shorts\/)([\w-]{11})/,
  /(?:youtube\.com\/embed\/)([\w-]{11})/,
  /^([\w-]{11})$/,
];

function extractVideoId(input) {
  const trimmed = String(input || '').trim();
  for (const pattern of ID_PATTERNS) {
    const match = trimmed.match(pattern);
    if (match) return match[1];
  }
  return null;
}

async function fetchVideoInfo(videoId) {
  const url = `https://www.youtube.com/watch?v=${videoId}`;
  const oembedUrl = `https://www.youtube.com/oembed?url=${encodeURIComponent(url)}&format=json`;
  const res = await fetch(oembedUrl);
  if (!res.ok) {
    throw new Error('영상 정보를 가져올 수 없어요. 링크를 다시 확인해 주세요.');
  }
  const data = await res.json();
  return {
    title: data.title,
    author: data.author_name,
    thumbnail: data.thumbnail_url,
    videoUrl: url,
  };
}

module.exports = { extractVideoId, fetchVideoInfo };
