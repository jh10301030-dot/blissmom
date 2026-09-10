import 'dotenv/config';

export const config = {
  port: Number(process.env.PORT || 3000),
  timezone: process.env.TIMEZONE || 'Asia/Seoul',
  spikeThreshold: Number(process.env.SPIKE_THRESHOLD || 0.5),
  instagram: {
    accessToken: process.env.IG_ACCESS_TOKEN || '',
    businessAccountId: process.env.IG_BUSINESS_ACCOUNT_ID || '',
  },
  get demoMode() {
    return !this.instagram.accessToken || !this.instagram.businessAccountId;
  },
};
