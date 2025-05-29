use crate::structures::{ResponseStats, WebSocketStats, CuDataPoint, Backend};
use crate::block_height_tracker::BlockHeightTracker;
use crate::secondary_probe::SecondaryProbe;
use std::time::{Duration, SystemTime};
use std::sync::{Arc, Mutex, atomic::{AtomicU64, Ordering}};
use dashmap::DashMap;
use log::{debug, error, info, warn};

pub struct StatsCollector {
    pub request_stats: Arc<Mutex<Vec<ResponseStats>>>,
    pub method_stats: Arc<DashMap<String, Mutex<Vec<Duration>>>>, // method_name -> list of durations for primary
    pub backend_method_stats: Arc<DashMap<String, DashMap<String, Mutex<Vec<Duration>>>>>, // backend_name -> method_name -> list of durations
    pub backend_wins: Arc<DashMap<String, AtomicU64>>, // backend_name -> count
    pub method_backend_wins: Arc<DashMap<String, DashMap<String, AtomicU64>>>, // method_name -> backend_name -> count
    pub first_response_durations: Arc<Mutex<Vec<Duration>>>,
    pub actual_first_response_durations: Arc<Mutex<Vec<Duration>>>,
    pub method_first_response_durations: Arc<DashMap<String, Mutex<Vec<Duration>>>>,
    pub method_actual_first_response_durations: Arc<DashMap<String, Mutex<Vec<Duration>>>>,
    pub total_requests: Arc<AtomicU64>>,
    pub error_count: Arc<AtomicU64>>,
    pub skipped_secondary_requests: Arc<AtomicU64>>,
    pub ws_stats: Arc<Mutex<Vec<WebSocketStats>>>,
    pub total_ws_connections: Arc<AtomicU64>>,
    pub app_start_time: SystemTime,
    pub interval_start_time: Arc<Mutex<SystemTime>>,
    pub summary_interval: Duration,
    pub method_cu_prices: Arc<DashMap<String, u64>>,
    pub total_cu: Arc<AtomicU64>>,
    pub method_cu: Arc<DashMap<String, AtomicU64>>, // method_name -> total CU for this method in interval
    pub historical_cu: Arc<Mutex<Vec<CuDataPoint>>>,
    pub has_secondary_backends: bool,
    // Placeholders for probe and tracker - actual types will be defined later
    // pub secondary_probe: Option<Arc<SecondaryProbe>>,
    // pub block_height_tracker: Option<Arc<BlockHeightTracker>>,
}

impl StatsCollector {
    pub fn new(summary_interval: Duration, has_secondary_backends: bool) -> Self {
        let method_cu_prices = Arc::new(DashMap::new());
        Self::init_cu_prices(&method_cu_prices);

        StatsCollector {
            request_stats: Arc::new(Mutex::new(Vec::new())),
            method_stats: Arc::new(DashMap::new()),
            backend_method_stats: Arc::new(DashMap::new()),
            backend_wins: Arc::new(DashMap::new()),
            method_backend_wins: Arc::new(DashMap::new()),
            first_response_durations: Arc::new(Mutex::new(Vec::new())),
            actual_first_response_durations: Arc::new(Mutex::new(Vec::new())),
            method_first_response_durations: Arc::new(DashMap::new()),
            method_actual_first_response_durations: Arc::new(DashMap::new()),
            total_requests: Arc::new(AtomicU64::new(0)),
            error_count: Arc::new(AtomicU64::new(0)),
            skipped_secondary_requests: Arc::new(AtomicU64::new(0)),
            ws_stats: Arc::new(Mutex::new(Vec::new())),
            total_ws_connections: Arc::new(AtomicU64::new(0)),
            app_start_time: SystemTime::now(),
            interval_start_time: Arc::new(Mutex::new(SystemTime::now())),
            summary_interval,
            method_cu_prices,
            total_cu: Arc::new(AtomicU64::new(0)),
            method_cu: Arc::new(DashMap::new()),
            historical_cu: Arc::new(Mutex::new(Vec::new())),
            has_secondary_backends,
        }
    }

    fn init_cu_prices(prices_map: &DashMap<String, u64>) {
        // Base CU
        prices_map.insert("eth_call".to_string(), 100);
        prices_map.insert("eth_estimateGas".to_string(), 150);
        prices_map.insert("eth_getLogs".to_string(), 200);
        prices_map.insert("eth_sendRawTransaction".to_string(), 250);
        prices_map.insert("trace_call".to_string(), 300);
        prices_map.insert("trace_replayBlockTransactions".to_string(), 500);
        // Default for unknown methods
        prices_map.insert("default".to_string(), 50);
    }

