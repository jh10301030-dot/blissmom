const $ = (sel) => document.querySelector(sel);

async function fetchJSON(url, options) {
  const res = await fetch(url, options);
  if (!res.ok) throw new Error(`${url} -> ${res.status}`);
  return res.json();
}

function shortCaption(caption) {
  return (caption || '').split('\n')[0];
}

function formatNumber(n) {
  return Number(n || 0).toLocaleString('ko-KR');
}

function mediaTypeLabel(type) {
  return { IMAGE: '이미지', VIDEO: '동영상', CAROUSEL_ALBUM: '캐러셀' }[type] || type;
}

let timelineChart = null;

async function loadStatus() {
  const status = await fetchJSON('/api/status');
  $('#demo-badge').hidden = !status.demoMode;
  $('#status-line').textContent = status.demoMode
    ? '데모 모드로 실행 중 (Instagram Graph API 키를 설정하면 실제 데이터로 전환됩니다)'
    : `Instagram Graph API 연동됨 · 타임존 ${status.timezone}`;
}

async function loadDailyBrief() {
  const brief = await fetchJSON('/api/reports/daily/latest');
  if (!brief) {
    $('#daily-summary').textContent = '아직 생성된 브리프가 없습니다. "다시 생성" 버튼을 눌러주세요.';
    return;
  }
  $('#daily-summary').textContent = brief.summaryText;

  $('#follower-count').textContent = `${formatNumber(brief.followerCount)}명`;
  const deltaEl = $('#follower-delta');
  if (brief.followerDelta == null) {
    deltaEl.textContent = '';
  } else {
    deltaEl.textContent = `${brief.followerDelta >= 0 ? '▲' : '▼'} ${Math.abs(brief.followerDelta)} (전일 대비)`;
    deltaEl.className = `follower-delta ${brief.followerDelta >= 0 ? 'up' : 'down'}`;
  }
}

async function loadWeeklyReport() {
  const report = await fetchJSON('/api/reports/weekly/latest');
  $('#weekly-summary').textContent = report
    ? report.summaryText
    : '아직 생성된 주간 보고서가 없습니다. "다시 생성" 버튼을 눌러주세요.';
}

async function loadSpikes() {
  const spikes = await fetchJSON('/api/analysis/spikes');
  const container = $('#spike-list');
  container.innerHTML = '';
  if (!spikes.length) {
    container.innerHTML = '<div class="empty-state">현재 급상승한 콘텐츠가 없습니다.</div>';
    return;
  }
  for (const spike of spikes) {
    const div = document.createElement('div');
    div.className = 'spike-item';
    div.innerHTML = `<strong>${shortCaption(spike.caption)}</strong><br/>
      조회수 ${formatNumber(spike.baselineViews)} → ${formatNumber(spike.latestViews)}
      (<span style="color:#d9534f;font-weight:700;">+${spike.growthPct}%</span>)
      ${spike.comparedToYesterday ? '· 전일 대비' : '· 최초 수집 대비'}`;
    container.appendChild(div);
  }
}

async function loadTopPerformers() {
  const posts = await fetchJSON('/api/posts/top?limit=3');
  const list = $('#top-list');
  list.innerHTML = '';
  if (!posts.length) {
    list.innerHTML = '<li class="empty-state">이번 주 게시된 콘텐츠가 없습니다.</li>';
    return;
  }
  posts.forEach((post, i) => {
    const li = document.createElement('li');
    li.className = 'rank-item';
    li.innerHTML = `<span class="rank-number">${i + 1}</span>
      <span>
        <div>${shortCaption(post.caption)}</div>
        <div class="meta">${mediaTypeLabel(post.mediaType)} · 조회 ${formatNumber(post.metrics.views)} · 저장 ${formatNumber(post.metrics.saves)} · 점수 ${formatNumber(post.score)}</div>
      </span>`;
    list.appendChild(li);
  });
}

async function loadRecentComparison() {
  const posts = await fetchJSON('/api/posts/recent?limit=5');
  const tbody = $('#recent-table tbody');
  tbody.innerHTML = '';
  for (const post of posts) {
    const tr = document.createElement('tr');
    const date = new Date(post.postedAt).toLocaleDateString('ko-KR');
    tr.innerHTML = `<td>${shortCaption(post.caption)}</td>
      <td>${mediaTypeLabel(post.mediaType)}</td>
      <td>${date}</td>
      <td>${formatNumber(post.views)}</td>
      <td>${formatNumber(post.reach)}</td>
      <td>${formatNumber(post.saves)}</td>
      <td>${formatNumber(post.shares)}</td>`;
    tbody.appendChild(tr);
  }
}

