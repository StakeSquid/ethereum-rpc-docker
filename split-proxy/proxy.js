const axios = require('axios');
const config = require('./config');
const logger = require('./logger');
const crypto = require('crypto');
const http = require('http');
const https = require('https');

// Create HTTP agents with DNS caching disabled and connection pooling
const httpAgent = new http.Agent({
  keepAlive: true,
  keepAliveMsecs: 1000,
  maxSockets: 100,
  maxFreeSockets: 10,
  timeout: config.requestTimeout,
  // Force fresh DNS lookups
  lookup: (hostname, options, callback) => {
    // This forces Node.js to use fresh DNS resolution
    require('dns').lookup(hostname, options, callback);
  }
});

const httpsAgent = new https.Agent({
  keepAlive: true,
  keepAliveMsecs: 1000,
  maxSockets: 100,
  maxFreeSockets: 10,
  timeout: config.requestTimeout,
  // Force fresh DNS lookups
  lookup: (hostname, options, callback) => {
    // This forces Node.js to use fresh DNS resolution
    require('dns').lookup(hostname, options, callback);
  }
});

class RPCProxy {
  constructor() {
    // Store endpoint URLs instead of clients
    this.primaryEndpoint = config.primaryRpc;
    this.secondaryEndpoint = config.secondaryRpc;

    // Determine which endpoint to stream and which to compare
    if (config.primaryRole === 'primary') {
      this.streamEndpoint = this.primaryEndpoint;
      this.compareEndpoint = this.secondaryEndpoint;
    } else {
      this.streamEndpoint = this.secondaryEndpoint;
      this.compareEndpoint = this.primaryEndpoint;
    }

    // Start DNS refresh timer
    this.startDnsRefreshTimer();
  }

  // Create a fresh axios instance for each request to ensure DNS resolution
  createClient(baseURL) {
    const isHttps = baseURL.startsWith('https://');
    return axios.create({
      baseURL,
      timeout: config.requestTimeout,
      maxContentLength: Infinity,
      maxBodyLength: Infinity,
      httpAgent: isHttps ? undefined : httpAgent,
      httpsAgent: isHttps ? httpsAgent : undefined,
      // Disable axios's built-in DNS caching
      transformRequest: [
        (data, headers) => {
          // Add timestamp to force fresh connections periodically
          headers['X-Request-Time'] = Date.now().toString();
          return data;
        },
        ...axios.defaults.transformRequest
      ]
    });
  }

  startDnsRefreshTimer() {
    // Periodically clear the DNS cache by recreating the agents
    setInterval(() => {
      logger.debug('Refreshing DNS cache');
      
      // Clear any cached DNS entries in the HTTP agents
      if (httpAgent.sockets) {
        Object.keys(httpAgent.sockets).forEach(name => {
          httpAgent.sockets[name].forEach(socket => {
            socket.destroy();
          });
        });
      }
      
      if (httpsAgent.sockets) {
        Object.keys(httpsAgent.sockets).forEach(name => {
          httpsAgent.sockets[name].forEach(socket => {
            socket.destroy();
          });
        });
      }
    }, config.dnsRefreshInterval);
  }

  generateRequestId() {
    return crypto.randomBytes(16).toString('hex');
  }

  switchRoles() {
    // Swap the endpoints
    const tempEndpoint = this.streamEndpoint;
    
    this.streamEndpoint = this.compareEndpoint;
    this.compareEndpoint = tempEndpoint;
    
    // Update the primaryRole in config
    config.primaryRole = config.primaryRole === 'primary' ? 'secondary' : 'primary';
    
    logger.info({
      newStreamEndpoint: this.streamEndpoint,
      newCompareEndpoint: this.compareEndpoint,
      newPrimaryRole: config.primaryRole,
    }, 'Switched primary/secondary roles');
    
    return {
      streamEndpoint: this.streamEndpoint,
      compareEndpoint: this.compareEndpoint,
      primaryRole: config.primaryRole,
    };
  }

  async handleRequest(req, res) {
    const requestId = this.generateRequestId();
    const startTime = Date.now();
    const requestBody = req.body;

    logger.info({
      requestId,
      method: requestBody.method,
      params: requestBody.params,
      endpoint: 'incoming',
    }, 'Received JSON-RPC request');

    try {
      // Start both requests in parallel
      const streamPromise = this.streamResponse(requestId, requestBody, res, startTime);
      const comparePromise = this.compareResponse(requestId, requestBody, startTime);

      // Wait for the stream to complete and get response info
      const streamInfo = await streamPromise;

      // Get comparison response
      comparePromise.then(compareInfo => {
        if (compareInfo && streamInfo) {
          this.compareResponses(requestId, streamInfo, compareInfo, requestBody);
        }
      }).catch(err => {
        logger.error({
          requestId,
          error: err.message,
          endpoint: 'compare',
        }, 'Error in comparison request');
      });

    } catch (error) {
      logger.error({
        requestId,
        error: error.message,
        stack: error.stack,
      }, 'Error handling request');

      if (!res.headersSent) {
        res.status(500).json({
          jsonrpc: '2.0',
          error: {
            code: -32603,
            message: 'Internal error',
          },
          id: requestBody.id,
        });
      }
    }
  }

