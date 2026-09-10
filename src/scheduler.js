import cron from 'node-cron';
import { config } from './config.js';
import { collectSnapshot } from './services/collector.js';
import { generateDailyBrief, generateWeeklyReport } from './services/reports.js';

export function startScheduler() {
  const tz = { timezone: config.timezone };

  // Refresh metrics hourly so day-over-day and spike comparisons have data to work with.
  cron.schedule('0 * * * *', async () => {
    try {
      await collectSnapshot();
    } catch (err) {
      console.error('[scheduler] hourly collection failed:', err.message);
    }
  }, tz);

  // 매일 아침 8시: 팔로워/콘텐츠 성과 브리프
  cron.schedule('0 8 * * *', async () => {
    try {
      await collectSnapshot();
      const brief = generateDailyBrief();
      console.log('[scheduler] daily brief generated:\n' + brief.summaryText);
    } catch (err) {
      console.error('[scheduler] daily brief failed:', err.message);
    }
  }, tz);

  // 매주 월요일 오전 9시: 지난주 성과 보고서
  cron.schedule('0 9 * * 1', async () => {
    try {
      await collectSnapshot();
      const report = generateWeeklyReport();
      console.log('[scheduler] weekly report generated:\n' + report.summaryText);
    } catch (err) {
      console.error('[scheduler] weekly report failed:', err.message);
    }
  }, tz);

  console.log(`[scheduler] started (timezone=${config.timezone}): hourly collection, 08:00 daily brief, Mon 09:00 weekly report`);
}
