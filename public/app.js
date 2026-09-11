(() => {
  const form = document.getElementById('cardForm');
  const urlInput = document.getElementById('urlInput');
  const submitBtn = document.getElementById('submitBtn');
  const statusArea = document.getElementById('statusArea');
  const resultArea = document.getElementById('resultArea');
  const videoThumb = document.getElementById('videoThumb');
  const videoTitle = document.getElementById('videoTitle');
  const videoAuthor = document.getElementById('videoAuthor');
  const cardTrack = document.getElementById('cardTrack');
  const dots = document.getElementById('dots');
  const prevBtn = document.getElementById('prevBtn');
  const nextBtn = document.getElementById('nextBtn');
  const downloadBtn = document.getElementById('downloadBtn');
  const resetBtn = document.getElementById('resetBtn');

  const GRADIENTS = [
    'linear-gradient(135deg, #ff6b6b, #f06595)',
    'linear-gradient(135deg, #4dabf7, #7c5cff)',
    'linear-gradient(135deg, #38d9a9, #228be6)',
    'linear-gradient(135deg, #ffa94d, #ff6b6b)',
    'linear-gradient(135deg, #9775fa, #f06595)',
    'linear-gradient(135deg, #63e6be, #4dabf7)',
    'linear-gradient(135deg, #ffd43b, #ff8787)',
  ];
  const OUTRO_GRADIENT = 'linear-gradient(135deg, #2b2250, #7c5cff)';

  let currentIndex = 0;
  let cardCount = 0;

  function setStatus(mode, message) {
    statusArea.hidden = !message;
    statusArea.className = 'status-area' + (mode ? ` ${mode}` : '');
    statusArea.innerHTML = '';
    if (!message) return;

    if (mode === 'loading') {
      const spinner = document.createElement('div');
      spinner.className = 'spinner';
      statusArea.appendChild(spinner);
    }
    const text = document.createElement('p');
    text.textContent = message;
    text.style.margin = '0';
    statusArea.appendChild(text);
  }

  function renderCards(data) {
    cardTrack.innerHTML = '';
    dots.innerHTML = '';

    data.cards.forEach((card, i) => {
      const el = document.createElement('div');
      el.className = 'news-card';

      if (card.isTitle && data.thumbnail) {
        el.style.backgroundImage = `linear-gradient(180deg, rgba(0,0,0,0.15), rgba(0,0,0,0.15)), url('${data.thumbnail}')`;
        el.style.backgroundSize = 'cover';
        el.style.backgroundPosition = 'center';
      } else if (card.isOutro) {
        el.style.background = OUTRO_GRADIENT;
      } else {
        el.style.background = GRADIENTS[(card.page - 1 + GRADIENTS.length) % GRADIENTS.length];
      }

      const badge = document.createElement('span');
      badge.className = 'page-badge';
      badge.textContent = card.isTitle ? '인트로' : card.isOutro ? '끝' : `${card.page} / ${data.cards.length - 2}`;
      el.appendChild(badge);

      if (card.timestamp) {
        const ts = document.createElement('p');
        ts.className = 'timestamp';
        ts.textContent = `▶ ${card.timestamp}`;
        el.appendChild(ts);
      }

      const heading = document.createElement('p');
      heading.className = 'heading';
      heading.textContent = card.heading;
      el.appendChild(heading);

      const body = document.createElement('p');
      body.className = 'body';
      body.textContent = card.body;
      el.appendChild(body);

      const brand = document.createElement('span');
      brand.className = 'brand';
      brand.textContent = '카드뉴스 메이커';
      el.appendChild(brand);

      cardTrack.appendChild(el);

      const dot = document.createElement('span');
      if (i === 0) dot.classList.add('active');
      dots.appendChild(dot);
    });

    cardCount = data.cards.length;
    currentIndex = 0;
    updateTrackPosition();
  }

  function updateTrackPosition() {
    cardTrack.style.transform = `translateX(-${currentIndex * 100}%)`;
    [...dots.children].forEach((dot, i) => dot.classList.toggle('active', i === currentIndex));
    prevBtn.disabled = currentIndex === 0;
    nextBtn.disabled = currentIndex === cardCount - 1;
  }

  function goTo(index) {
    currentIndex = Math.max(0, Math.min(cardCount - 1, index));
    updateTrackPosition();
  }

  prevBtn.addEventListener('click', () => goTo(currentIndex - 1));
  nextBtn.addEventListener('click', () => goTo(currentIndex + 1));

  let touchStartX = null;
  cardTrack.addEventListener('touchstart', (e) => { touchStartX = e.touches[0].clientX; }, { passive: true });
  cardTrack.addEventListener('touchend', (e) => {
    if (touchStartX === null) return;
    const diff = e.changedTouches[0].clientX - touchStartX;
    if (Math.abs(diff) > 40) goTo(currentIndex + (diff < 0 ? 1 : -1));
    touchStartX = null;
  }, { passive: true });

  downloadBtn.addEventListener('click', async () => {
    const activeCard = cardTrack.children[currentIndex];
    if (!activeCard) return;
    downloadBtn.disabled = true;
    downloadBtn.textContent = '이미지 생성 중...';
    try {
      const canvas = await html2canvas(activeCard, { backgroundColor: null, scale: 2 });
      const link = document.createElement('a');
      link.download = `카드뉴스-${currentIndex + 1}.png`;
      link.href = canvas.toDataURL('image/png');
      link.click();
    } catch (err) {
      console.error(err);
      alert('이미지를 저장하지 못했어요. 다시 시도해 주세요.');
    } finally {
      downloadBtn.disabled = false;
      downloadBtn.textContent = '현재 카드 이미지로 저장';
    }
  });

  resetBtn.addEventListener('click', () => {
    resultArea.hidden = true;
    setStatus(null, '');
    urlInput.value = '';
    urlInput.focus();
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const url = urlInput.value.trim();
    if (!url) return;

    resultArea.hidden = true;
    submitBtn.disabled = true;
    setStatus('loading', '영상 자막을 분석해서 카드뉴스를 만들고 있어요...');

    try {
      const res = await fetch('/api/cardnews', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url }),
      });
      const data = await res.json();

      if (!res.ok) {
        setStatus('error', data.error || '카드뉴스를 만들지 못했어요.');
        return;
      }

      setStatus(null, '');
      videoThumb.src = data.thumbnail || '';
      videoTitle.textContent = data.title || '';
      videoAuthor.textContent = data.author || '';
      renderCards(data);
      resultArea.hidden = false;
    } catch (err) {
      console.error(err);
      setStatus('error', '네트워크 오류가 발생했어요. 잠시 후 다시 시도해 주세요.');
    } finally {
      submitBtn.disabled = false;
    }
  });
})();