async function loadSaveRateAnalysis() {
  const data = await fetchJSON('/api/analysis/save-rate');
  const container = $('#save-rate-analysis');
  if (!data.highSaveRatePosts.length) {
    container.innerHTML = '<div class="empty-state">분석할 데이터가 부족합니다.</div>';
    return;
  }
  const tagsHtml = data.commonHashtags.map((h) => `<span class="tag">#${h.tag} (${h.count})</span>`).join('');
  const mediaHtml = Object.entries(data.mediaTypeBreakdown)
    .map(([type, count]) => `${mediaTypeLabel(type)} ${count}건`)
    .join(' · ');
  container.innerHTML = `
    <p class="muted">저장률 상위 ${data.highSaveRatePosts.length}개 게시물 기준</p>
    <div style="margin-bottom:10px;">${tagsHtml}</div>
    <table>
      <tbody>
        <tr><th>주요 콘텐츠 유형</th><td>${mediaHtml}</td></tr>
        <tr><th>평균 캡션 길이</th><td>${data.averageCaptionLength}자</td></tr>
        <tr><th>평균 게시 시간대</th><td>${data.averagePostingHour != null ? `${data.averagePostingHour}시` : '-'}</td></tr>
      </tbody>
    </table>`;
}

async function loadRecommendations() {
  const recs = await fetchJSON('/api/analysis/recommendations');
  const list = $('#recommendation-list');
  list.innerHTML = '';
  if (!recs.length) {
    list.innerHTML = '<li class="empty-state">추천할 만한 데이터가 아직 없습니다.</li>';
    return;
  }
  for (const rec of recs) {
    const li = document.createElement('li');
    li.className = 'rank-item';
    li.innerHTML = `<span class="rank-number">${rec.rank}</span>
      <span>
        <div><strong>${rec.topic}</strong> 관련 콘텐츠 (${mediaTypeLabel(rec.recommendedMediaType)} 추천)</div>
        <div class="meta">${rec.reason}</div>
      </span>`;
    list.appendChild(li);
  }
}

async function loadTimeline() {
  const { followers, publishing } = await fetchJSON('/api/analysis/timeline');
  const publishByDate = new Map(publishing.map((p) => [p.date, p.postCount]));
  const labels = followers.map((f) => f.date);
  const followerData = followers.map((f) => f.followerCount);
  const postData = labels.map((date) => publishByDate.get(date) || 0);

  const ctx = document.getElementById('timeline-chart');
  if (timelineChart) timelineChart.destroy();
  timelineChart = new Chart(ctx, {
    data: {
      labels,
      datasets: [
        {
          type: 'line',
          label: '팔로워 수',
          data: followerData,
          borderColor: '#e07a8b',
          backgroundColor: '#e07a8b',
          yAxisID: 'y',
          tension: 0.3,
        },
        {
          type: 'bar',
          label: '게시물 발행 수',
          data: postData,
          backgroundColor: '#f0d9de',
          yAxisID: 'y1',
        },
      ],
    },
    options: {
      responsive: true,
      interaction: { mode: 'index', intersect: false },
      scales: {
        y: { position: 'left', title: { display: true, text: '팔로워 수' } },
        y1: { position: 'right', title: { display: true, text: '게시물 수' }, grid: { drawOnChartArea: false }, ticks: { stepSize: 1 } },
      },
    },
  });
}

async function loadAll() {
  await Promise.all([
    loadStatus(),
    loadDailyBrief(),
    loadWeeklyReport(),
    loadSpikes(),
    loadTopPerformers(),
    loadRecentComparison(),
    loadSaveRateAnalysis(),
    loadRecommendations(),
    loadTimeline(),
  ]);
}

$('#refresh-btn').addEventListener('click', async () => {
  const btn = $('#refresh-btn');
  btn.disabled = true;
  btn.textContent = '수집 중...';
  try {
    await fetchJSON('/api/collect', { method: 'POST' });
    await loadAll();
  } finally {
    btn.disabled = false;
    btn.textContent = '지금 데이터 새로고침';
  }
});

$('#daily-regen').addEventListener('click', async () => {
  await fetchJSON('/api/reports/daily/generate', { method: 'POST' });
  await loadDailyBrief();
  await loadSpikes();
});

$('#weekly-regen').addEventListener('click', async () => {
  await fetchJSON('/api/reports/weekly/generate', { method: 'POST' });
  await loadWeeklyReport();
});

loadAll().catch((err) => {
  console.error(err);
  document.body.insertAdjacentHTML('afterbegin', `<div style="background:#fdd;padding:10px;">데이터를 불러오지 못했습니다: ${err.message}</div>`);
});