  async streamResponse(requestId, requestBody, res, startTime) {
    let responseData = '';
    let statusCode = 0;

    try {
      // Create fresh client for this request
      const client = this.createClient(this.streamEndpoint);
      const response = await client.post('/', requestBody, {
        responseType: 'stream',
        headers: {
          'Content-Type': 'application/json',
        },
      });

      statusCode = response.status;
      const streamLatency = Date.now() - startTime;

      logger.info({
        requestId,
        endpoint: 'stream',
        latencyMs: streamLatency,
        statusCode: response.status,
      }, 'Stream response started');

      // Set response headers
      res.status(response.status);
      Object.entries(response.headers).forEach(([key, value]) => {
        if (key.toLowerCase() !== 'content-encoding') {
          res.setHeader(key, value);
        }
      });

      // Capture and stream the response
      response.data.on('data', (chunk) => {
        responseData += chunk.toString();
        res.write(chunk);
      });

      return new Promise((resolve, reject) => {
        response.data.on('end', () => {
          res.end();
          const totalTime = Date.now() - startTime;
          
          logger.info({
            requestId,
            endpoint: 'stream',
            totalTimeMs: totalTime,
            responseSize: responseData.length,
          }, 'Stream response completed');
          
          resolve({
            statusCode,
            data: responseData,
            size: responseData.length,
            latency: totalTime,
          });
        });

        response.data.on('error', (error) => {
          logger.error({
            requestId,
            endpoint: 'stream',
            error: error.message,
          }, 'Stream error');
          reject(error);
        });
      });

    } catch (error) {
      const streamLatency = Date.now() - startTime;
      
      logger.error({
        requestId,
        endpoint: 'stream',
        latencyMs: streamLatency,
        error: error.message,
        statusCode: error.response?.status,
      }, 'Stream request failed');

      throw error;
    }
  }

  async compareResponse(requestId, requestBody, startTime) {
    try {
      const compareStart = Date.now();
      // Create fresh client for this request
      const client = this.createClient(this.compareEndpoint);
      const response = await client.post('/', requestBody, {
        headers: {
          'Content-Type': 'application/json',
        },
      });

      const compareLatency = Date.now() - compareStart;
      const compareData = typeof response.data === 'string' 
        ? response.data 
        : JSON.stringify(response.data);
      const compareSize = compareData.length;

      logger.info({
        requestId,
        endpoint: 'compare',
        latencyMs: compareLatency,
        statusCode: response.status,
        responseSize: compareSize,
      }, 'Compare response received');

      return {
        statusCode: response.status,
        data: compareData,
        size: compareSize,
        latency: compareLatency,
      };

    } catch (error) {
      logger.error({
        requestId,
        endpoint: 'compare',
        error: error.message,
        statusCode: error.response?.status,
      }, 'Compare request failed');

      return {
        error: error.message,
        statusCode: error.response?.status || 0,
      };
    }
  }

  compareResponses(requestId, streamResponse, compareResponse, requestBody) {
    if (!config.logMismatches) return;

    const mismatches = [];

    // Check status code mismatch
    if (streamResponse.statusCode !== compareResponse.statusCode) {
      mismatches.push({
        type: 'status_code',
        stream: streamResponse.statusCode,
        compare: compareResponse.statusCode,
      });
    }

    // Check size difference
    const sizeDiff = Math.abs(streamResponse.size - compareResponse.size);
    if (sizeDiff > config.sizeDiffThreshold) {
      mismatches.push({
        type: 'size',
        streamSize: streamResponse.size,
        compareSize: compareResponse.size,
        difference: sizeDiff,
      });
    }

    // Check latency difference
    const latencyDiff = compareResponse.latency - streamResponse.latency;
    if (latencyDiff > config.latencyThresholdMs) {
      mismatches.push({
        type: 'latency',
        streamLatency: streamResponse.latency,
        compareLatency: compareResponse.latency,
        difference: latencyDiff,
      });
    }

    // Log mismatches if any found
    if (mismatches.length > 0) {
      const logEntry = {
        requestId,
        method: requestBody.method,
        mismatches,
        streamEndpoint: this.streamEndpoint,
        compareEndpoint: this.compareEndpoint,
      };

      // Include full compare response if size differs significantly
      if (sizeDiff > config.sizeDiffThreshold) {
        try {
          logEntry.compareResponseData = JSON.parse(compareResponse.data);
          logEntry.streamResponseData = JSON.parse(streamResponse.data);
        } catch (e) {
          // If not valid JSON, include raw data
          logEntry.compareResponseData = compareResponse.data;
          logEntry.streamResponseData = streamResponse.data;
        }
      }

      logger.warn(logEntry, 'Response mismatch detected');
    } else {
      logger.debug({
        requestId,
        method: requestBody.method,
        streamLatency: streamResponse.latency,
        compareLatency: compareResponse.latency,
      }, 'Responses match');
    }
  }
}

module.exports = RPCProxy; 