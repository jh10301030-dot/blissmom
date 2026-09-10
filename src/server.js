import express from 'express';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { config } from './config.js';
import './db.js';
import { router } from './routes.js';
import { collectSnapshot, seedDemoHistory } from './services/collector.js';
import { generateDailyBrief, generateWeeklyReport } from './services/reports.js';
import { startScheduler } from './scheduler.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const app = express();
app.use(express.json());
app.use('/api', router);
app.use('/vendor/chart.js', express.static(path.join(__dirname, '..', 'node_modules', 'chart.js', 'dist', 'chart.umd.js')));
app.use(express.static(path.join(__dirname, '..', 'public')));

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: err.message });
});

async function bootstrap() {
  if (config.demoMode) {
    console.log('[startup] IG_ACCESS_TOKEN/IG_BUSINESS_ACCOUNT_ID not set — running in demo mode with sample data.');
    await seedDemoHistory();
  }
  await collectSnapshot();
  generateDailyBrief();
  generateWeeklyReport();
  startScheduler();

  app.listen(config.port, () => {
    console.log(`[startup] blissmom dashboard listening on http://localhost:${config.port}`);
  });
}

bootstrap().catch((err) => {
  console.error('[startup] failed:', err);
  process.exit(1);
});
