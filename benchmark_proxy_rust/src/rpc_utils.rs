use crate::structures::{BatchInfo, JsonRpcRequest};
use std::collections::HashSet;
use log;
use serde_json; // Added for parsing

fn get_stateful_methods() -> HashSet<&'static str> {
    [
        "eth_newFilter", "eth_newBlockFilter", "eth_newPendingTransactionFilter",
        "eth_getFilterChanges", "eth_getFilterLogs", "eth_uninstallFilter",
        "eth_subscribe", "eth_unsubscribe", "eth_subscription", // "eth_subscription" is a notification, not a method client calls.
                                                                // But if it appears in a batch for some reason, it's state-related.
    ]
    .iter()
    .cloned()
    .collect()
}

fn get_expensive_methods() -> HashSet<&'static str> {
    [
        // Ethereum Debug API (typically Geth-specific)
        "debug_traceBlockByHash", "debug_traceBlockByNumber", "debug_traceCall", "debug_traceTransaction",
        "debug_storageRangeAt", "debug_getModifiedAccountsByHash", "debug_getModifiedAccountsByNumber",
        // Erigon/OpenEthereum Trace Module (more standard)
        "trace_block", "trace_call", "trace_callMany", "trace_filter", "trace_get", "trace_rawTransaction",
        "trace_replayBlockTransactions", "trace_replayTransaction", "trace_transaction",
        // Specific combinations that might be considered extra expensive
        "trace_replayBlockTransactions#vmTrace", // Example, depends on actual usage if # is method part
        "trace_replayTransaction#vmTrace",
    ]
    .iter()
    .cloned()
    .collect()
}

lazy_static::lazy_static! {
    static ref STATEFUL_METHODS: HashSet<&'static str> = get_stateful_methods();
    static ref EXPENSIVE_METHODS: HashSet<&'static str> = get_expensive_methods();
}

pub fn is_stateful_method(method: &str) -> bool {
    STATEFUL_METHODS.contains(method)
}

pub fn is_expensive_method(method: &str) -> bool {
    EXPENSIVE_METHODS.contains(method)
}

pub fn parse_batch_info(body_bytes: &[u8]) -> Result<BatchInfo, String> {
    if body_bytes.is_empty() {
        return Err("Empty request body".to_string());
    }

    // Try parsing as a batch (array) first
    match serde_json::from_slice::<Vec<JsonRpcRequest>>(body_bytes) {
        Ok(batch_reqs) => {
            if batch_reqs.is_empty() {
                return Err("Empty batch request".to_string());
            }
            let mut methods = Vec::new();
            let mut has_stateful = false;
            for req in &batch_reqs {
                methods.push(req.method.clone());
                if is_stateful_method(&req.method) {
                    has_stateful = true;
                }
            }
            Ok(BatchInfo {
                is_batch: true,
                methods,
                request_count: batch_reqs.len(),
                has_stateful,
            })
        }
        Err(_e_batch) => {
            // If not a batch, try parsing as a single request
            match serde_json::from_slice::<JsonRpcRequest>(body_bytes) {
                Ok(single_req) => Ok(BatchInfo {
                    is_batch: false,
                    methods: vec![single_req.method.clone()],
                    request_count: 1,
                    has_stateful: is_stateful_method(&single_req.method),
                }),
                Err(_e_single) => {
                    // Log the actual errors if needed for debugging, but return a generic one
                    log::debug!("Failed to parse as batch: {}", _e_batch);
                    log::debug!("Failed to parse as single: {}", _e_single);
                    Err("Invalid JSON-RPC request format. Not a valid single request or batch.".to_string())
                }
            }
        }
    }
}
