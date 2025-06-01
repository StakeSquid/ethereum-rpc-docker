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
  // Set socket timeout to prevent hanging connections
  scheduling: 'fifo', // First-in-first-out scheduling
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
  // Set socket timeout to prevent hanging connections
  scheduling: 'fifo', // First-in-first-out scheduling
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
    // Only clear IDLE sockets, not active ones
    setInterval(() => {
      logger.debug('Refreshing DNS cache - clearing idle sockets only');
      
      // Only destroy free (idle) sockets, not active ones
      if (httpAgent.freeSockets) {
        Object.keys(httpAgent.freeSockets).forEach(name => {
          if (httpAgent.freeSockets[name]) {
            httpAgent.freeSockets[name].forEach(socket => {
              socket.destroy();
            });
          }
        });
      }
      
      if (httpsAgent.freeSockets) {
        Object.keys(httpsAgent.freeSockets).forEach(name => {
          if (httpsAgent.freeSockets[name]) {
            httpsAgent.freeSockets[name].forEach(socket => {
              socket.destroy();
            });
          }
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

    // Validate request body
    if (!requestBody || !requestBody.method) {
      logger.error({
        requestId,
        body: requestBody,
        headers: req.headers,
      }, 'Invalid or missing request body');
      
      res.status(400).json({
        jsonrpc: '2.0',
        error: {
          code: -32600,
          message: 'Invalid Request',
        },
        id: requestBody?.id || null,
      });
      return;
    }

    logger.info({
      requestId,
      method: requestBody.method,
      params: requestBody.params,
      endpoint: 'incoming',
      httpVersion: req.httpVersion,
      connection: req.headers.connection,
      userAgent: req.headers['user-agent'],
      acceptEncoding: req.headers['accept-encoding'],
    }, 'Received JSON-RPC request');

    // Handle client disconnect
    let clientClosed = false;
    let clientCloseReason = null;
    let responseCompleted = false;
    
    // Use 'aborted' event which is more reliable for detecting client disconnects
    req.on('aborted', () => {
      if (!clientClosed) {
        clientClosed = true;
        clientCloseReason = 'request_aborted';
        const elapsedMs = Date.now() - startTime;
        
        logger.warn({ 
          requestId,
          reason: clientCloseReason,
          headers: req.headers,
          userAgent: req.headers['user-agent'],
          contentLength: req.headers['content-length'],
          method: requestBody.method,
          elapsedMs,
          responseCompleted,
        }, 'Client aborted request');
      }
    });
    
    // Don't use the 'close' event to determine client disconnect
    // It fires too early and unreliably
    req.on('close', () => {
      const elapsedMs = Date.now() - startTime;
      logger.debug({ 
        requestId,
        reason: 'request_close_event',
        method: requestBody.method,
        elapsedMs,
        responseCompleted,
        headersSent: res.headersSent,
        finished: res.finished,
      }, 'Request close event (informational only)');
    });

    req.on('error', (error) => {
      // Only mark as closed for specific network errors
      if (error.code === 'ECONNRESET' || error.code === 'EPIPE') {
        clientClosed = true;
        clientCloseReason = `connection_error: ${error.code}`;
      }
      logger.error({ 
        requestId, 
        error: error.message,
        code: error.code,
        reason: clientCloseReason,
        headers: req.headers,
        method: requestBody.method,
        elapsedMs: Date.now() - startTime,
      }, 'Client connection error');
    });

    // Track when response is actually finished
    res.on('finish', () => {
      responseCompleted = true;
      logger.debug({
        requestId,
        method: requestBody.method,
        elapsedMs: Date.now() - startTime,
      }, 'Response finished successfully');
    });

    // Also track response close events
    res.on('close', () => {
      if (!responseCompleted) {
        logger.warn({
          requestId,
          reason: 'response_closed',
          finished: res.finished,
          headersSent: res.headersSent,
          method: requestBody.method,
          elapsedMs: Date.now() - startTime,
          clientClosed,
        }, 'Response connection closed before completion');
      }
    });

    try {
      // Start both requests in parallel
      const streamPromise = this.streamResponse(
        requestId, 
        requestBody, 
        res, 
        startTime, 
        () => clientClosed, 
        () => responseCompleted = true,
        () => clientCloseReason
      );
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
        streamEndpoint: this.streamEndpoint,
        compareEndpoint: this.compareEndpoint,
      }, 'Error handling request');

      // Always try to send an error response if possible
      if (!res.headersSent && !res.writableEnded) {
        try {
          // Send a proper JSON-RPC error response
          res.status(502).json({
            jsonrpc: '2.0',
            error: {
              code: -32603,
              message: 'Internal error: Unable to connect to upstream RPC endpoints',
              data: {
                error: error.message,
                streamEndpoint: this.streamEndpoint,
                compareEndpoint: this.compareEndpoint,
              }
            },
            id: requestBody.id || null,
          });
          
          logger.info({
            requestId,
            sentErrorResponse: true,
          }, 'Sent error response to client');
        } catch (sendError) {
          logger.error({
            requestId,
            error: sendError.message,
          }, 'Failed to send error response to client');
        }
      } else {
        logger.warn({
          requestId,
          headersSent: res.headersSent,
          writableEnded: res.writableEnded,
          clientClosed,
        }, 'Cannot send error response - headers already sent or connection closed');
      }
    }
  }

  async streamResponse(requestId, requestBody, res, startTime, isClientClosed, isResponseCompleted, getClientCloseReason) {
    let responseData = '';
    let statusCode = 0;
    let upstreamResponse = null;

    try {
      // Create fresh client for this request
      const client = this.createClient(this.streamEndpoint);
      
      // Get the original Accept-Encoding from the client request
      const acceptEncoding = res.req.headers['accept-encoding'] || 'identity';
      
      // Check if client already closed before making upstream request
      if (isClientClosed()) {
        logger.warn({
          requestId,
          endpoint: 'stream',
          method: requestBody.method,
          clientCloseReason: getClientCloseReason(),
          elapsedBeforeRequest: Date.now() - startTime,
        }, 'Client closed before upstream request could be made');
        // Don't return early - still try to make the request in case our detection was wrong
        // The actual response sending will handle the client closed state
      }
      
      logger.debug({
        requestId,
        endpoint: 'stream',
        method: requestBody.method,
        streamEndpoint: this.streamEndpoint,
      }, 'Making upstream request');
      
      let response;
      try {
        response = await client.post('/', requestBody, {
          responseType: 'stream',
          headers: {
            'Content-Type': 'application/json',
            'Accept-Encoding': acceptEncoding, // Forward client's encoding preference
          },
          validateStatus: (status) => true, // Don't throw on any status
        });
      } catch (upstreamError) {
        // Log the specific error details
        logger.error({
          requestId,
          endpoint: 'stream',
          error: upstreamError.message,
          code: upstreamError.code,
          streamEndpoint: this.streamEndpoint,
          errno: upstreamError.errno,
          syscall: upstreamError.syscall,
          address: upstreamError.address,
          port: upstreamError.port,
        }, 'Failed to connect to upstream endpoint');
        
        // Re-throw with more context
        const enhancedError = new Error(`Failed to connect to upstream RPC endpoint at ${this.streamEndpoint}: ${upstreamError.message}`);
        enhancedError.code = upstreamError.code;
        enhancedError.originalError = upstreamError;
        throw enhancedError;
      }

      upstreamResponse = response;
      statusCode = response.status;
      const streamLatency = Date.now() - startTime;

      logger.info({
        requestId,
        endpoint: 'stream',
        latencyMs: streamLatency,
        statusCode: response.status,
      }, 'Stream response started');

      // Set response headers if not already sent
      if (!res.headersSent) {
        try {
          res.status(response.status);
          
          // Respect client's connection preference
          const clientConnection = res.req.headers.connection;
          if (clientConnection && clientConnection.toLowerCase() === 'close') {
            res.setHeader('Connection', 'close');
          } else {
            res.setHeader('Connection', 'keep-alive');
            res.setHeader('Keep-Alive', `timeout=${Math.floor(config.requestTimeout / 1000)}`);
          }
          
          Object.entries(response.headers).forEach(([key, value]) => {
            // Don't override Connection header we just set
            if (key.toLowerCase() !== 'connection' && key.toLowerCase() !== 'keep-alive') {
              res.setHeader(key, value);
            }
          });
          
          // For Java clients, ensure we handle content properly
          const userAgent = res.req.headers['user-agent'] || '';
          if (userAgent.includes('Java') || userAgent.includes('okhttp') || userAgent.includes('Apache-HttpClient')) {
            // Java clients often expect explicit content handling
            if (!response.headers['content-length'] && !response.headers['transfer-encoding']) {
              // If upstream didn't specify, we'll use chunked encoding
              res.setHeader('Transfer-Encoding', 'chunked');
            }
          }
          
          // Explicitly flush headers to ensure client receives them immediately
          res.flushHeaders();
          
          logger.debug({
            requestId,
            endpoint: 'stream',
            headersSent: true,
            statusCode: response.status,
            contentType: response.headers['content-type'],
            contentLength: response.headers['content-length'],
            transferEncoding: response.headers['transfer-encoding'],
            clientClosed: isClientClosed(),
          }, 'Response headers sent');
        } catch (headerError) {
          logger.error({
            requestId,
            error: headerError.message,
            clientClosed: isClientClosed(),
          }, 'Error setting response headers');
        }
      }

      // Handle upstream errors
      response.data.on('error', (error) => {
        logger.error({
          requestId,
          endpoint: 'stream',
          error: error.message,
          code: error.code,
        }, 'Upstream stream error');
        
        // Only destroy if response hasn't been sent yet
        if (!res.headersSent && !res.writableEnded) {
          res.destroy();
        }
      });

      // Capture and stream the response
      const chunks = [];
      
      // Check if we should buffer the response (for clients that don't handle streaming well)
      const userAgent = res.req.headers['user-agent'] || '';
      const shouldBuffer = userAgent.includes('ReactorNetty') || 
                          userAgent.includes('Java') || 
                          userAgent.includes('okhttp') ||
                          userAgent.includes('Apache-HttpClient');
      
      // For streaming clients, we need to handle backpressure properly
      let writeQueue = Promise.resolve();
      
      response.data.on('data', (chunk) => {
        // Always capture raw chunks for comparison
        chunks.push(chunk);
        
        // Only write to client if not buffering
        // Remove the clientClosed check - let the write fail gracefully if truly disconnected
        if (!shouldBuffer && !res.writableEnded) {
          // Chain writes to handle backpressure properly
          writeQueue = writeQueue.then(() => new Promise((resolve) => {
            try {
              const canContinue = res.write(chunk, (err) => {
                if (err) {
                  logger.error({
                    requestId,
                    error: err.message,
                    chunkSize: chunk.length,
                  }, 'Error in write callback');
                }
                resolve();
              });
              
              if (!canContinue) {
                // Wait for drain event if write buffer is full
                logger.debug({
                  requestId,
                  chunkSize: chunk.length,
                }, 'Backpressure detected, waiting for drain');
                res.once('drain', resolve);
              } else {
                resolve();
              }
            } catch (writeError) {
              logger.error({
                requestId,
                error: writeError.message,
                code: writeError.code,
                clientClosed: isClientClosed(),
              }, 'Error writing to client');
              resolve(); // Continue even on error
            }
          }));
        }
      });

      return new Promise((resolve, reject) => {
        response.data.on('end', async () => {
          isResponseCompleted(); // Mark response as completed
          
          const totalTime = Date.now() - startTime;
          
          // Combine chunks and convert to string for logging
          const rawData = Buffer.concat(chunks);
          responseData = rawData.toString('utf8');
          
          // Wait for all writes to complete before ending
          if (!shouldBuffer) {
            try {
              await writeQueue;
              logger.debug({
                requestId,
                endpoint: 'stream',
              }, 'All chunks written successfully');
            } catch (err) {
              logger.error({
                requestId,
                error: err.message,
              }, 'Error waiting for writes to complete');
            }
          }
          
          // Send buffered response for clients that don't handle streaming well
          // Check for Java clients (including dshackle) and buffer their responses
          const userAgent = res.req.headers['user-agent'] || '';
          const shouldBufferForClient = shouldBuffer || 
                                       userAgent.includes('Java') || 
                                       userAgent.includes('okhttp') ||
                                       userAgent.includes('Apache-HttpClient');
          
          if (shouldBufferForClient && !res.writableEnded) {
            try {
              // For buffered responses, ensure we send proper headers
              res.removeHeader('transfer-encoding');
              res.setHeader('content-length', rawData.length);
              
              // Write all data and end in one operation
              res.end(rawData, () => {
                logger.debug({
                  requestId,
                  endpoint: 'stream',
                  buffered: true,
                  responseSize: rawData.length,
                  userAgent,
                  clientClosed: isClientClosed(),
                }, 'Sent buffered response');
              });
            } catch (error) {
              logger.error({
                requestId,
                error: error.message,
                userAgent,
              }, 'Error sending buffered response');
            }
          } else if (!res.writableEnded) {
            // For streaming responses, ensure all data is flushed before ending
            // Use res.end() with a callback to ensure it completes
            try {
              // If there's still data in the write buffer, wait for it to drain
              if (res.writableHighWaterMark && res.writableLength > 0) {
                res.once('drain', () => {
                  res.end(() => {
                    logger.debug({
                      requestId,
                      endpoint: 'stream',
                      responseSize: rawData.length,
                      clientClosed: isClientClosed(),
                    }, 'Ended streaming response after drain');
                  });
                });
              } else {
                res.end(() => {
                  logger.debug({
                    requestId,
                    endpoint: 'stream',
                    responseSize: rawData.length,
                    clientClosed: isClientClosed(),
                  }, 'Ended streaming response');
                });
              }
            } catch (endError) {
              logger.error({
                requestId,
                error: endError.message,
                clientClosed: isClientClosed(),
              }, 'Error ending response');
            }
          }
          
          // Log if client closed very early
          if (isClientClosed() && totalTime < 10) {
            // This appears to be normal JSON-RPC client behavior
            logger.info({
              requestId,
              endpoint: 'stream',
              totalTimeMs: totalTime,
              responseSize: rawData.length,
              contentEncoding: response.headers['content-encoding'],
              responseHeaders: response.headers,
              method: requestBody.method,
              httpVersion: res.req.httpVersion,
              keepAlive: res.req.headers.connection,
              clientClosedAt: getClientCloseReason(),
              responseComplete: true, // We're in the 'end' event, so response is complete
              chunksReceived: chunks.length,
              // For small responses, log the actual data to see what's happening
              responseData: rawData.length < 200 ? responseData : '[truncated]',
            }, 'Client closed connection quickly (normal for JSON-RPC)');
          }
          
          logger.info({
            requestId,
            endpoint: 'stream',
            totalTimeMs: totalTime,
            responseSize: rawData.length,
            contentEncoding: response.headers['content-encoding'],
            clientClosed: isClientClosed(),
          }, 'Stream response completed');
          
          resolve({
            statusCode,
            data: responseData,
            size: rawData.length,
            latency: totalTime,
            contentEncoding: response.headers['content-encoding'],
          });
        });

        response.data.on('error', (error) => {
          logger.error({
            requestId,
            endpoint: 'stream',
            error: error.message,
            code: error.code,
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
        code: error.code,
        statusCode: error.response?.status,
        streamEndpoint: this.streamEndpoint,
      }, 'Stream request failed');

      // Clean up upstream response if it exists
      if (upstreamResponse && upstreamResponse.data) {
        upstreamResponse.data.destroy();
      }

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
          'Accept-Encoding': 'gzip, deflate', // Accept compressed responses for comparison
        },
        validateStatus: (status) => true, // Don't throw on any status
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
        code: error.code,
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
        request: requestBody, // Include the original request for context
        mismatches,
        streamEndpoint: this.streamEndpoint,
        compareEndpoint: this.compareEndpoint,
      };

      // Include full responses if there's any mismatch (not just size)
      // This helps debug status code mismatches, timeouts, etc.
      const shouldLogResponses = sizeDiff > config.sizeDiffThreshold || 
                                streamResponse.statusCode !== compareResponse.statusCode ||
                                (config.logAllMismatchedResponses === true);

      if (shouldLogResponses) {
        try {
          // Try to parse as JSON for better readability
          logEntry.streamResponse = {
            statusCode: streamResponse.statusCode,
            size: streamResponse.size,
            data: streamResponse.data ? JSON.parse(streamResponse.data) : null
          };
          logEntry.compareResponse = {
            statusCode: compareResponse.statusCode,
            size: compareResponse.size,
            data: compareResponse.data ? JSON.parse(compareResponse.data) : null
          };
        } catch (e) {
          // If not valid JSON, include raw data
          logEntry.streamResponse = {
            statusCode: streamResponse.statusCode,
            size: streamResponse.size,
            data: streamResponse.data
          };
          logEntry.compareResponse = {
            statusCode: compareResponse.statusCode,
            size: compareResponse.size,
            data: compareResponse.data
          };
        }
        
        // Log a summary for easier reading
        logger.warn({
          requestId,
          method: requestBody.method,
          mismatchTypes: mismatches.map(m => m.type),
          streamEndpoint: this.streamEndpoint,
          compareEndpoint: this.compareEndpoint,
        }, 'Response mismatch detected - full details below');
      }

      // Log the full entry with all details
      logger.warn(logEntry, 'Response mismatch details');
    } else {
      logger.debug({
        requestId,
        method: requestBody.method,
        streamLatency: streamResponse.latency,
        compareLatency: compareResponse.latency,
        streamSize: streamResponse.size,
        compareSize: compareResponse.size,
      }, 'Responses match');
    }
  }
}

module.exports = RPCProxy; 