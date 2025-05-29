use std::sync::Arc;
use std::time::{Duration, Instant};
use hyper::{Body, Request, Response, StatusCode};
use hyper_tungstenite::HyperWebsocket;
use log;
use tokio_tungstenite::tungstenite::protocol::Message;
use futures_util::{stream::StreamExt, sink::SinkExt};

use crate::config::AppConfig;
use crate::stats_collector::StatsCollector;
use crate::structures::{Backend, WebSocketStats}; // Ensure WebSocketStats has new fields

pub async fn handle_websocket_request(
    mut req: Request<Body>,
    app_config: Arc<AppConfig>,
    stats_collector: Arc<StatsCollector>,
    all_backends: Arc<Vec<Backend>>,
) -> Result<Response<Body>, Box<dyn std::error::Error + Send + Sync + 'static>> {
    let upgrade_start_time = Instant::now();

    // Check for upgrade request
    if !hyper_tungstenite::is_upgrade_request(&req) {
        log::warn!("Not a WebSocket upgrade request");
        let mut resp = Response::new(Body::from("Not a WebSocket upgrade request"));
        *resp.status_mut() = StatusCode::BAD_REQUEST;
        return Ok(resp);
    }

    // Attempt to upgrade the connection
    let (response, websocket) = match hyper_tungstenite::upgrade(&mut req, None) {
        Ok((resp, ws)) => (resp, ws),
        Err(e) => {
            log::error!("WebSocket upgrade failed: {}", e);
            let mut resp = Response::new(Body::from(format!("WebSocket upgrade failed: {}", e)));
            *resp.status_mut() = StatusCode::INTERNAL_SERVER_ERROR; // Or BAD_REQUEST
            return Ok(resp);
        }
    };

    // Spawn a task to handle the WebSocket connection after sending 101
    tokio::spawn(async move {
        match websocket.await {
            Ok(ws_stream) => {
                let client_ws_stream = ws_stream;
                if app_config.enable_detailed_logs {
                    log::info!("Client WebSocket connection established.");
                }
                // Successfully upgraded client connection, now connect to primary backend
                proxy_websocket_to_primary(client_ws_stream, app_config, stats_collector, all_backends).await;
            }
            Err(e) => {
                log::error!("Error awaiting client WebSocket upgrade: {}", e);
                // No actual client WS connection to record stats against other than the failed upgrade attempt
                let stats = WebSocketStats {
                    backend_name: "client_upgrade_failed".to_string(),
                    error: Some(format!("Client WS upgrade await error: {}", e)),
                    connect_time: upgrade_start_time.elapsed(),
                    is_active: false,
                    client_to_backend_messages: 0,
                    backend_to_client_messages: 0,
                };
                stats_collector.add_websocket_stats(stats);
            }
        }
    });

    // Return the 101 Switching Protocols response to the client
    Ok(response)
}

