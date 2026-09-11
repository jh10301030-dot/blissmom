const express = require('express');
const { YoutubeTranscript } = require('youtube-transcript');
const { extractVideoId, fetchVideoInfo } = require('./lib/youtube');
const { buildCards } = require('./lib/summarize');

const app = express();
app.use(express.json());
app.use(express.static('public'));

async function fetchTranscriptWithFallback(videoId) {
  const langs = ['ko', 'en', undefined];
  let lastError;
  for (const lang of langs) {
    try {
      return await YoutubeTranscript.fetchTranscript(videoId, lang ? { lang } : undefined);
    } catch (err) {
      lastError = err;
    }
  }
  throw lastError;
}

app.post('/api/cardnews', async (req, res) => {
  const videoId = extractVideoId(req.body.url);
  if (!videoId) {
    return res.status(400).json({ error: '유효한 유튜브 링크를 입력해 주세요.' });
  }

  try {
    const [info, transcript] = await Promise.all([
      fetchVideoInfo(videoId),
      fetchTranscriptWithFallback(videoId),
    ]);

    const targetCount = Math.max(4, Math.min(10, Math.round(transcript.length / 25)));
    const contentCards = buildCards(transcript, targetCount);

    if (contentCards.length === 0) {
      return res.status(422).json({ error: '이 영상에서는 카드뉴스를 만들 만한 자막 내용을 찾지 못했어요.' });
    }

    const cards = [
      {
        page: 0,
        heading: info.title,
        body: `${info.author} · 유튜브 영상 카드뉴스`,
        isTitle: true,
      },
      ...contentCards,
      {
        page: contentCards.length + 1,
        heading: '오늘의 요약 끝 🎬',
        body: '더 자세한 내용은 원본 영상에서 확인해 보세요.',
        isOutro: true,
      },
    ];

    res.json({
      title: info.title,
      author: info.author,
      thumbnail: info.thumbnail,
      videoUrl: info.videoUrl,
      cards,
    });
  } catch (err) {
    console.error(err);
    const message = /disabled|not available|unavailable/i.test(err.message || '')
      ? '이 영상은 자막이 없어서 카드뉴스를 만들 수 없어요.'
      : '카드뉴스를 만드는 중 문제가 발생했어요. 잠시 후 다시 시도해 주세요.';
    res.status(502).json({ error: message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`카드뉴스 서버 실행 중: http://localhost:${PORT}`);
});