    pub fn add_stats(&self, stats_vec: Vec<ResponseStats>) {
        if stats_vec.is_empty() {
            warn!("add_stats called with empty stats_vec");
            return;
        }

        self.total_requests.fetch_add(1, Ordering::Relaxed);

        let mut primary_stats: Option<&ResponseStats> = None;
        let mut winning_backend_name: Option<String> = None;
        let mut actual_first_response_duration: Option<Duration> = None;
        let mut first_response_duration_from_primary_or_fastest_secondary: Option<Duration> = None;

        // Find the 'actual-first-response' if present and the primary response
        for stat in &stats_vec {
            if stat.backend_name == "actual-first-response" {
                actual_first_response_duration = Some(stat.duration);
            } else if stat.backend_name.contains("-primary") { // Assuming primary name contains "-primary"
                primary_stats = Some(stat);
            }
        }
        
        let method_name = primary_stats.map_or_else(
            || stats_vec.first().map_or_else(|| "unknown".to_string(), |s| s.method.clone()),
            |ps| ps.method.clone()
        );


        // Determine winning backend and first_response_duration_from_primary_or_fastest_secondary
        if self.has_secondary_backends {
            let mut fastest_duration = Duration::MAX;
            for stat in stats_vec.iter().filter(|s| s.backend_name != "actual-first-response" && s.error.is_none()) {
                if stat.duration < fastest_duration {
                    fastest_duration = stat.duration;
                    winning_backend_name = Some(stat.backend_name.clone());
                }
            }
            if fastest_duration != Duration::MAX {
                 first_response_duration_from_primary_or_fastest_secondary = Some(fastest_duration);
            }
        } else {
            // If no secondary backends, primary is the winner if no error
            if let Some(ps) = primary_stats {
                if ps.error.is_none() {
                    winning_backend_name = Some(ps.backend_name.clone());
                    first_response_duration_from_primary_or_fastest_secondary = Some(ps.duration);
                }
            }
        }
        
        // If no winner determined yet (e.g. all errored, or no secondary and primary errored),
        // and if primary_stats exists, consider it as the "winner" for error tracking purposes.
        if winning_backend_name.is_none() && primary_stats.is_some() {
            winning_backend_name = Some(primary_stats.unwrap().backend_name.clone());
        }


        // Update backend_wins and method_backend_wins
        if let Some(ref winner_name) = winning_backend_name {
            self.backend_wins.entry(winner_name.clone()).or_insert_with(|| AtomicU64::new(0)).fetch_add(1, Ordering::Relaxed);
            self.method_backend_wins.entry(method_name.clone()).or_default().entry(winner_name.clone()).or_insert_with(|| AtomicU64::new(0)).fetch_add(1, Ordering::Relaxed);
        }

        // Update first_response_durations and actual_first_response_durations
        if let Some(duration) = first_response_duration_from_primary_or_fastest_secondary {
            self.first_response_durations.lock().unwrap().push(duration);
            self.method_first_response_durations.entry(method_name.clone()).or_insert_with(|| Mutex::new(Vec::new())).lock().unwrap().push(duration);
        }

        if let Some(duration) = actual_first_response_duration {
            self.actual_first_response_durations.lock().unwrap().push(duration);
            self.method_actual_first_response_durations.entry(method_name.clone()).or_insert_with(|| Mutex::new(Vec::new())).lock().unwrap().push(duration);
        }


        let mut request_stats_guard = self.request_stats.lock().unwrap();
        for stat in stats_vec {
            if stat.backend_name == "actual-first-response" { // Already handled
                continue;
            }

            request_stats_guard.push(stat.clone());

            if stat.error.is_some() {
                if stat.error.as_deref() == Some("skipped by primary due to min_delay_buffer") {
                    self.skipped_secondary_requests.fetch_add(1, Ordering::Relaxed);
                } else {
                    self.error_count.fetch_add(1, Ordering::Relaxed);
                }
            }

            // Update backend_method_stats for all backends
            self.backend_method_stats
                .entry(stat.backend_name.clone())
                .or_default()
                .entry(stat.method.clone())
                .or_insert_with(|| Mutex::new(Vec::new()))
                .lock()
                .unwrap()
                .push(stat.duration);


            // If the winning backend is primary and it's not a batch (batch handled separately), update method_stats and CUs
            // Assuming primary_stats contains the correct method name for CU calculation
            if let Some(ref winner_name_val) = winning_backend_name {
                 if &stat.backend_name == winner_name_val && stat.backend_name.contains("-primary") && stat.error.is_none() {
                    // Update method_stats (for primary)
                    self.method_stats
                        .entry(stat.method.clone())
                        .or_insert_with(|| Mutex::new(Vec::new()))
                        .lock()
                        .unwrap()
                        .push(stat.duration);

                    // Update CU
                    let cu_price = self.method_cu_prices.get(&stat.method).map_or_else(
                        || self.method_cu_prices.get("default").map_or(0, |p| *p.value()),
                        |p| *p.value()
                    );
                    if cu_price > 0 {
                        self.total_cu.fetch_add(cu_price, Ordering::Relaxed);
                        self.method_cu.entry(stat.method.clone()).or_insert_with(|| AtomicU64::new(0)).fetch_add(cu_price, Ordering::Relaxed);
                    }
                }
            }
        }
    }