async fn proxy_websocket_to_primary(
    mut client_ws_stream: HyperWebsocket, // Made mutable for close()
    app_config: Arc<AppConfig>,
    stats_collector: Arc<StatsCollector>,
    all_backends: Arc<Vec<Backend>>,
) {
    let connect_to_primary_start_time = Instant::now();
    let mut client_to_backend_msg_count: u64 = 0;
    let mut backend_to_client_msg_count: u64 = 0;
    let mut ws_stats_error: Option<String> = None;
    let mut backend_name_for_stats = "primary_unknown".to_string();

    // 1. Find Primary Backend
    let primary_backend = match all_backends.iter().find(|b| b.role == "primary") {
        Some(pb) => {
            backend_name_for_stats = pb.name.clone();
            pb
        }
        None => {
            log::error!("No primary backend configured for WebSocket proxy.");
            ws_stats_error = Some("No primary backend configured".to_string());
            // Close client connection gracefully if possible
            let _ = client_ws_stream.close(None).await; // HyperWebsocket uses close method
            // Record stats and return
            let stats = WebSocketStats {
                backend_name: backend_name_for_stats,
                error: ws_stats_error,
                connect_time: connect_to_primary_start_time.elapsed(),
                is_active: false,
                client_to_backend_messages,
                backend_to_client_messages,
            };
            stats_collector.add_websocket_stats(stats);
            return;
        }
    };
    
    backend_name_for_stats = primary_backend.name.clone(); // Ensure it's set if primary_backend was found

    // 2. Connect to Primary Backend's WebSocket
    let mut ws_url = primary_backend.url.clone();
    let scheme = if ws_url.scheme() == "https" { "wss" } else { "ws" };
    if ws_url.set_scheme(scheme).is_err() {
        log::error!("Failed to set WebSocket scheme for backend URL: {}", primary_backend.url);
        ws_stats_error = Some(format!("Invalid backend URL scheme for {}", primary_backend.url));
        let _ = client_ws_stream.close(None).await;
        let stats = WebSocketStats {
            backend_name: backend_name_for_stats,
            error: ws_stats_error,
            connect_time: connect_to_primary_start_time.elapsed(),
            is_active: false,
            client_to_backend_messages,
            backend_to_client_messages,
        };
        stats_collector.add_websocket_stats(stats);
        return;
    }

    let backend_connect_attempt_time = Instant::now();
    let backend_ws_result = tokio_tungstenite::connect_async(ws_url.clone()).await;
    let connect_duration = backend_connect_attempt_time.elapsed(); // This is backend connection time

    let backend_ws_stream_conn = match backend_ws_result {
        Ok((stream, _response)) => {
            if app_config.enable_detailed_logs {
                log::info!("Successfully connected to primary backend WebSocket: {}", primary_backend.name);
            }
            stream
        }
        Err(e) => {
            log::error!("Failed to connect to primary backend {} WebSocket: {}", primary_backend.name, e);
            ws_stats_error = Some(format!("Primary backend connect error: {}", e));
            let _ = client_ws_stream.close(None).await; // Close client connection
            let stats = WebSocketStats {
                backend_name: backend_name_for_stats,
                error: ws_stats_error,
                connect_time: connect_duration, 
                is_active: false,
                client_to_backend_messages,
                backend_to_client_messages,
            };
            stats_collector.add_websocket_stats(stats);
            return;
        }
    };
    
    // 3. Proxying Logic
    let (mut client_ws_tx, mut client_ws_rx) = client_ws_stream.split();
    let (mut backend_ws_tx, mut backend_ws_rx) = backend_ws_stream_conn.split();

    let client_to_backend_task = async {
        while let Some(msg_result) = client_ws_rx.next().await {
            match msg_result {
                Ok(msg) => {
                    if app_config.enable_detailed_logs { log::trace!("C->B: {:?}", msg); }
                    if backend_ws_tx.send(msg).await.is_err() { 
                        if app_config.enable_detailed_logs { log::debug!("Error sending to backend, C->B loop breaking."); }
                        break; 
                    }
                    client_to_backend_msg_count += 1;
                }
                Err(e) => {
                    log::warn!("Error reading from client WebSocket: {}", e);
                    // Use a closure to capture `e` by reference for the format macro.
                    ws_stats_error.get_or_insert_with(|| { let e_ref = &e; format!("Client read error: {}", e_ref) });
                    break;
                }
            }
        }
        // Try to close the backend sink gracefully if client read loop ends
        if app_config.enable_detailed_logs { log::debug!("C->B proxy loop finished. Closing backend_ws_tx.");}
        let _ = backend_ws_tx.close().await;
    };

    let backend_to_client_task = async {
        while let Some(msg_result) = backend_ws_rx.next().await {
            match msg_result {
                Ok(msg) => {
                    if app_config.enable_detailed_logs { log::trace!("B->C: {:?}", msg); }
                    if client_ws_tx.send(msg).await.is_err() { 
                        if app_config.enable_detailed_logs { log::debug!("Error sending to client, B->C loop breaking."); }
                        break; 
                    }
                    backend_to_client_msg_count += 1;
                }
                Err(e) => {
                    log::warn!("Error reading from backend WebSocket: {}", e);
                     // Use a closure to capture `e` by reference for the format macro.
                    ws_stats_error.get_or_insert_with(|| { let e_ref = &e; format!("Backend read error: {}", e_ref) });
                    break;
                }
            }
        }
        // Try to close the client sink gracefully if backend read loop ends
        if app_config.enable_detailed_logs { log::debug!("B->C proxy loop finished. Closing client_ws_tx.");}
        let _ = client_ws_tx.close().await;
    };

    // Run both proxy tasks concurrently
    tokio::join!(client_to_backend_task, backend_to_client_task);

    if app_config.enable_detailed_logs {
        log::info!("WebSocket proxying ended for {}. Client->Backend: {}, Backend->Client: {}. Error: {:?}",
            backend_name_for_stats, client_to_backend_msg_count, backend_to_client_msg_count, ws_stats_error);
    }
    
    let final_session_duration = connect_to_primary_start_time.elapsed();

    let final_stats = WebSocketStats {
        backend_name: backend_name_for_stats,
        error: ws_stats_error, 
        connect_time: final_session_duration, 
        is_active: false, // Session is now over
        client_to_backend_messages,
        backend_to_client_messages,
    };
    stats_collector.add_websocket_stats(final_stats);
}
