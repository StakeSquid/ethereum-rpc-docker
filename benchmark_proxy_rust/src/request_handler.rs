use bytes::Bytes;
use hyper::{Body, Request, Response, StatusCode};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use log;

use crate::config::AppConfig;
use crate::stats_collector::StatsCollector;
use crate::secondary_probe::SecondaryProbe;
use crate::block_height_tracker::BlockHeightTracker;
use crate::structures::{Backend, BatchInfo};
use crate::rpc_utils;

#[derive(Debug)]
pub enum BackendResult {
    Success {
        backend_name: String,
        response: reqwest::Response, // Send the whole reqwest::Response
        duration: std::time::Duration,
    },
    Error {
        backend_name: String,
        error: reqwest::Error, // Send the reqwest::Error
        duration: std::time::Duration,
    },
}

fn calculate_secondary_delay(
    batch_info: &crate::structures::BatchInfo,
    probe: &Option<Arc<crate::secondary_probe::SecondaryProbe>>,
    stats: &Arc<crate::stats_collector::StatsCollector>,
    _config: &Arc<crate::config::AppConfig>, // _config might be used later for more complex logic
) -> std::time::Duration {
    let mut max_delay = std::time::Duration::from_millis(0);
    let default_delay = std::time::Duration::from_millis(25); // Default from Go

    if batch_info.methods.is_empty() {
        return default_delay;
    }

    for method_name in &batch_info.methods {
        let current_method_delay = if let Some(p) = probe {
            p.get_delay_for_method(method_name)
        } else {
            // This will use the stubbed method from StatsCollector which currently returns 25ms
            stats.get_primary_p75_for_method(method_name) 
        };
        if current_method_delay > max_delay {
            max_delay = current_method_delay;
        }
    }
    
    if max_delay == std::time::Duration::from_millis(0) { // if all methods were unknown or had 0 delay
        if let Some(p) = probe {
             // Go code uses: probe.minResponseTime + probe.minDelayBuffer
             // probe.get_delay_for_method("") would approximate this if it falls back to min_response_time + buffer
            return p.get_delay_for_method(""); // Assuming empty method falls back to base delay
        }
        return default_delay;
    }
    max_delay
}

