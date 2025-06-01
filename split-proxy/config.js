const dotenv = require('dotenv');
const path = require('path');

// Load environment variables from .env file
dotenv.config({ path: path.join(__dirname, '.env') });

const config = {
  // RPC endpoints
  primaryRpc: process.env.PRIMARY_RPC || 'http://localhost:8545',
  secondaryRpc: process.env.SECONDARY_RPC || 'http://localhost:8546',
  
  // Role configuration
  primaryRole: process.env.PRIMARY_ROLE || 'primary', // 'primary' or 'secondary'
  
  // Thresholds
  latencyThresholdMs: parseInt(process.env.LATENCY_THRESHOLD_MS || '1000', 10),
  sizeDiffThreshold: parseInt(process.env.SIZE_DIFF_THRESHOLD || '100', 10),
  
  // Logging
  logMismatches: process.env.LOG_MISMATCHES !== 'false', // default true
  
  // Server
  port: parseInt(process.env.PORT || '8545', 10),
  
  // Request timeout
  requestTimeout: parseInt(process.env.REQUEST_TIMEOUT || '30000', 10),
  
  // DNS refresh interval in milliseconds
  dnsRefreshInterval: parseInt(process.env.DNS_REFRESH_INTERVAL || '1000', 10),
};

// Validate configuration
function validateConfig() {
  if (!config.primaryRpc || !config.secondaryRpc) {
    throw new Error('PRIMARY_RPC and SECONDARY_RPC must be configured');
  }
  
  if (!['primary', 'secondary'].includes(config.primaryRole)) {
    throw new Error('PRIMARY_ROLE must be either "primary" or "secondary"');
  }
  
  if (config.primaryRpc === config.secondaryRpc) {
    console.warn('WARNING: PRIMARY_RPC and SECONDARY_RPC are the same');
  }
}

validateConfig();

module.exports = config; 