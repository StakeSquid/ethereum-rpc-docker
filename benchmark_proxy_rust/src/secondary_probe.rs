use crate::{
    config::AppConfig,
    structures::{Backend, JsonRpcRequest},
};
use chrono::Utc;
use dashmap::DashMap;
use log::{debug, error, info, warn};
use reqwest::Client;
use serde_json::json;
use std::{
    cmp::min,
    sync::{
        atomic::{AtomicU32, Ordering},
        Arc, Mutex, RwLock,
    },
    time::{Duration, SystemTime},
};
use tokio::sync::watch;

const PROBE_REQUEST_COUNT: usize = 10;
const DEFAULT_MIN_RESPONSE_TIME_MS: u64 = 15;
const PROBE_CYCLE_DELAY_MS: u64 = 10;

pub struct SecondaryProbe {
    config: Arc<AppConfig>,
    backends: Vec<Backend>, // Only secondary backends
    client: Client,
    min_response_time: Arc<RwLock<Duration>>,
    method_timings: Arc<DashMap<String, Duration>>, // method_name -> min_duration
    backend_timings: Arc<DashMap<String, Duration>>, // backend_name -> min_duration
    
    // Health state per backend
    backend_available: Arc<DashMap<String, bool>>,
    backend_error_count: Arc<DashMap<String, AtomicU32>>,
    backend_consecutive_success_count: Arc<DashMap<String, AtomicU32>>, // For recovery
    backend_last_success: Arc<DashMap<String, Mutex<SystemTime>>>,
    
    last_probe_time: Arc<Mutex<SystemTime>>,
    failure_count: Arc<AtomicU32>, // Consecutive overall probe cycle failures
    last_success_time: Arc<Mutex<SystemTime>>, // Last time any probe in an overall cycle succeeded
    
    shutdown_tx: watch::Sender<bool>,
    shutdown_rx: watch::Receiver<bool>,
    enable_detailed_logs: bool,
}

impl SecondaryProbe {
    pub fn new(
        config: Arc<AppConfig>,
        all_backends: &[Backend],
        client: Client,
    ) -> Option<Arc<Self>> {
        let secondary_backends: Vec<Backend> = all_backends
            .iter()
            .filter(|b| b.role.to_lowercase() == "secondary")
            .cloned()
            .collect();

        if secondary_backends.is_empty() {
            info!("No secondary backends configured. SecondaryProbe will not be initialized.");
            return None;
        }

        info!(
            "Initializing SecondaryProbe for {} secondary backends.",
            secondary_backends.len()
        );

        let backend_available = Arc::new(DashMap::new());
        let backend_error_count = Arc::new(DashMap::new());
        let backend_consecutive_success_count = Arc::new(DashMap::new());
        let backend_last_success = Arc::new(DashMap::new());

        for backend in &secondary_backends {
            backend_available.insert(backend.name.clone(), true);
            backend_error_count.insert(backend.name.clone(), AtomicU32::new(0));
            backend_consecutive_success_count.insert(backend.name.clone(), AtomicU32::new(0));
            backend_last_success.insert(backend.name.clone(), Mutex::new(SystemTime::now()));
            info!("  - Backend '{}' ({}) initialized as available.", backend.name, backend.url);
        }

        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        Some(Arc::new(Self {
            config: config.clone(),
            backends: secondary_backends,
            client,
            min_response_time: Arc::new(RwLock::new(Duration::from_millis(
                DEFAULT_MIN_RESPONSE_TIME_MS, // Or load from config if needed
            ))),
            method_timings: Arc::new(DashMap::new()),
            backend_timings: Arc::new(DashMap::new()),
            backend_available,
            backend_error_count,
            backend_consecutive_success_count,
            backend_last_success,
            last_probe_time: Arc::new(Mutex::new(SystemTime::now())),
            failure_count: Arc::new(AtomicU32::new(0)),
            last_success_time: Arc::new(Mutex::new(SystemTime::now())),
            shutdown_tx,
            shutdown_rx, // Receiver is cloneable
            enable_detailed_logs: config.enable_detailed_logs,
        }))
    }

