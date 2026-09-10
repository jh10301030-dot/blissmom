import { Router } from 'express';
import { config } from './config.js';
import { collectSnapshot } from './services/collector.js';
import {
  compareRecentPosts,
  topPerformersThisWeek,
  saveRateCommonality,
  detectViewSpikes,
  followerAndPublishingTimeline,
  recommendNextTopics,
} from './services/analytics.js';
import { generateDailyBrief, generateWeeklyReport, getLatestReport, listReports } from './services/reports.js';

export const router = Router();

router.get('/status', (req, res) => {
  res.json({ demoMode: config.demoMode, timezone: config.timezone, spikeThreshold: config.spikeThreshold });
});

router.post('/collect', async (req, res, next) => {
  try {
    res.json(await collectSnapshot());
  } catch (err) {
    next(err);
  }
});

router.get('/posts/recent', (req, res) => {
  const limit = Number(req.query.limit) || 5;
  res.json(compareRecentPosts(limit));
});

router.get('/posts/top', (req, res) => {
  const limit = Number(req.query.limit) || 3;
  res.json(topPerformersThisWeek(limit));
});

router.get('/analysis/save-rate', (req, res) => {
  res.json(saveRateCommonality());
});

router.get('/analysis/spikes', (req, res) => {
  res.json(detectViewSpikes());
});

router.get('/analysis/timeline', (req, res) => {
  res.json(followerAndPublishingTimeline());
});

router.get('/analysis/recommendations', (req, res) => {
  const limit = Number(req.query.limit) || 3;
  res.json(recommendNextTopics(limit));
});

router.get('/reports/daily/latest', (req, res) => {
  res.json(getLatestReport('daily'));
});

router.get('/reports/weekly/latest', (req, res) => {
  res.json(getLatestReport('weekly'));
});

router.get('/reports/daily/history', (req, res) => {
  res.json(listReports('daily', Number(req.query.limit) || 14));
});

router.get('/reports/weekly/history', (req, res) => {
  res.json(listReports('weekly', Number(req.query.limit) || 8));
});

router.post('/reports/daily/generate', async (req, res, next) => {
  try {
    await collectSnapshot();
    res.json(generateDailyBrief());
  } catch (err) {
    next(err);
  }
});

router.post('/reports/weekly/generate', async (req, res, next) => {
  try {
    await collectSnapshot();
    res.json(generateWeeklyReport());
  } catch (err) {
    next(err);
  }
});
