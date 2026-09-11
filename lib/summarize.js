const STOPWORDS = new Set([
  '그리고', '그래서', '그러나', '하지만', '그런데', '이것', '저것', '그것', '합니다', '있습니다',
  '있다', '없다', '대한', '위해', '정말', '너무', '이제', '그냥', '이거', '저거', '거기', '여기',
  '사실', '진짜', '약간', '조금', '한번', '우리', '저희', '이번', '오늘', '지금', '당신', '여러분',
  'the', 'a', 'an', 'is', 'are', 'was', 'were', 'and', 'or', 'but', 'to', 'of', 'in', 'on',
  'for', 'with', 'that', 'this', 'it', 'you', 'i', 'we', 'so', 'just', 'like', 'um', 'uh',
]);

function tokenize(text) {
  return (text.match(/[\p{L}\p{N}]+/gu) || [])
    .map((t) => t.toLowerCase())
    .filter((t) => t.length >= 2 && !STOPWORDS.has(t));
}

function cleanText(text) {
  return text.replace(/\s+/g, ' ').replace(/\[.*?\]/g, '').trim();
}

function buildCards(transcriptItems, targetCount) {
  const items = transcriptItems
    .map((item) => ({ text: cleanText(item.text), offset: item.offset || 0 }))
    .filter((item) => item.text.length > 0);

  if (items.length === 0) return [];

  const wordFreq = new Map();
  for (const item of items) {
    for (const token of tokenize(item.text)) {
      wordFreq.set(token, (wordFreq.get(token) || 0) + 1);
    }
  }

  const totalDuration = items[items.length - 1].offset;
  const cardCount = Math.max(4, Math.min(targetCount, 10));
  const bucketSize = totalDuration > 0 ? totalDuration / cardCount : 1;

  const buckets = Array.from({ length: cardCount }, () => []);
  for (const item of items) {
    const bucketIndex = bucketSize > 0
      ? Math.min(cardCount - 1, Math.floor(item.offset / bucketSize))
      : 0;
    buckets[bucketIndex].push(item);
  }

  const scoreLine = (text) => {
    const tokens = tokenize(text);
    if (tokens.length === 0) return 0;
    const sum = tokens.reduce((acc, t) => acc + (wordFreq.get(t) || 0), 0);
    return sum / Math.sqrt(tokens.length);
  };

  const cards = [];
  buckets.forEach((bucket, i) => {
    if (bucket.length === 0) return;
    const heading = bucket
      .slice()
      .sort((a, b) => scoreLine(b.text) - scoreLine(a.text))[0].text;
    const body = bucket.map((item) => item.text).join(' ');

    cards.push({
      page: cards.length + 1,
      heading: truncate(heading, 42),
      body: truncate(body, 170),
      timestamp: formatTime(bucket[0].offset),
    });
  });

  return cards;
}

function truncate(text, max) {
  if (text.length <= max) return text;
  return text.slice(0, max - 1).trim() + '…';
}

function formatTime(seconds) {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

module.exports = { buildCards };