pub async fn handle_http_request(
    req: Request<Body>,
    config: Arc<AppConfig>,
    stats_collector: Arc<StatsCollector>,
    http_client: Arc<reqwest::Client>,
    secondary_probe: Option<Arc<SecondaryProbe>>,
    block_height_tracker: Option<Arc<BlockHeightTracker>>,
    all_backends: Arc<Vec<Backend>>,
) -> Result<Response<Body>, Box<dyn std::error::Error + Send + Sync>> {
    let _overall_start_time = std::time::Instant::now(); // To be used later with request_context_timeout

    // 1. Read and limit request body
    let limited_body = hyper::body::Limited::new(req.into_body(), config.max_body_size_bytes);
    let body_bytes = match hyper::body::to_bytes(limited_body).await {
        Ok(bytes) => bytes,
        Err(e) => {
            log::error!("Failed to read request body or limit exceeded: {}", e);
            let mut err_resp = Response::new(Body::from(format!("Request body error: {}", e)));
            *err_resp.status_mut() = if e.is::<hyper::Error>() && e.downcast_ref::<hyper::Error>().map_or(false, |he| he.is_body_write_aborted() || format!("{}", he).contains("Too Large")) { // A bit heuristic for "Too Large"
                 StatusCode::PAYLOAD_TOO_LARGE
            } else {
                 StatusCode::BAD_REQUEST
            };
            return Ok(err_resp);
        }
    };
    
    // 2. Parse Batch Info
    let batch_info = match rpc_utils::parse_batch_info(&body_bytes) {
        Ok(info) => info,
        Err(e) => {
            log::error!("Invalid JSON-RPC request: {}", e);
            let mut err_resp = Response::new(Body::from(format!("Invalid JSON-RPC: {}", e)));
            *err_resp.status_mut() = StatusCode::BAD_REQUEST;
            return Ok(err_resp);
        }
    };

    let display_method = if batch_info.is_batch {
        format!("batch[{}]", batch_info.request_count)
    } else {
        batch_info.methods.get(0).cloned().unwrap_or_else(|| "unknown".to_string())
    };
    log::info!("Received request: Method: {}, IsBatch: {}, NumMethods: {}", display_method, batch_info.is_batch, batch_info.methods.len());

    // 3. Calculate Secondary Delay
    let secondary_delay = calculate_secondary_delay(&batch_info, &secondary_probe, &stats_collector, &config);
    if config.enable_detailed_logs {
        log::debug!("Method: {}, Calculated secondary delay: {:?}", display_method, secondary_delay);
    }

    // 4. Backend Filtering & Expensive Method Routing
    let mut target_backends: Vec<Backend> = (*all_backends).clone(); 

    if batch_info.has_stateful {
        log::debug!("Stateful method detected in request '{}', targeting primary only.", display_method);
        target_backends.retain(|b| b.role == "primary");
    } else {
        // Filter by block height
        if let Some(bht) = &block_height_tracker {
            if config.enable_block_height_tracking { // Check if feature is enabled
                target_backends.retain(|b| {
                    if b.role != "primary" && bht.is_secondary_behind(&b.name) {
                        if config.enable_detailed_logs { log::info!("Skipping secondary {}: behind in block height for request {}", b.name, display_method); }
                        // TODO: Add stat for skipped due to block height
                        false
                    } else { true }
                });
            }
        }
        // Filter by probe availability
        if let Some(sp) = &secondary_probe {
            if config.enable_secondary_probing { // Check if feature is enabled
                target_backends.retain(|b| {
                    if b.role != "primary" && !sp.is_backend_available(&b.name) {
                        if config.enable_detailed_logs { log::info!("Skipping secondary {}: not available via probe for request {}", b.name, display_method); }
                        // TODO: Add stat for skipped due to probe unavailable
                        false
                    } else { true }
                });
            }
        }
    }
    
    let is_req_expensive = batch_info.methods.iter().any(|m| rpc_utils::is_expensive_method(m)) ||
                           batch_info.methods.iter().any(|m| stats_collector.is_expensive_method_by_stats(m)); // Stubbed
    
    if config.enable_expensive_method_routing && is_req_expensive && !batch_info.has_stateful {
        log::debug!("Expensive method detected in request {}. Attempting to route to a secondary.", display_method);
        // TODO: Complex expensive method routing logic.
        // For now, this placeholder doesn't change target_backends.
        // A real implementation would try to find the best secondary or stick to primary if none are suitable.
    }

    // 5. Concurrent Request Dispatch
    let (response_tx, mut response_rx) = mpsc::channel::<BackendResult>(target_backends.len().max(1));
    let mut dispatched_count = 0;

    for backend in target_backends { // target_backends is now filtered
        dispatched_count += 1;
        let task_body_bytes = body_bytes.clone();
        let task_http_client = http_client.clone();
        let task_response_tx = response_tx.clone();
        // task_backend_name, task_backend_url, task_backend_role are cloned from 'backend'
        let task_backend_name = backend.name.clone();
        let task_backend_url = backend.url.clone();
        let task_backend_role = backend.role.clone(); 
        let task_secondary_delay = secondary_delay;
        let task_config_detailed_logs = config.enable_detailed_logs;
        let task_http_timeout = config.http_client_timeout(); // Get Duration from config

        tokio::spawn(async move {
            let backend_req_start_time = std::time::Instant::now();
            
            if task_backend_role != "primary" { 
                if task_config_detailed_logs {
                    log::debug!("Secondary backend {} for request {} delaying for {:?}", task_backend_name, display_method, task_secondary_delay);
                }
                tokio::time::sleep(task_secondary_delay).await;
            }

            let result = task_http_client
                .post(task_backend_url)
                .header("Content-Type", "application/json") 
                // TODO: Copy relevant headers from original request 'req.headers()'
                .body(task_body_bytes)
                .timeout(task_http_timeout) 
                .send()
                .await;
            
            let duration = backend_req_start_time.elapsed();

            match result {
                Ok(resp) => {
                    if task_config_detailed_logs {
                        log::debug!("Backend {} for request {} responded with status {}", task_backend_name, display_method, resp.status());
                    }
                    if task_response_tx.send(BackendResult::Success {
                        backend_name: task_backend_name,
                        response: resp,
                        duration,
                    }).await.is_err() {
                         log::error!("Failed to send success to channel for request {}: receiver dropped", display_method);
                    }
                }
                Err(err) => {
                    if task_config_detailed_logs {
                        log::error!("Backend {} for request {} request failed: {}", task_backend_name, display_method, err);
                    }
                     if task_response_tx.send(BackendResult::Error {
                        backend_name: task_backend_name,
                        error: err,
                        duration,
                    }).await.is_err() {
                        log::error!("Failed to send error to channel for request {}: receiver dropped", display_method);
                    }
                }
            }
        });
    }
    drop(response_tx); 

    if dispatched_count == 0 {
        log::warn!("No backends available to dispatch request for method {}", display_method);
        // TODO: Add stat for no backend available
        let mut err_resp = Response::new(Body::from("No available backends for this request type."));
        *err_resp.status_mut() = StatusCode::SERVICE_UNAVAILABLE;
        return Ok(err_resp);
    }
    
    // Placeholder: return the first received response
    if let Some(first_result) = response_rx.recv().await {
        if config.enable_detailed_logs {
            log::info!("First backend response for request {}: {:?}", display_method, first_result);
        }
        
        match first_result {
            BackendResult::Success { backend_name: _, response: reqwest_resp, duration: _ } => {
                let mut hyper_resp_builder = Response::builder().status(reqwest_resp.status());
                for (name, value) in reqwest_resp.headers().iter() {
                    hyper_resp_builder = hyper_resp_builder.header(name.clone(), value.clone());
                }
                let hyper_resp = hyper_resp_builder
                    .body(Body::wrap_stream(reqwest_resp.bytes_stream()))
                    .unwrap_or_else(|e| {
                        log::error!("Error building response from backend for request {}: {}", display_method, e);
                        let mut err_resp = Response::new(Body::from("Error processing backend response"));
                        *err_resp.status_mut() = StatusCode::INTERNAL_SERVER_ERROR;
                        err_resp
                    });
                return Ok(hyper_resp);
            }
            BackendResult::Error { backend_name, error, duration: _ } => {
                 log::error!("First response for request {} was an error from {}: {}", display_method, backend_name, error);
                 let mut err_resp = Response::new(Body::from(format!("Error from backend {}: {}", backend_name, error)));
                *err_resp.status_mut() = StatusCode::BAD_GATEWAY;
                return Ok(err_resp);
            }
        }
    } else {
        log::error!("No responses received from any dispatched backend for method {}", display_method);
        // TODO: Add stat for no response received
        let mut err_resp = Response::new(Body::from("No response from any backend."));
        *err_resp.status_mut() = StatusCode::GATEWAY_TIMEOUT; 
        return Ok(err_resp);
    }
    // Note: Overall request context timeout and full response aggregation logic are still TODOs.
}