    pub fn add_batch_stats(&self, methods: &[String], duration: Duration, backend_name: &str) {
        if !backend_name.contains("-primary") { // Only primary processes batches directly for now
            warn!("add_batch_stats called for non-primary backend: {}", backend_name);
            return;
        }

        let mut batch_cu: u64 = 0;
        for method_name in methods {
            let cu_price = self.method_cu_prices.get(method_name).map_or_else(
                || self.method_cu_prices.get("default").map_or(0, |p| *p.value()),
                |p| *p.value()
            );
            batch_cu += cu_price;

            if cu_price > 0 {
                 self.method_cu.entry(method_name.clone()).or_insert_with(|| AtomicU64::new(0)).fetch_add(cu_price, Ordering::Relaxed);
            }

            // Update method_stats for each method in the batch on the primary
            self.method_stats
                .entry(method_name.clone())
                .or_insert_with(|| Mutex::new(Vec::new()))
                .lock()
                .unwrap()
                .push(duration); // Using the same duration for all methods in the batch as an approximation
            
            // Update backend_method_stats
             self.backend_method_stats
                .entry(backend_name.to_string())
                .or_default()
                .entry(method_name.clone())
                .or_insert_with(|| Mutex::new(Vec::new()))
                .lock()
                .unwrap()
                .push(duration);
        }

        if batch_cu > 0 {
            self.total_cu.fetch_add(batch_cu, Ordering::Relaxed);
        }
        // Note: total_requests is incremented by add_stats which should be called for the overall batch request
    }


    pub fn add_websocket_stats(&self, ws_stat: WebSocketStats) {
        if ws_stat.error.is_some() {
            self.error_count.fetch_add(1, Ordering::Relaxed);
        }
        self.ws_stats.lock().unwrap().push(ws_stat);
        self.total_ws_connections.fetch_add(1, Ordering::Relaxed);
    }

    // STUBBED METHODS - to be implemented later
    pub fn get_primary_p75_for_method(&self, _method: &str) -> std::time::Duration {
        // Placeholder: return a default fixed duration
        log::debug!("StatsCollector::get_primary_p75_for_method called (stub)");
        std::time::Duration::from_millis(25) // Default from Go's calculateBatchDelay fallback
    }

    pub fn get_primary_p50_for_method(&self, _method: &str) -> std::time::Duration {
        // Placeholder: return a default fixed duration
        log::debug!("StatsCollector::get_primary_p50_for_method called (stub)");
        std::time::Duration::from_millis(15) 
    }

    pub fn is_expensive_method_by_stats(&self, _method: &str) -> bool {
        // Placeholder: always return false
        log::debug!("StatsCollector::is_expensive_method_by_stats called (stub)");
        false
    }

    pub fn select_best_secondary_for_expensive_method(
        &self,
        _method: &str,
        _backends: &[Backend],
        _block_height_tracker: &Option<Arc<BlockHeightTracker>>,
        _secondary_probe: &Option<Arc<SecondaryProbe>>,
    ) -> Option<Backend> {
        // Placeholder: always return None
        log::debug!("StatsCollector::select_best_secondary_for_expensive_method called (stub)");
        None
    }
}
