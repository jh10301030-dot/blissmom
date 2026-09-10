import '../db.js';
import { config } from '../config.js';
import { collectSnapshot, seedDemoHistory } from '../services/collector.js';

if (config.demoMode) {
  await seedDemoHistory();
}
const result = await collectSnapshot();
console.log('Collected snapshot:', result);
