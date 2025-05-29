use crate::{config::AppConfig, structures::Backend};
use dashmap::DashMap;
use futures_util::{stream::SplitSink, SinkExt, StreamExt};
use log::{debug, error, info, warn};
use serde_json::json;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime},
};
use tokio::{
    net::TcpStream,
    sync::watch,
    task::JoinHandle,
    time::sleep,
};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{protocol::Message as TungsteniteMessage, Error as TungsteniteError},
    MaybeTlsStream, WebSocketStream,
};
use url::Url;

const RECONNECT_DELAY: Duration = Duration::from_secs(10);

#[derive(serde::Deserialize, Debug)]
struct SubscriptionMessage {
    #[allow(dead_code)] // May not be used if only checking method
    jsonrpc: Option<String>,
    method: Option<String>,
    params: Option<SubscriptionParams>,
    result: Option<serde_json::Value>, // For subscription ID confirmation
    id: Option<serde_json::Value>,    // For request echo
}

#[derive(serde::Deserialize, Debug)]
struct SubscriptionParams {
    subscription: String,
    result: HeaderData,
}

#[derive(serde::Deserialize, Debug)]
struct HeaderData {
    number: String, // Hex string like "0x123"
                    // Add other fields like "hash" if ever needed for more advanced logic
}

pub struct BlockHeightTracker {
    config: Arc<AppConfig>,
    backends: Vec<Backend>,
    block_heights: Arc<DashMap<String, u64>>,
    last_update_times: Arc<DashMap<String, SystemTime>>,
    shutdown_tx: watch::Sender<bool>,
    tasks: Arc<Mutex<Vec<JoinHandle<()>>>>,
    enable_detailed_logs: bool,
}

impl BlockHeightTracker {
    pub fn new(
        config: Arc<AppConfig>,
        all_backends: &[Backend],
    ) -> Option<Arc<Self>> {
        if !config.enable_block_height_tracking {
            info!("BlockHeightTracker disabled by configuration.");
            return None;
        }

        info!("Initializing BlockHeightTracker for {} backends.", all_backends.len());
        let (shutdown_tx, _shutdown_rx) = watch::channel(false); // _shutdown_rx cloned by tasks

        Some(Arc::new(Self {
            config: config.clone(),
            backends: all_backends.to_vec(), // Clones the slice into a Vec
            block_heights: Arc::new(DashMap::new()),
            last_update_times: Arc::new(DashMap::new()),
            shutdown_tx,
            tasks: Arc::new(Mutex::new(Vec::new())),
            enable_detailed_logs: config.enable_detailed_logs,
        }))
    }

    pub fn start_monitoring(self: Arc<Self>) {
        if self.backends.is_empty() {
            info!("BHT: No backends configured for monitoring.");
            return;
        }
        info!("BHT: Starting block height monitoring for {} backends.", self.backends.len());
        let mut tasks_guard = self.tasks.lock().unwrap();
        for backend in self.backends.clone() {
            // Only monitor if backend has a URL, primarily for non-primary roles or specific needs
            // For this implementation, we assume all backends in the list are candidates.
            let task_self = self.clone();
            let task_backend = backend.clone(); // Clone backend for the task
            let task_shutdown_rx = self.shutdown_tx.subscribe();
            
            let task = tokio::spawn(async move {
                task_self
                    .monitor_backend_connection(task_backend, task_shutdown_rx)
                    .await;
            });
            tasks_guard.push(task);
        }
    }

