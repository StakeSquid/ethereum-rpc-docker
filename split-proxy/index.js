const express = require('express');
const config = require('./config');
const logger = require('./logger');
const RPCProxy = require('./proxy');

const app = express();
const proxy = new RPCProxy();

// Middleware to parse JSON bodies
app.use(express.json({
  limit: '50mb',
  type: 'application/json'
}));

// Request timeout middleware
app.use((req, res, next) => {
  // Set request timeout
  req.setTimeout(config.requestTimeout, () => {
    logger.error({
      method: req.method,
      url: req.url,
      timeout: config.requestTimeout,
    }, 'Request timeout');
    
    if (!res.headersSent) {
      res.status(504).json({
        jsonrpc: '2.0',
        error: {
          code: -32000,
          message: 'Request timeout',
        },
        id: req.body?.id,
      });
    }
  });
  
  next();
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    primaryEndpoint: config.primaryRpc,
    secondaryEndpoint: config.secondaryRpc,
    primaryRole: config.primaryRole,
    currentStreamEndpoint: proxy.streamEndpoint,
    currentCompareEndpoint: proxy.compareEndpoint,
  });
});

// Main JSON-RPC endpoint
app.post('/', async (req, res) => {
  await proxy.handleRequest(req, res);
});

// Error handling middleware
app.use((err, req, res, next) => {
  logger.error({
    error: err.message,
    stack: err.stack,
  }, 'Unhandled error');

  if (!res.headersSent) {
    res.status(500).json({
      jsonrpc: '2.0',
      error: {
        code: -32603,
        message: 'Internal error',
      },
      id: req.body?.id,
    });
  }
});

// Start server
const server = app.listen(config.port, () => {
  logger.info({
    port: config.port,
    primaryRpc: config.primaryRpc,
    secondaryRpc: config.secondaryRpc,
    primaryRole: config.primaryRole,
    latencyThreshold: config.latencyThresholdMs,
    sizeDiffThreshold: config.sizeDiffThreshold,
  }, 'ETH JSON-RPC proxy started');
});

// Set server timeouts to be longer than request timeout
// This prevents the server from closing connections while requests are in flight
server.timeout = config.requestTimeout + 5000; // Add 5 seconds buffer
server.keepAliveTimeout = config.requestTimeout + 5000;
server.headersTimeout = config.requestTimeout + 6000; // Should be > keepAliveTimeout

logger.info({
  serverTimeout: server.timeout,
  keepAliveTimeout: server.keepAliveTimeout,
  headersTimeout: server.headersTimeout,
  requestTimeout: config.requestTimeout,
}, 'Server timeout configuration');

// Graceful shutdown
process.on('SIGTERM', () => {
  logger.info('SIGTERM received, shutting down gracefully');
  server.close(() => {
    logger.info('Server closed');
    process.exit(0);
  });
});

process.on('SIGINT', () => {
  logger.info('SIGINT received, shutting down gracefully');
  server.close(() => {
    logger.info('Server closed');
    process.exit(0);
  });
});

// Dynamic role switching with SIGUSR1
process.on('SIGUSR1', () => {
  logger.info('SIGUSR1 received, switching primary/secondary roles');
  try {
    const newConfig = proxy.switchRoles();
    logger.info({
      ...newConfig,
      signal: 'SIGUSR1',
    }, 'Successfully switched roles');
  } catch (error) {
    logger.error({
      error: error.message,
      signal: 'SIGUSR1',
    }, 'Failed to switch roles');
  }
});

// Log instructions for role switching on startup
logger.info('To switch primary/secondary roles at runtime, send SIGUSR1 signal:');
logger.info('  kill -USR1 <pid>  OR  docker kill -s USR1 <container>');

module.exports = app;