    pub fn start_periodic_probing(self: Arc<Self>) {
        if self.backends.is_empty() {
            info!("No secondary backends to probe. Periodic probing will not start.");
            return;
        }

        info!(
            "Starting periodic probing for {} secondary backends. Probe interval: {}s. Probe methods: {:?}. Max errors: {}, Recovery threshold: {}.",
            self.backends.len(),
            self.config.probe_interval_secs,
            self.config.probe_methods,
            self.config.max_error_threshold,
            self.config.recovery_threshold
        );

        // Run initial probe
        let initial_probe_self = self.clone();
        tokio::spawn(async move {
            if initial_probe_self.enable_detailed_logs {
                debug!("Running initial probe...");
            }
            initial_probe_self.run_probe().await;
            if initial_probe_self.enable_detailed_logs {
                debug!("Initial probe finished.");
            }
        });

        // Start periodic probing task
        let mut interval = tokio::time::interval(self.config.probe_interval());
        let mut shutdown_rx_clone = self.shutdown_rx.clone();

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = interval.tick() => {
                        if self.enable_detailed_logs {
                            debug!("Running periodic probe cycle...");
                        }
                        self.run_probe().await;
                         if self.enable_detailed_logs {
                            debug!("Periodic probe cycle finished.");
                        }
                    }
                    res = shutdown_rx_clone.changed() => {
                         if res.is_err() || *shutdown_rx_clone.borrow() {
                            info!("SecondaryProbe: Shutdown signal received or channel closed, stopping periodic probing.");
                            break;
                        }
                    }
                }
            }
            info!("SecondaryProbe: Periodic probing task has stopped.");
        });
    }

    async fn run_probe(&self) {
        let mut successful_probes_in_overall_cycle = 0;
        let mut temp_method_timings: DashMap<String, Duration> = DashMap::new(); // method_name -> min_duration for this cycle
        let mut temp_backend_timings: DashMap<String, Duration> = DashMap::new(); // backend_name -> min_duration for this cycle
        let mut temp_overall_min_response_time = Duration::MAX;

        for backend in &self.backends {
            let mut backend_cycle_successful_probes = 0;
            let mut backend_cycle_min_duration = Duration::MAX;

            for method_name in &self.config.probe_methods {
                let mut method_min_duration_for_backend_this_cycle = Duration::MAX;

                for i in 0..PROBE_REQUEST_COUNT {
                    let probe_id = format!(
                        "probe-{}-{}-{}-{}",
                        backend.name,
                        method_name,
                        Utc::now().timestamp_nanos_opt().unwrap_or_else(|| SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_nanos() as i64),
                        i
                    );
                    let request_body = JsonRpcRequest {
                        method: method_name.clone(),
                        params: Some(json!([])),
                        id: Some(json!(probe_id)),
                        jsonrpc: Some("2.0".to_string()),
                    };

                    let start_time = SystemTime::now();
                    match self.client.post(backend.url.clone()).json(&request_body).timeout(self.config.http_client_timeout()).send().await {
                        Ok(response) => {
                            let duration = start_time.elapsed().unwrap_or_default();
                            if response.status().is_success() {
                                // TODO: Optionally parse JSON RPC response for error field
                                backend_cycle_successful_probes += 1;
                                successful_probes_in_overall_cycle += 1;

                                method_min_duration_for_backend_this_cycle = min(method_min_duration_for_backend_this_cycle, duration);
                                backend_cycle_min_duration = min(backend_cycle_min_duration, duration);
                                temp_overall_min_response_time = min(temp_overall_min_response_time, duration);
                                
                                if self.enable_detailed_logs {
                                     debug!("Probe success: {} method {} ID {} took {:?}.", backend.name, method_name, probe_id, duration);
                                }
                            } else {
                                if self.enable_detailed_logs {
                                     warn!("Probe failed (HTTP status {}): {} method {} ID {}. Body: {:?}", response.status(), backend.name, method_name, probe_id, response.text().await.unwrap_or_default());
                                }
                            }
                        }
                        Err(e) => {
                            if self.enable_detailed_logs {
                                warn!("Probe error (request failed): {} method {} ID {}: {:?}", backend.name, method_name, probe_id, e);
                            }
                        }
                    }
                    tokio::time::sleep(Duration::from_millis(PROBE_CYCLE_DELAY_MS)).await;
                } // End of PROBE_REQUEST_COUNT loop

                if method_min_duration_for_backend_this_cycle != Duration::MAX {
                    temp_method_timings
                        .entry(method_name.clone())
                        .and_modify(|current_min| *current_min = min(*current_min, method_min_duration_for_backend_this_cycle))
                        .or_insert(method_min_duration_for_backend_this_cycle);
                }
            } // End of probe_methods loop

            if backend_cycle_min_duration != Duration::MAX {
                temp_backend_timings.insert(backend.name.clone(), backend_cycle_min_duration);
            }
            self.update_backend_health(&backend.name, backend_cycle_successful_probes > 0);
            if self.enable_detailed_logs {
                 debug!(
                    "Probe sub-cycle for backend {}: {} successful probes. Min duration for this backend this cycle: {:?}. Current health: available={}",
                    backend.name,
                    backend_cycle_successful_probes,
                    if backend_cycle_min_duration == Duration::MAX { None } else { Some(backend_cycle_min_duration) },
                    self.is_backend_available(&backend.name)
                );
            }
        } // End of backends loop

        // Update overall timings if any probe in the cycle was successful
        if successful_probes_in_overall_cycle > 0 {
            if temp_overall_min_response_time != Duration::MAX {
                let mut min_resp_time_guard = self.min_response_time.write().unwrap();
                *min_resp_time_guard = min(*min_resp_time_guard, temp_overall_min_response_time);
                 if self.enable_detailed_logs {
                    debug!("Global min_response_time updated to: {:?}", *min_resp_time_guard);
                 }
            }

            for entry in temp_method_timings.iter() {
                self.method_timings
                    .entry(entry.key().clone())
                    .and_modify(|current_min| *current_min = min(*current_min, *entry.value()))
                    .or_insert(*entry.value());
                 if self.enable_detailed_logs {
                    debug!("Global method_timing for {} updated/set to: {:?}", entry.key(), *entry.value());
                 }
            }

            for entry in temp_backend_timings.iter() {
                self.backend_timings
                    .entry(entry.key().clone())
                    .and_modify(|current_min| *current_min = min(*current_min, *entry.value()))
                    .or_insert(*entry.value());
                if self.enable_detailed_logs {
                    debug!("Global backend_timing for {} updated/set to: {:?}", entry.key(), *entry.value());
                }
            }
            
            self.failure_count.store(0, Ordering::Relaxed);
            *self.last_success_time.lock().unwrap() = SystemTime::now();
            if self.enable_detailed_logs {
                info!("Overall probe cycle completed with {} successes. Overall failure count reset.", successful_probes_in_overall_cycle);
            }

        } else {
            let prev_failures = self.failure_count.fetch_add(1, Ordering::Relaxed);
            warn!(
                "Overall probe cycle completed with NO successful probes. Overall failure count incremented to {}.",
                 prev_failures + 1
            );
        }

        *self.last_probe_time.lock().unwrap() = SystemTime::now();
    }

    fn update_backend_health(&self, backend_name: &str, is_cycle_success: bool) {
        let current_availability = self.is_backend_available(backend_name);
        let error_count_entry = self.backend_error_count.entry(backend_name.to_string()).or_insert_with(|| AtomicU32::new(0));
        let consecutive_success_entry = self.backend_consecutive_success_count.entry(backend_name.to_string()).or_insert_with(|| AtomicU32::new(0));

        if is_cycle_success {
            error_count_entry.store(0, Ordering::Relaxed);
            consecutive_success_entry.fetch_add(1, Ordering::Relaxed);
            if let Some(mut last_success_guard) = self.backend_last_success.get_mut(backend_name) {
                *last_success_guard.lock().unwrap() = SystemTime::now();
            }

            if !current_availability {
                let successes = consecutive_success_entry.load(Ordering::Relaxed);
                if successes >= self.config.recovery_threshold {
                    self.backend_available.insert(backend_name.to_string(), true);
                    info!("Backend {} recovered and is now AVAILABLE ({} consecutive successes met threshold {}).", backend_name, successes, self.config.recovery_threshold);
                    consecutive_success_entry.store(0, Ordering::Relaxed); // Reset after recovery
                } else {
                    if self.enable_detailed_logs {
                        debug!("Backend {} had a successful probe cycle. Consecutive successes: {}. Needs {} for recovery.", backend_name, successes, self.config.recovery_threshold);
                    }
                }
            } else {
                 if self.enable_detailed_logs {
                    debug!("Backend {} remains available, successful probe cycle.", backend_name);
                 }
            }
        } else { // Probe cycle failed for this backend
            consecutive_success_entry.store(0, Ordering::Relaxed); // Reset consecutive successes on any failure
            let current_errors = error_count_entry.fetch_add(1, Ordering::Relaxed) + 1; // +1 because fetch_add returns previous value

            if current_availability && current_errors >= self.config.max_error_threshold {
                self.backend_available.insert(backend_name.to_string(), false);
                warn!(
                    "Backend {} has become UNAVAILABLE due to {} errors (threshold {}).",
                    backend_name, current_errors, self.config.max_error_threshold
                );
            } else {
                if self.enable_detailed_logs {
                    if current_availability {
                         debug!("Backend {} is still available but error count increased to {}. Max errors before unavailable: {}", backend_name, current_errors, self.config.max_error_threshold);
                    } else {
                        debug!("Backend {} remains UNAVAILABLE, error count now {}.", backend_name, current_errors);
                    }
                }
            }
        }
    }
    
    pub fn get_delay_for_method(&self, method_name: &str) -> Duration {
        let base_delay = self
            .method_timings
            .get(method_name)
            .map(|timing_ref| *timing_ref.value())
            .unwrap_or_else(|| *self.min_response_time.read().unwrap()); // Read lock

        let buffer = Duration::from_millis(self.config.min_delay_buffer_ms);
        let calculated_delay = base_delay.saturating_add(buffer);

        let overall_failures = self.failure_count.load(Ordering::Relaxed);
        // Consider last_success_time to see if failures are recent and persistent
        let time_since_last_overall_success = SystemTime::now()
            .duration_since(*self.last_success_time.lock().unwrap()) // Lock for last_success_time
            .unwrap_or_default();

        // Fallback logic: if many consecutive failures AND last success was long ago
        if overall_failures >= 3 && time_since_last_overall_success > self.config.probe_interval().saturating_mul(3) {
            warn!(
                "Probes failing ({} consecutive, last overall success {:?} ago). Using conservative fixed delay for method {}.",
                overall_failures, time_since_last_overall_success, method_name
            );
            return Duration::from_millis(self.config.min_delay_buffer_ms.saturating_mul(3));
        }
        
        if self.enable_detailed_logs {
            debug!("Delay for method '{}': base {:?}, buffer {:?}, final {:?}", method_name, base_delay, buffer, calculated_delay);
        }
        calculated_delay
    }

    pub fn is_backend_available(&self, backend_name: &str) -> bool {
        self.backend_available
            .get(backend_name)
            .map_or(false, |entry| *entry.value())
    }

    pub fn stop(&self) {
        info!("SecondaryProbe: Sending shutdown signal...");
        if self.shutdown_tx.send(true).is_err() {
            error!("Failed to send shutdown signal to SecondaryProbe task. It might have already stopped or had no receiver.");
        }
    }
}