    async fn monitor_backend_connection(
        self: Arc<Self>,
        backend: Backend,
        mut shutdown_rx: watch::Receiver<bool>,
    ) {
        info!("BHT: Starting monitoring for backend: {}", backend.name);
        loop { // Outer reconnect loop
            tokio::select! {
                biased;
                _ = shutdown_rx.changed() => {
                    if *shutdown_rx.borrow() {
                        info!("BHT: Shutdown signal received for {}, terminating monitoring.", backend.name);
                        break; // Break outer reconnect loop
                    }
                }
                _ = tokio::time::sleep(Duration::from_millis(10)) => { // Give a chance for shutdown signal before attempting connection
                    // Proceed to connection attempt
                }
            }
             if *shutdown_rx.borrow() { break; }


            let mut ws_url = backend.url.clone();
            let scheme = if backend.url.scheme() == "https" { "wss" } else { "ws" };
            if let Err(_e) = ws_url.set_scheme(scheme) {
                error!("BHT: Failed to set scheme to {} for backend {}: {}", scheme, backend.name, backend.url);
                sleep(RECONNECT_DELAY).await;
                continue;
            }
            
            if self.enable_detailed_logs {
                debug!("BHT: Attempting to connect to {} for backend {}", ws_url, backend.name);
            }

            match connect_async(ws_url.clone()).await {
                Ok((ws_stream, _response)) => {
                    if self.enable_detailed_logs {
                        info!("BHT: Successfully connected to WebSocket for backend: {}", backend.name);
                    }
                    let (mut write, mut read) = ws_stream.split();

                    let subscribe_payload = json!({
                        "jsonrpc": "2.0",
                        "method": "eth_subscribe",
                        "params": ["newHeads"],
                        "id": 1 // Static ID for this subscription
                    });

                    if let Err(e) = write.send(TungsteniteMessage::Text(subscribe_payload.to_string())).await {
                        error!("BHT: Failed to send eth_subscribe to {}: {}. Retrying connection.", backend.name, e);
                        // Connection will be retried by the outer loop after delay
                        sleep(RECONNECT_DELAY).await;
                        continue;
                    }
                    if self.enable_detailed_logs {
                       debug!("BHT: Sent eth_subscribe payload to {}", backend.name);
                    }

                    // Inner message reading loop
                    loop {
                        tokio::select! {
                            biased;
                            _ = shutdown_rx.changed() => {
                                if *shutdown_rx.borrow() {
                                    info!("BHT: Shutdown signal for {}, closing WebSocket and stopping.", backend.name);
                                     // Attempt to close the WebSocket gracefully
                                    let _ = write.send(TungsteniteMessage::Close(None)).await;
                                    break; // Break inner message_read_loop
                                }
                            }
                            maybe_message = read.next() => {
                                match maybe_message {
                                    Some(Ok(message)) => {
                                        match message {
                                            TungsteniteMessage::Text(text_msg) => {
                                                if self.enable_detailed_logs {
                                                    debug!("BHT: Received text from {}: {}", backend.name, text_msg);
                                                }
                                                match serde_json::from_str::<SubscriptionMessage>(&text_msg) {
                                                    Ok(parsed_msg) => {
                                                        if parsed_msg.method.as_deref() == Some("eth_subscription") {
                                                            if let Some(params) = parsed_msg.params {
                                                                let block_num_str = params.result.number;
                                                                match u64::from_str_radix(block_num_str.trim_start_matches("0x"), 16) {
                                                                    Ok(block_num) => {
                                                                        self.block_heights.insert(backend.name.clone(), block_num);
                                                                        self.last_update_times.insert(backend.name.clone(), SystemTime::now());
                                                                        if self.enable_detailed_logs {
                                                                            debug!("BHT: Updated block height for {}: {} (raw: {})", backend.name, block_num, block_num_str);
                                                                        }
                                                                    }
                                                                    Err(e) => error!("BHT: Failed to parse block number hex '{}' for {}: {}", block_num_str, backend.name, e),
                                                                }
                                                            }
                                                        } else if parsed_msg.id == Some(json!(1)) && parsed_msg.result.is_some() {
                                                             if self.enable_detailed_logs {
                                                                info!("BHT: Received subscription confirmation from {}: {:?}", backend.name, parsed_msg.result);
                                                             }
                                                        } else {
                                                            if self.enable_detailed_logs {
                                                                debug!("BHT: Received other JSON message from {}: {:?}", backend.name, parsed_msg);
                                                            }
                                                        }
                                                    }
                                                    Err(e) => {
                                                        if self.enable_detailed_logs {
                                                            warn!("BHT: Failed to parse JSON from {}: {}. Message: {}", backend.name, e, text_msg);
                                                        }
                                                    }
                                                }
                                            }
                                            TungsteniteMessage::Binary(bin_msg) => {
                                                if self.enable_detailed_logs {
                                                    debug!("BHT: Received binary message from {} ({} bytes), ignoring.", backend.name, bin_msg.len());
                                                }
                                            }
                                            TungsteniteMessage::Ping(ping_data) => {
                                                 if self.enable_detailed_logs { debug!("BHT: Received Ping from {}, sending Pong.", backend.name); }
                                                 // tokio-tungstenite handles Pongs automatically by default if feature "rustls-pong" or "native-tls-pong" is enabled.
                                                 // If not, manual send:
                                                 // if let Err(e) = write.send(TungsteniteMessage::Pong(ping_data)).await {
                                                 //    error!("BHT: Failed to send Pong to {}: {}", backend.name, e);
                                                 //    break; // Break inner loop, connection might be unstable
                                                 // }
                                            }
                                            TungsteniteMessage::Pong(_) => { /* Usually no action needed */ }
                                            TungsteniteMessage::Close(_) => {
                                                if self.enable_detailed_logs { info!("BHT: WebSocket closed by server for {}.", backend.name); }
                                                break; // Break inner loop
                                            }
                                            TungsteniteMessage::Frame(_) => { /* Raw frame, usually not handled directly */ }
                                        }
                                    }
                                    Some(Err(e)) => {
                                        match e {
                                            TungsteniteError::ConnectionClosed | TungsteniteError::AlreadyClosed => {
                                                if self.enable_detailed_logs { info!("BHT: WebSocket connection closed for {}.", backend.name); }
                                            }
                                            _ => {
                                                error!("BHT: Error reading from WebSocket for {}: {:?}. Attempting reconnect.", backend.name, e);
                                            }
                                        }
                                        break; // Break inner loop, will trigger reconnect
                                    }
                                    None => {
                                        if self.enable_detailed_logs { info!("BHT: WebSocket stream ended for {}. Attempting reconnect.", backend.name); }
                                        break; // Break inner loop, will trigger reconnect
                                    }
                                }
                            }
                        } // End of inner select
                        if *shutdown_rx.borrow() { break; } // Ensure inner loop breaks if shutdown occurred
                    } // End of inner message reading loop
                }
                Err(e) => {
                    warn!("BHT: Failed to connect to WebSocket for backend {}: {:?}. Retrying after delay.", backend.name, e);
                }
            }
            // If we are here, it means the connection was dropped or failed. Wait before retrying.
             if !*shutdown_rx.borrow() { // Don't sleep if shutting down
                sleep(RECONNECT_DELAY).await;
            }
        } // End of outer reconnect loop
        info!("BHT: Stopped monitoring backend {}.", backend.name);
    }

    pub fn is_secondary_behind(&self, secondary_name: &str) -> bool {
        if !self.config.enable_block_height_tracking { return false; } // If tracking is off, assume not behind

        let primary_info = self.backends.iter().find(|b| b.role == "primary");
        let primary_name = match primary_info {
            Some(b) => b.name.clone(),
            None => {
                if self.enable_detailed_logs {
                    warn!("BHT: No primary backend configured for is_secondary_behind check.");
                }
                return false; 
            }
        };

        let primary_height_opt = self.block_heights.get(&primary_name).map(|h_ref| *h_ref.value());
        
        let primary_height = match primary_height_opt {
            Some(h) => h,
            None => {
                if self.enable_detailed_logs {
                    debug!("BHT: Primary '{}' height unknown for is_secondary_behind check with {}.", primary_name, secondary_name);
                }
                return false; // Primary height unknown, can't reliably determine if secondary is behind
            }
        };

        let secondary_height_opt = self.block_heights.get(secondary_name).map(|h_ref| *h_ref.value());

        match secondary_height_opt {
            Some(secondary_height_val) => {
                if primary_height > secondary_height_val {
                    let diff = primary_height - secondary_height_val;
                    let is_behind = diff > self.config.max_blocks_behind;
                    if self.enable_detailed_logs && is_behind {
                        debug!("BHT: Secondary '{}' (height {}) is behind primary '{}' (height {}). Diff: {}, Max allowed: {}", 
                               secondary_name, secondary_height_val, primary_name, primary_height, diff, self.config.max_blocks_behind);
                    }
                    return is_behind;
                }
                false // Secondary is not behind or is ahead
            }
            None => {
                if self.enable_detailed_logs {
                    debug!("BHT: Secondary '{}' height unknown, considering it behind primary '{}' (height {}).", secondary_name, primary_name, primary_height);
                }
                true // Secondary height unknown, assume it's behind if primary height is known
            }
        }
    }

    pub fn get_block_height_status(&self) -> HashMap<String, u64> {
        self.block_heights
            .iter()
            .map(|entry| (entry.key().clone(), *entry.value()))
            .collect()
    }

    pub async fn stop(&self) {
        info!("BHT: Sending shutdown signal to all monitoring tasks...");
        if self.shutdown_tx.send(true).is_err() {
            error!("BHT: Failed to send shutdown signal. Tasks might not terminate gracefully.");
        }

        let mut tasks_guard = self.tasks.lock().unwrap();
        info!("BHT: Awaiting termination of {} monitoring tasks...", tasks_guard.len());
        for task in tasks_guard.drain(..) {
            if let Err(e) = task.await {
                error!("BHT: Error awaiting task termination: {:?}", e);
            }
        }
        info!("BHT: All monitoring tasks terminated.");
    }
}
