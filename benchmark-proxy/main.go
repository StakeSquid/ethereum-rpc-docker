// hi

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// Simple structure to extract just the method from JSON-RPC requests
type JSONRPCRequest struct {
	Method string `json:"method"`
}

// BatchInfo contains information about a batch request
type BatchInfo struct {
	IsBatch         bool
	Methods         []string
	RequestCount    int
	HasStateful     bool
	BlockTags       []string // Added to track block tags in batch
	RequiresPrimary bool     // Added to indicate if batch requires primary due to block tags
}

// parseBatchInfo analyzes the request body to extract method information
func parseBatchInfo(body []byte) (*BatchInfo, error) {
	// Check for empty body
	if len(body) == 0 {
		return nil, fmt.Errorf("empty request body")
	}

	// Try parsing as array first (batch request)
	var batchReqs []JSONRPCRequest
	if err := json.Unmarshal(body, &batchReqs); err == nil {
		// It's a batch request
		info := &BatchInfo{
			IsBatch:      true,
			RequestCount: len(batchReqs),
			Methods:      make([]string, 0, len(batchReqs)),
			BlockTags:    make([]string, 0),
		}

		// Extract methods and check for stateful ones
		methodSet := make(map[string]bool) // Track unique methods
		for _, req := range batchReqs {
			if req.Method != "" {
				info.Methods = append(info.Methods, req.Method)
				methodSet[req.Method] = true
				if isStatefulMethod(req.Method) || requiresPrimaryOnlyMethod(req.Method) {
					info.HasStateful = true
				}
			}
		}

		// Extract block tags from the batch
		blockTags, err := parseBlockTagsFromBatch(body)
		if err == nil {
			info.BlockTags = blockTags
			// Check if any block tag requires primary
			for _, tag := range blockTags {
				if requiresPrimaryBackend(tag) {
					info.RequiresPrimary = true
					break
				}
			}
		}

		return info, nil
	}

	// Try parsing as single request
	var singleReq JSONRPCRequest
	if err := json.Unmarshal(body, &singleReq); err == nil {
		info := &BatchInfo{
			IsBatch:      false,
			Methods:      []string{singleReq.Method},
			RequestCount: 1,
			HasStateful:  isStatefulMethod(singleReq.Method) || requiresPrimaryOnlyMethod(singleReq.Method),
			BlockTags:    make([]string, 0),
		}

		// Extract block tag from single request
		reqInfo, err := parseRequestInfo(body)
		if err == nil && reqInfo.BlockTag != "" {
			info.BlockTags = []string{reqInfo.BlockTag}
			info.RequiresPrimary = requiresPrimaryBackend(reqInfo.BlockTag)
		}

		return info, nil
	}

	// Neither batch nor single request
	return nil, fmt.Errorf("invalid JSON-RPC request format")
}

// calculateBatchDelay determines the appropriate delay for a batch request for a specific backend
func calculateBatchDelay(methods []string, backendName string, probe *SecondaryProbe, stats *StatsCollector) time.Duration {
	var maxDelay time.Duration

	for _, method := range methods {
		var delay time.Duration
		if probe != nil {
			delay = probe.getDelayForBackendAndMethod(backendName, method)
		} else {
			delay = stats.GetPrimaryP75ForMethod(method)
		}

		if delay > maxDelay {
			maxDelay = delay
		}
	}

	// If no methods or all unknown, use a default
	if maxDelay == 0 {
		if probe != nil {
			return probe.minResponseTime + probe.minDelayBuffer
		}
		return 15 * time.Millisecond // Default fallback
	}

	return maxDelay
}

// formatMethodList creates a readable string from method list for logging
func formatMethodList(methods []string) string {
	if len(methods) == 0 {
		return "[]"
	}
	if len(methods) <= 3 {
		return fmt.Sprintf("%v", methods)
	}
	// Show first 3 methods + count of remaining
	return fmt.Sprintf("[%s, %s, %s, ... +%d more]",
		methods[0], methods[1], methods[2], len(methods)-3)
}

type Backend struct {
	URL  string
	Name string
	Role string
}

type ResponseStats struct {
	Backend    string
	StatusCode int
	Duration   time.Duration
	Error      error
	Method     string // Added method field
}

// WebSocketStats tracks information about websocket connections
type WebSocketStats struct {
	Backend          string
	Error            error
	ConnectTime      time.Duration
	IsActive         bool
	MessagesSent     int
	MessagesReceived int
}

// CUDataPoint represents a historical CU data point with timestamp
type CUDataPoint struct {
	Timestamp time.Time // End time of the interval
	CU        int
}

// StatsCollector maintains statistics for periodic summaries
type StatsCollector struct {
	mu                                 sync.Mutex
	requestStats                       []ResponseStats
	methodStats                        map[string][]time.Duration            // Track durations by method
	backendMethodStats                 map[string]map[string][]time.Duration // Track durations by backend and method
	backendWins                        map[string]int                        // Track how many times each backend responded first
	methodBackendWins                  map[string]map[string]int             // Track wins per method per backend
	firstResponseDurations             []time.Duration                       // Track durations of first successful responses (from winning backend's perspective)
	actualFirstResponseDurations       []time.Duration                       // Track actual user-experienced durations
	methodFirstResponseDurations       map[string][]time.Duration            // Track first response durations by method (winning backend's perspective)
	methodActualFirstResponseDurations map[string][]time.Duration            // Track actual user-experienced durations by method
	totalRequests                      int
	errorCount                         int
	wsConnections                      []WebSocketStats // Track websocket connections
	totalWsConnections                 int
	appStartTime                       time.Time // Application start time (never reset)
	intervalStartTime                  time.Time // Current interval start time (reset each interval)
	summaryInterval                    time.Duration
	methodCUPrices                     map[string]int    // Map of method names to CU prices
	totalCU                            int               // Total CU earned
	methodCU                           map[string]int    // Track CU earned per method
	historicalCU                       []CUDataPoint     // Historical CU data for different time windows
	hasSecondaryBackends               bool              // Track if secondary backends are configured
	skippedSecondaryRequests           int               // Track how many secondary requests were skipped
	secondaryProbe                     *SecondaryProbe   // Reference to secondary probe
	chainHeadMonitor                   *ChainHeadMonitor // Reference to chain head monitor
}

// SecondaryProbe maintains latency information for secondary backends through active probing
type SecondaryProbe struct {
	mu                 sync.RWMutex
	backends           []Backend
	client             *http.Client
	minResponseTime    time.Duration            // Overall minimum response time
	methodTimings      map[string]time.Duration // Per-method minimum response times
	backendTimings     map[string]time.Duration // Per-backend minimum response times
	lastProbeTime      time.Time
	probeInterval      time.Duration
	minDelayBuffer     time.Duration // Buffer to add to minimum times
	probeMethods       []string
	enableDetailedLogs bool
	failureCount       int       // Track consecutive probe failures
	lastSuccessTime    time.Time // Last time probes succeeded
}

// ChainHeadMonitor monitors chain heads of all backends via WebSocket subscriptions
type ChainHeadMonitor struct {
	mu                 sync.RWMutex
	backends           []Backend
	chainHeads         map[string]*ChainHead // backend name -> chain head info
	primaryChainID     string                // Chain ID of primary backend
	enabledBackends    map[string]bool       // Track which backends are enabled
	blockHashCache     map[string]uint64     // block hash -> block number cache (last 128 blocks from primary)
	blockHashOrder     []string              // ordered list of block hashes (oldest first)
	wsDialer           *websocket.Dialer
	stopChan           chan struct{}
	enableDetailedLogs bool
}

// ChainHead tracks the current head of a backend
type ChainHead struct {
	BlockNumber uint64    // Current block number
	BlockHash   string    // Current block hash
	ChainID     string    // Chain ID
	LastUpdate  time.Time // Last time we received an update
	IsHealthy   bool      // Whether this backend is healthy
	Error       string    // Last error if any
}

// RequestInfo contains parsed information about a JSON-RPC request
type RequestInfo struct {
	Method    string
	BlockTag  string
	HasParams bool
}

// Full JSON-RPC request structure for parsing parameters
type JSONRPCFullRequest struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	ID     interface{}     `json:"id"`
}

// parseRequestInfo extracts detailed information from a JSON-RPC request
func parseRequestInfo(body []byte) (*RequestInfo, error) {
	var req JSONRPCFullRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return nil, err
	}

	info := &RequestInfo{
		Method:    req.Method,
		HasParams: len(req.Params) > 0,
	}

	// Special handling for eth_getLogs
	if req.Method == "eth_getLogs" && info.HasParams {
		blockTags, err := parseEthLogsFilter(req.Params)
		if err == nil && len(blockTags) > 0 {
			// For eth_getLogs, we'll return the first block tag that requires primary routing
			// or "latest" if any of them is "latest"
			for _, tag := range blockTags {
				if requiresPrimaryBackend(tag) || tag == "latest" {
					info.BlockTag = tag
					break
				}
			}
			// If no special tags found but we have tags, use the first one
			if info.BlockTag == "" && len(blockTags) > 0 {
				info.BlockTag = blockTags[0]
			}
		}
		return info, nil
	}

	// Special handling for trace_filter
	if req.Method == "trace_filter" && info.HasParams {
		blockTags, err := parseTraceFilter(req.Params)
		if err == nil && len(blockTags) > 0 {
			// For trace_filter, we'll return the first block tag that requires primary routing
			// or "latest" if any of them is "latest"
			for _, tag := range blockTags {
				if requiresPrimaryBackend(tag) || tag == "latest" {
					info.BlockTag = tag
					break
				}
			}
			// If no special tags found but we have tags, use the first one
			if info.BlockTag == "" && len(blockTags) > 0 {
				info.BlockTag = blockTags[0]
			}
		}
		return info, nil
	}

	// Methods that commonly use block tags
	methodsWithBlockTags := map[string]int{
		"eth_getBalance":                          -1, // last param
		"eth_getCode":                             -1, // last param
		"eth_getTransactionCount":                 -1, // last param
		"eth_getStorageAt":                        -1, // last param
		"eth_call":                                -1, // last param
		"eth_estimateGas":                         -1, // last param
		"eth_getProof":                            -1, // last param
		"eth_getBlockByNumber":                    0,  // first param
		"eth_getBlockTransactionCountByNumber":    0,  // first param
		"eth_getTransactionByBlockNumberAndIndex": 0,  // first param
		"eth_getUncleByBlockNumberAndIndex":       0,  // first param
		"eth_getUncleCountByBlockNumber":          0,  // first param
		// Trace methods that use block tags
		"trace_block":                   0,  // first param (block number/tag)
		"trace_replayBlockTransactions": 0,  // first param (block number/tag)
		"trace_call":                    -1, // last param (block tag)
		// Debug methods that use block tags
		"debug_traceBlockByNumber": 0, // first param (block number/tag)
		"debug_traceCall":          1, // SPECIAL: second param (call object, block tag, trace config)
		// Note: eth_getLogs uses a filter object with fromBlock/toBlock fields,
		// which is handled specially above
		// Note: trace_filter uses a filter object similar to eth_getLogs,
		// which needs special handling
	}

	// Methods that use block hashes as parameters
	methodsWithBlockHashes := map[string]int{
		"eth_getBlockByHash":                    0, // first param
		"eth_getBlockTransactionCountByHash":    0, // first param
		"eth_getTransactionByBlockHashAndIndex": 0, // first param
		"eth_getUncleByBlockHashAndIndex":       0, // first param
		"eth_getUncleCountByBlockHash":          0, // first param
		"debug_traceBlockByHash":                0, // first param
	}

	// Check for block hash methods first
	paramPos, hasBlockHash := methodsWithBlockHashes[req.Method]
	if hasBlockHash && info.HasParams {
		// Parse params as array
		var params []json.RawMessage
		if err := json.Unmarshal(req.Params, &params); err == nil && len(params) > paramPos {
			// Try to parse as string (block hash)
			var blockHash string
			if err := json.Unmarshal(params[paramPos], &blockHash); err == nil {
				info.BlockTag = blockHash
				return info, nil
			}
		}
	}

	paramPos, hasBlockTag := methodsWithBlockTags[req.Method]
	if !hasBlockTag || !info.HasParams {
		return info, nil
	}

	// Parse params as array
	var params []json.RawMessage
	if err := json.Unmarshal(req.Params, &params); err != nil {
		// Not an array, might be object params
		return info, nil
	}

	if len(params) == 0 {
		return info, nil
	}

	// Determine which parameter to check
	var blockTagParam json.RawMessage
	if paramPos == -1 {
		// Last parameter
		blockTagParam = params[len(params)-1]
	} else if paramPos < len(params) {
		// Specific position
		blockTagParam = params[paramPos]
	} else {
		return info, nil
	}

	// Special handling for debug_traceCall where position 1 might be omitted
	// If we're checking position 1 but only have 2 params, the middle param might be omitted
	if req.Method == "debug_traceCall" && paramPos == 1 && len(params) == 2 {
		// With only 2 params, it's likely (call_object, trace_config) without block tag
		// The block tag would default to "latest" on the backend
		info.BlockTag = "latest"
		return info, nil
	}

	// Try to parse as string (block tag)
	var blockTag string
	if err := json.Unmarshal(blockTagParam, &blockTag); err == nil {
		info.BlockTag = blockTag
	}

	return info, nil
}

// parseBlockTagsFromBatch extracts block tags from all requests in a batch
func parseBlockTagsFromBatch(body []byte) ([]string, error) {
	var batchReqs []JSONRPCFullRequest
	if err := json.Unmarshal(body, &batchReqs); err != nil {
		return nil, err
	}

	blockTags := make([]string, 0)
	for _, req := range batchReqs {
		// Special handling for eth_getLogs
		if req.Method == "eth_getLogs" && len(req.Params) > 0 {
			logsTags, err := parseEthLogsFilter(req.Params)
			if err == nil {
				blockTags = append(blockTags, logsTags...)
			}
			continue
		}

		// Special handling for trace_filter
		if req.Method == "trace_filter" && len(req.Params) > 0 {
			traceTags, err := parseTraceFilter(req.Params)
			if err == nil {
				blockTags = append(blockTags, traceTags...)
			}
			continue
		}

		// Regular handling for other methods
		reqBytes, err := json.Marshal(req)
		if err != nil {
			continue
		}

		info, err := parseRequestInfo(reqBytes)
		if err != nil {
			continue
		}

		if info.BlockTag != "" {
			blockTags = append(blockTags, info.BlockTag)
		}
	}

	return blockTags, nil
}

// parseEthLogsFilter extracts block tags from eth_getLogs filter parameter
func parseEthLogsFilter(params json.RawMessage) ([]string, error) {
	// eth_getLogs takes a single filter object parameter
	var paramArray []json.RawMessage
	if err := json.Unmarshal(params, &paramArray); err != nil {
		return nil, err
	}

	if len(paramArray) == 0 {
		return nil, nil
	}

	// Parse the filter object
	var filter struct {
		FromBlock json.RawMessage `json:"fromBlock"`
		ToBlock   json.RawMessage `json:"toBlock"`
	}

	if err := json.Unmarshal(paramArray[0], &filter); err != nil {
		return nil, err
	}

	blockTags := make([]string, 0, 2)

	// Extract fromBlock if present
	if len(filter.FromBlock) > 0 {
		var fromBlock string
		if err := json.Unmarshal(filter.FromBlock, &fromBlock); err == nil && fromBlock != "" {
			blockTags = append(blockTags, fromBlock)
		}
	}

	// Extract toBlock if present
	if len(filter.ToBlock) > 0 {
		var toBlock string
		if err := json.Unmarshal(filter.ToBlock, &toBlock); err == nil && toBlock != "" {
			blockTags = append(blockTags, toBlock)
		}
	}

	return blockTags, nil
}

// parseTraceFilter extracts block tags from trace_filter filter parameter
func parseTraceFilter(params json.RawMessage) ([]string, error) {
	// trace_filter takes a single filter object parameter
	var paramArray []json.RawMessage
	if err := json.Unmarshal(params, &paramArray); err != nil {
		return nil, err
	}

	if len(paramArray) == 0 {
		return nil, nil
	}

	// Parse the filter object
	var filter struct {
		FromBlock json.RawMessage `json:"fromBlock"`
		ToBlock   json.RawMessage `json:"toBlock"`
	}

	if err := json.Unmarshal(paramArray[0], &filter); err != nil {
		return nil, err
	}

	blockTags := make([]string, 0, 2)

	// Extract fromBlock if present
	if len(filter.FromBlock) > 0 {
		var fromBlock string
		if err := json.Unmarshal(filter.FromBlock, &fromBlock); err == nil && fromBlock != "" {
			blockTags = append(blockTags, fromBlock)
		}
	}

	// Extract toBlock if present
	if len(filter.ToBlock) > 0 {
		var toBlock string
		if err := json.Unmarshal(filter.ToBlock, &toBlock); err == nil && toBlock != "" {
			blockTags = append(blockTags, toBlock)
		}
	}

	return blockTags, nil
}

// requiresPrimaryBackend checks if a request must be routed to primary based on block tag
func requiresPrimaryBackend(blockTag string) bool {
	// These block tags must always go to primary
	primaryOnlyTags := map[string]bool{
		"finalized": true,
		"pending":   true,
		"safe":      true,
	}

	return primaryOnlyTags[blockTag]
}

// canUseSecondaryForLatest checks if secondary backend can be used for "latest" block tag
func canUseSecondaryForLatest(blockTag string, backendName string, chainHeadMonitor *ChainHeadMonitor) bool {
	// Only check for "latest" tag
	if blockTag != "latest" {
		// For non-latest tags (like specific block numbers), follow existing rules
		return true
	}

	if chainHeadMonitor == nil {
		// No monitor, can't verify - be conservative
		return false
	}

	// Get chain head status
	chainStatus := chainHeadMonitor.GetStatus()

	primaryHead, primaryExists := chainStatus["primary"]
	if !primaryExists || !primaryHead.IsHealthy {
		// Primary not healthy, allow secondary
		return true
	}

	secondaryHead, secondaryExists := chainStatus[backendName]
	if !secondaryExists || !secondaryHead.IsHealthy {
		// Secondary not healthy
		return false
	}

	// For "latest", secondary must be at EXACTLY the same block height
	return secondaryHead.BlockNumber == primaryHead.BlockNumber
}

// canUseSecondaryForBlockTag checks if secondary backend can be used for a given block tag
func canUseSecondaryForBlockTag(blockTag string, backendName string, chainHeadMonitor *ChainHeadMonitor) bool {
	if chainHeadMonitor == nil {
		// No monitor, can't verify - be conservative
		return false
	}

	// Get chain head status
	chainStatus := chainHeadMonitor.GetStatus()

	primaryHead, primaryExists := chainStatus["primary"]
	if !primaryExists || !primaryHead.IsHealthy {
		// Primary not healthy, allow secondary
		return true
	}

	secondaryHead, secondaryExists := chainStatus[backendName]
	if !secondaryExists || !secondaryHead.IsHealthy {
		// Secondary not healthy
		return false
	}

	// Handle "latest" tag - secondary must be at EXACTLY the same block height
	if blockTag == "latest" {
		return secondaryHead.BlockNumber == primaryHead.BlockNumber
	}

	// Handle "earliest" tag - always allowed
	if blockTag == "earliest" {
		return true
	}

	// Check if it's a block hash (0x followed by 64 hex chars)
	if len(blockTag) == 66 && strings.HasPrefix(blockTag, "0x") {
		// Try to look up the block number from our cache
		if blockNumber, exists := chainHeadMonitor.GetBlockNumberForHash(blockTag); exists {
			// We know this block number, check if secondary has it
			return secondaryHead.BlockNumber >= blockNumber
		}
		// Unknown block hash - be conservative and route to primary
		return false
	}

	// Check if it's a numeric block tag (hex number)
	if strings.HasPrefix(blockTag, "0x") {
		blockNumber, err := strconv.ParseUint(strings.TrimPrefix(blockTag, "0x"), 16, 64)
		if err == nil {
			// Valid block number - check if secondary has reached it
			return secondaryHead.BlockNumber >= blockNumber
		}
	}

	// Unknown block tag format - be conservative
	return false
}

func NewStatsCollector(summaryInterval time.Duration, hasSecondaryBackends bool) *StatsCollector {
	now := time.Now()
	sc := &StatsCollector{
		requestStats:                       make([]ResponseStats, 0, 1000),
		methodStats:                        make(map[string][]time.Duration),
		backendMethodStats:                 make(map[string]map[string][]time.Duration),
		backendWins:                        make(map[string]int),
		methodBackendWins:                  make(map[string]map[string]int),
		firstResponseDurations:             make([]time.Duration, 0, 1000),
		actualFirstResponseDurations:       make([]time.Duration, 0, 1000),
		methodFirstResponseDurations:       make(map[string][]time.Duration),
		methodActualFirstResponseDurations: make(map[string][]time.Duration),
		appStartTime:                       now,
		intervalStartTime:                  now,
		summaryInterval:                    summaryInterval,
		methodCUPrices:                     initCUPrices(), // Initialize CU prices
		methodCU:                           make(map[string]int),
		historicalCU:                       make([]CUDataPoint, 0, 2000), // Store up to ~24 hours of 1-minute intervals
		hasSecondaryBackends:               hasSecondaryBackends,
	}

	// Start the periodic summary goroutine
	go sc.periodicSummary()

	return sc
}

// SetSecondaryProbe sets the secondary probe reference after stats collector is created
func (sc *StatsCollector) SetSecondaryProbe(probe *SecondaryProbe) {
	sc.mu.Lock()
	defer sc.mu.Unlock()
	sc.secondaryProbe = probe
}

// SetChainHeadMonitor sets the chain head monitor reference after stats collector is created
func (sc *StatsCollector) SetChainHeadMonitor(monitor *ChainHeadMonitor) {
	sc.mu.Lock()
	defer sc.mu.Unlock()
	sc.chainHeadMonitor = monitor
}

// NewSecondaryProbe creates a new secondary probe instance
func NewSecondaryProbe(backends []Backend, client *http.Client, probeInterval time.Duration,
	minDelayBuffer time.Duration, probeMethods []string, enableDetailedLogs bool) *SecondaryProbe {

	// Filter only secondary backends
	var secondaryBackends []Backend
	for _, b := range backends {
		if b.Role == "secondary" {
			secondaryBackends = append(secondaryBackends, b)
		}
	}

	if len(secondaryBackends) == 0 {
		return nil
	}

	sp := &SecondaryProbe{
		backends:           secondaryBackends,
		client:             client,
		minResponseTime:    15 * time.Millisecond, // Start with reasonable default
		methodTimings:      make(map[string]time.Duration),
		backendTimings:     make(map[string]time.Duration),
		probeInterval:      probeInterval,
		minDelayBuffer:     minDelayBuffer,
		probeMethods:       probeMethods,
		enableDetailedLogs: enableDetailedLogs,
		lastSuccessTime:    time.Now(),
	}

	// Run initial probe immediately
	go func() {
		sp.runProbe()
		// Then start periodic probing
		sp.startPeriodicProbing()
	}()

	return sp
}

// getDelayForMethod returns the appropriate delay for a given method
func (sp *SecondaryProbe) getDelayForMethod(method string) time.Duration {
	sp.mu.RLock()
	defer sp.mu.RUnlock()

	// If probes have been failing, use a conservative fallback
	if sp.failureCount > 3 && time.Since(sp.lastSuccessTime) > 5*time.Minute {
		return 20 * time.Millisecond // Conservative fallback
	}

	// Use method-specific timing if available
	if timing, exists := sp.methodTimings[method]; exists {
		return timing + sp.minDelayBuffer
	}

	// Fall back to general minimum
	return sp.minResponseTime + sp.minDelayBuffer
}

// getDelayForBackendAndMethod returns the appropriate delay for a specific backend and method
func (sp *SecondaryProbe) getDelayForBackendAndMethod(backend, method string) time.Duration {
	sp.mu.RLock()
	defer sp.mu.RUnlock()

	// Start with backend-specific timing
	delay := sp.minResponseTime
	if backendTiming, exists := sp.backendTimings[backend]; exists {
		delay = backendTiming
	}

	// Use method-specific timing if it's longer
	if methodTiming, exists := sp.methodTimings[method]; exists && methodTiming > delay {
		delay = methodTiming
	}

	return delay + sp.minDelayBuffer
}

// runProbe performs a single probe cycle to all secondary backends
func (sp *SecondaryProbe) runProbe() {
	newMethodTimings := make(map[string]time.Duration)
	newBackendTimings := make(map[string]time.Duration)
	successfulProbes := 0

	for _, backend := range sp.backends {
		backendMin := time.Hour // Start with large value

		for _, method := range sp.probeMethods {
			methodMin := time.Hour // Track minimum for this method on this backend
			methodSuccesses := 0

			// Perform 10 probes for this method and take the minimum
			for probe := 0; probe < 10; probe++ {
				reqBody := []byte(fmt.Sprintf(
					`{"jsonrpc":"2.0","method":"%s","params":[],"id":"probe-%d-%d"}`,
					method, time.Now().UnixNano(), probe,
				))

				req, err := http.NewRequest("POST", backend.URL, bytes.NewReader(reqBody))
				if err != nil {
					continue
				}

				req.Header.Set("Content-Type", "application/json")
				// Ensure connection reuse by setting Connection: keep-alive
				req.Header.Set("Connection", "keep-alive")

				start := time.Now()
				resp, err := sp.client.Do(req)
				duration := time.Since(start)

				if err == nil && resp != nil {
					resp.Body.Close()

					if resp.StatusCode == 200 {
						methodSuccesses++
						successfulProbes++

						// Track minimum for this method on this backend
						if duration < methodMin {
							methodMin = duration
						}

						if sp.enableDetailedLogs {
							log.Printf("Probe %d/10: backend=%s method=%s duration=%s status=%d (min so far: %s)",
								probe+1, backend.Name, method, duration, resp.StatusCode, methodMin)
						}
					}
				}

				// Small delay between probes to avoid overwhelming the backend
				if probe < 9 { // Don't delay after the last probe
					time.Sleep(10 * time.Millisecond)
				}
			}

			// Only use this method's timing if we had successful probes
			if methodSuccesses > 0 && methodMin < time.Hour {
				// Update method timing (use minimum across all backends)
				if currentMin, exists := newMethodTimings[method]; !exists || methodMin < currentMin {
					newMethodTimings[method] = methodMin
				}

				// Track backend minimum
				if methodMin < backendMin {
					backendMin = methodMin
				}

				if sp.enableDetailedLogs {
					log.Printf("Method %s on backend %s: %d/10 successful probes, min duration: %s",
						method, backend.Name, methodSuccesses, methodMin)
				}
			}
		}

		// Store backend minimum if we got any successful probes
		if backendMin < time.Hour {
			newBackendTimings[backend.Name] = backendMin
		}
	}

	// Update timings if we got successful probes
	sp.mu.Lock()
	defer sp.mu.Unlock()

	if successfulProbes > 0 {
		sp.failureCount = 0
		sp.lastSuccessTime = time.Now()

		// Update method timings
		for method, timing := range newMethodTimings {
			sp.methodTimings[method] = timing
		}

		// Update backend timings
		for backend, timing := range newBackendTimings {
			sp.backendTimings[backend] = timing
		}

		// Update overall minimum
		overallMin := time.Hour
		for _, timing := range newBackendTimings {
			if timing < overallMin {
				overallMin = timing
			}
		}
		if overallMin < time.Hour {
			sp.minResponseTime = overallMin
		}

		sp.lastProbeTime = time.Now()

		if sp.enableDetailedLogs {
			log.Printf("Probe complete: min=%s methods=%v backends=%v",
				sp.minResponseTime, sp.methodTimings, sp.backendTimings)
		}
	} else {
		sp.failureCount++
		if sp.enableDetailedLogs {
			log.Printf("Probe failed: consecutive failures=%d", sp.failureCount)
		}
	}
}

// startPeriodicProbing runs probes at regular intervals
func (sp *SecondaryProbe) startPeriodicProbing() {
	ticker := time.NewTicker(sp.probeInterval)
	defer ticker.Stop()

	for range ticker.C {
		sp.runProbe()
	}
}

// initCUPrices initializes the map of method names to their CU prices
func initCUPrices() map[string]int {
	return map[string]int{
		"debug_traceBlockByHash":                  90,
		"debug_traceBlockByNumber":                90,
		"debug_traceCall":                         90,
		"debug_traceTransaction":                  90,
		"debug_storageRangeAt":                    50, // Storage access method
		"eth_accounts":                            0,
		"eth_blockNumber":                         10,
		"eth_call":                                21,
		"eth_chainId":                             0,
		"eth_coinbase":                            0,
		"eth_createAccessList":                    30,
		"eth_estimateGas":                         60,
		"eth_feeHistory":                          15,
		"eth_gasPrice":                            15,
		"eth_getBalance":                          11,
		"eth_getBlockByHash":                      21,
		"eth_getBlockByHash#full":                 60,
		"eth_getBlockByNumber":                    24,
		"eth_getBlockByNumber#full":               60,
		"eth_getBlockReceipts":                    80,
		"eth_getBlockTransactionCountByHash":      15,
		"eth_getBlockTransactionCountByNumber":    11,
		"eth_getCode":                             24,
		"eth_getFilterChanges":                    20,
		"eth_getFilterLogs":                       60,
		"eth_getLogs":                             60,
		"eth_getProof":                            11,
		"eth_getStorageAt":                        14,
		"eth_getTransactionByBlockHashAndIndex":   19,
		"eth_getTransactionByBlockNumberAndIndex": 13,
		"eth_getTransactionByHash":                11,
		"eth_getTransactionCount":                 11,
		"eth_getTransactionReceipt":               30,
		"eth_getUncleByBlockHashAndIndex":         15,
		"eth_getUncleByBlockNumberAndIndex":       15,
		"eth_getUncleCountByBlockHash":            15,
		"eth_getUncleCountByBlockNumber":          15,
		"eth_hashrate":                            0,
		"eth_maxPriorityFeePerGas":                16,
		"eth_mining":                              0,
		"eth_newBlockFilter":                      20,
		"eth_newFilter":                           20,
		"eth_newPendingTransactionFilter":         20,
		"eth_protocolVersion":                     0,
		"eth_sendRawTransaction":                  90,
		"eth_syncing":                             0,
		"eth_subscribe":                           10,
		"eth_subscription":                        25, // For "Notifications from the events you've subscribed to"
		"eth_uninstallFilter":                     10,
		"eth_unsubscribe":                         10,
		"net_listening":                           0,
		"net_peerCount":                           0,
		"net_version":                             0,
		"trace_block":                             90,
		"trace_call":                              60,
		"trace_callMany":                          90,
		"trace_filter":                            75,
		"trace_get":                               20,
		"trace_rawTransaction":                    75,
		"trace_replayBlockTransactions":           90,
		"trace_replayBlockTransactions#vmTrace":   300,
		"trace_replayTransaction":                 90,
		"trace_replayTransaction#vmTrace":         300,
		"trace_transaction":                       90,
		"txpool_content":                          1000,
		"web3_clientVersion":                      0,
		"web3_sha3":                               10,
		"bor_getAuthor":                           10,
		"bor_getCurrentProposer":                  10,
		"bor_getCurrentValidators":                10,
		"bor_getRootHash":                         10,
		"bor_getSignersAtHash":                    10,
	}
}

func (sc *StatsCollector) AddStats(stats []ResponseStats, totalDuration time.Duration) {
	sc.mu.Lock()
	defer sc.mu.Unlock()

	// Find the fastest successful response and actual first response
	var fastestBackend string
	var fastestDuration time.Duration = time.Hour // Initialize with a very large duration
	var actualFirstDuration time.Duration
	var method string
	var hasActualFirst bool

	for _, stat := range stats {
		if stat.Backend == "actual-first-response" {
			actualFirstDuration = stat.Duration
			hasActualFirst = true
			method = stat.Method
		} else if stat.Error == nil && stat.Duration < fastestDuration {
			fastestDuration = stat.Duration
			fastestBackend = stat.Backend
			if method == "" {
				method = stat.Method
			}
		}
	}

	// Track the win if we found a successful response
	if fastestBackend != "" {
		sc.backendWins[fastestBackend]++

		// Track wins per method
		if _, exists := sc.methodBackendWins[method]; !exists {
			sc.methodBackendWins[method] = make(map[string]int)
		}
		sc.methodBackendWins[method][fastestBackend]++

		// Track first response duration (from winning backend's perspective)
		sc.firstResponseDurations = append(sc.firstResponseDurations, fastestDuration)

		// Track first response duration by method
		if _, exists := sc.methodFirstResponseDurations[method]; !exists {
			sc.methodFirstResponseDurations[method] = make([]time.Duration, 0, 100)
		}
		sc.methodFirstResponseDurations[method] = append(sc.methodFirstResponseDurations[method], fastestDuration)

		// Track actual first response duration if available
		if hasActualFirst {
			sc.actualFirstResponseDurations = append(sc.actualFirstResponseDurations, actualFirstDuration)

			if _, exists := sc.methodActualFirstResponseDurations[method]; !exists {
				sc.methodActualFirstResponseDurations[method] = make([]time.Duration, 0, 100)
			}
			sc.methodActualFirstResponseDurations[method] = append(sc.methodActualFirstResponseDurations[method], actualFirstDuration)
		}
	}

	// Add stats to the collection (skip actual-first-response as it's synthetic)
	for _, stat := range stats {
		if stat.Backend == "actual-first-response" {
			continue // Don't add synthetic entries to regular stats
		}

		sc.requestStats = append(sc.requestStats, stat)
		if stat.Error != nil {
			// Don't count skipped secondary backends as errors
			if !strings.Contains(stat.Error.Error(), "skipped - primary responded") {
				sc.errorCount++
			} else {
				// Track that we skipped a secondary request
				sc.skippedSecondaryRequests++
			}
		}

		// Track method-specific stats for all backends
		if stat.Error == nil {
			// Initialize backend map if not exists
			if _, exists := sc.backendMethodStats[stat.Backend]; !exists {
				sc.backendMethodStats[stat.Backend] = make(map[string][]time.Duration)
			}

			// Initialize method array if not exists
			if _, exists := sc.backendMethodStats[stat.Backend][stat.Method]; !exists {
				sc.backendMethodStats[stat.Backend][stat.Method] = make([]time.Duration, 0, 100)
			}

			// Add the duration
			sc.backendMethodStats[stat.Backend][stat.Method] = append(
				sc.backendMethodStats[stat.Backend][stat.Method], stat.Duration)

			// Keep tracking primary backend in the old way for backward compatibility
			if stat.Backend == "primary" {
				// Handle batch requests specially for CU calculation
				if strings.HasPrefix(stat.Method, "batch[") && len(stat.Method) > 6 {
					// Don't track batch as a method, it will be handled separately
				} else {
					if _, exists := sc.methodStats[stat.Method]; !exists {
						sc.methodStats[stat.Method] = make([]time.Duration, 0, 100)
					}
					sc.methodStats[stat.Method] = append(sc.methodStats[stat.Method], stat.Duration)

					// Add CU for this method
					cuValue := sc.methodCUPrices[stat.Method]
					sc.totalCU += cuValue
					sc.methodCU[stat.Method] += cuValue
				}
			}
		}
	}

	sc.totalRequests++
}

// AddBatchStats adds statistics for a batch request
func (sc *StatsCollector) AddBatchStats(methods []string, duration time.Duration, backend string) {
	sc.mu.Lock()
	defer sc.mu.Unlock()

	// Calculate total CU for the batch
	batchCU := 0
	for _, method := range methods {
		if method != "" {
			cuValue := sc.methodCUPrices[method]
			batchCU += cuValue

			// Track individual method CU
			sc.methodCU[method] += cuValue

			// Track method durations (use batch duration for each method)
			if _, exists := sc.methodStats[method]; !exists {
				sc.methodStats[method] = make([]time.Duration, 0, 100)
			}
			sc.methodStats[method] = append(sc.methodStats[method], duration)
		}
	}

	sc.totalCU += batchCU
}

func (sc *StatsCollector) AddWebSocketStats(stats WebSocketStats) {
	sc.mu.Lock()
	defer sc.mu.Unlock()

	sc.wsConnections = append(sc.wsConnections, stats)
	sc.totalWsConnections++

	if stats.Error != nil {
		sc.errorCount++
	}
}

func (sc *StatsCollector) periodicSummary() {
	ticker := time.NewTicker(sc.summaryInterval)
	defer ticker.Stop()

	for range ticker.C {
		sc.printSummary()
	}
}

// formatDuration formats a duration with at most 6 significant digits total
func formatDuration(d time.Duration) string {
	// Convert to string with standard formatting
	str := d.String()

	// Find the decimal point if it exists
	decimalIdx := strings.Index(str, ".")
	if decimalIdx == -1 {
		// No decimal point, return as is (already ≤ 6 digits or no need to truncate)
		return str
	}

	// Find the unit suffix (ms, µs, etc.)
	unitIdx := -1
	for i := decimalIdx; i < len(str); i++ {
		if !(str[i] >= '0' && str[i] <= '9') && str[i] != '.' {
			unitIdx = i
			break
		}
	}

	if unitIdx == -1 {
		unitIdx = len(str) // No unit suffix found
	}

	// Count digits before decimal (not including sign)
	digitsBeforeDecimal := 0
	for i := 0; i < decimalIdx; i++ {
		if str[i] >= '0' && str[i] <= '9' {
			digitsBeforeDecimal++
		}
	}

	// Calculate how many decimal places we can keep (allowing for 6 total digits)
	maxDecimalPlaces := 6 - digitsBeforeDecimal
	if maxDecimalPlaces <= 0 {
		// No room for decimal places
		return str[:decimalIdx] + str[unitIdx:]
	}

	// Calculate end position for truncation
	endPos := decimalIdx + 1 + maxDecimalPlaces
	if endPos > unitIdx {
		endPos = unitIdx
	}

	// Return truncated string
	return str[:endPos] + str[unitIdx:]
}

func (sc *StatsCollector) printSummary() {
	sc.mu.Lock()
	defer sc.mu.Unlock()

	uptime := time.Since(sc.appStartTime)
	fmt.Printf("\n=== BENCHMARK PROXY SUMMARY ===\n")
	fmt.Printf("Uptime: %s\n", uptime.Round(time.Second))
	fmt.Printf("Total HTTP Requests: %d\n", sc.totalRequests)
	fmt.Printf("Total WebSocket Connections: %d\n", sc.totalWsConnections)
	fmt.Printf("Error Rate: %.2f%%\n", float64(sc.errorCount)/float64(sc.totalRequests+sc.totalWsConnections)*100)

	// Display secondary probe information if available
	if sc.secondaryProbe != nil {
		sc.secondaryProbe.mu.RLock()
		fmt.Printf("\n--- Secondary Probe Status ---\n")
		fmt.Printf("Minimum Secondary Latency: %s\n", formatDuration(sc.secondaryProbe.minResponseTime))
		fmt.Printf("Probe Buffer: %s\n", formatDuration(sc.secondaryProbe.minDelayBuffer))
		fmt.Printf("Effective Delay Threshold: %s\n", formatDuration(sc.secondaryProbe.minResponseTime+sc.secondaryProbe.minDelayBuffer))

		if len(sc.secondaryProbe.methodTimings) > 0 {
			fmt.Printf("Method-Specific Thresholds:\n")
			// Sort methods for consistent output
			var methods []string
			for method := range sc.secondaryProbe.methodTimings {
				methods = append(methods, method)
			}
			sort.Strings(methods)
			for _, method := range methods {
				timing := sc.secondaryProbe.methodTimings[method]
				fmt.Printf("  %s: %s (+ %s buffer = %s)\n",
					method,
					formatDuration(timing),
					formatDuration(sc.secondaryProbe.minDelayBuffer),
					formatDuration(timing+sc.secondaryProbe.minDelayBuffer))
			}
		}

		if len(sc.secondaryProbe.backendTimings) > 0 {
			fmt.Printf("Backend-Specific Minimum Latencies:\n")
			// Sort backend names for consistent output
			var backendNames []string
			for backend := range sc.secondaryProbe.backendTimings {
				backendNames = append(backendNames, backend)
			}
			sort.Strings(backendNames)
			for _, backend := range backendNames {
				timing := sc.secondaryProbe.backendTimings[backend]
				fmt.Printf("  %s: %s (+ %s buffer = %s)\n",
					backend,
					formatDuration(timing),
					formatDuration(sc.secondaryProbe.minDelayBuffer),
					formatDuration(timing+sc.secondaryProbe.minDelayBuffer))
			}
		}

		if sc.secondaryProbe.failureCount > 0 {
			fmt.Printf("Probe Failures: %d consecutive\n", sc.secondaryProbe.failureCount)
		}

		sc.secondaryProbe.mu.RUnlock()
	}

	// Display chain head monitor information if available
	if sc.chainHeadMonitor != nil {
		fmt.Printf("\n--- Chain Head Monitor Status ---\n")
		chainStatus := sc.chainHeadMonitor.GetStatus()

		// Get primary block height for comparison
		var primaryBlockHeight uint64
		if primaryHead, exists := chainStatus["primary"]; exists && primaryHead.IsHealthy {
			primaryBlockHeight = primaryHead.BlockNumber
		}

		// Sort backend names for consistent output
		var backendNames []string
		for name := range chainStatus {
			backendNames = append(backendNames, name)
		}
		sort.Strings(backendNames)

		for _, name := range backendNames {
			head := chainStatus[name]
			status := "healthy"
			details := fmt.Sprintf("block %d, chain %s", head.BlockNumber, head.ChainID)

			// Add block difference info for secondary backends
			if name != "primary" && primaryBlockHeight > 0 && head.IsHealthy {
				diff := int64(head.BlockNumber) - int64(primaryBlockHeight)
				if diff > 0 {
					details += fmt.Sprintf(" (+%d ahead)", diff)
				} else if diff < 0 {
					details += fmt.Sprintf(" (%d behind)", diff)
				} else {
					details += " (in sync)"
				}
			}

			if !head.IsHealthy {
				status = "unhealthy"
				details = head.Error
			} else if sc.chainHeadMonitor.IsBackendHealthy(name) {
				status = "enabled"
			} else {
				status = "disabled"
			}

			fmt.Printf("  %s: %s (%s)\n", name, status, details)
		}

		// Show block hash cache stats
		sc.chainHeadMonitor.mu.RLock()
		cacheSize := len(sc.chainHeadMonitor.blockHashCache)
		sc.chainHeadMonitor.mu.RUnlock()
		fmt.Printf("  Block hash cache: %d entries (max 128)\n", cacheSize)
	}

	if sc.hasSecondaryBackends && sc.skippedSecondaryRequests > 0 {
		fmt.Printf("Skipped Secondary Requests: %d (%.1f%% of requests)\n",
			sc.skippedSecondaryRequests,
			float64(sc.skippedSecondaryRequests)/float64(sc.totalRequests)*100)
	}
	fmt.Printf("Total Compute Units Earned (current interval): %d CU\n", sc.totalCU)

	// Calculate and display CU for different time windows
	timeWindows := []struct {
		duration time.Duration
		label    string
	}{
		{10 * time.Minute, "Last 10 minutes"},
		{1 * time.Hour, "Last hour"},
		{3 * time.Hour, "Last 3 hours"},
		{24 * time.Hour, "Last 24 hours"},
	}

	fmt.Printf("\nHistorical Compute Units:\n")
	for _, window := range timeWindows {
		actualCU, needsExtrapolation := sc.calculateCUForTimeWindow(window.duration)

		if needsExtrapolation {
			// Calculate actual data duration for extrapolation
			now := time.Now()
			cutoff := now.Add(-window.duration)
			var oldestDataStartTime time.Time
			hasData := false

			// Check current interval
			if sc.intervalStartTime.After(cutoff) {
				oldestDataStartTime = sc.intervalStartTime
				hasData = true
			}

			// Check historical data
			for i := len(sc.historicalCU) - 1; i >= 0; i-- {
				point := sc.historicalCU[i]
				intervalStart := point.Timestamp.Add(-sc.summaryInterval)

				if point.Timestamp.Before(cutoff) {
					break
				}

				if !hasData || intervalStart.Before(oldestDataStartTime) {
					oldestDataStartTime = intervalStart
				}
				hasData = true
			}

			var actualDuration time.Duration
			if hasData {
				actualDuration = now.Sub(oldestDataStartTime)
			}

			extrapolatedCU := sc.extrapolateCU(actualCU, actualDuration, window.duration)
			fmt.Printf("  %s: %s\n", window.label, formatCUWithExtrapolation(extrapolatedCU, true))
		} else {
			fmt.Printf("  %s: %s\n", window.label, formatCUWithExtrapolation(actualCU, false))
		}
	}

	// Calculate response time statistics for primary backend
	var primaryDurations []time.Duration
	for _, stat := range sc.requestStats {
		if stat.Backend == "primary" && stat.Error == nil {
			primaryDurations = append(primaryDurations, stat.Duration)
		}
	}

	if len(primaryDurations) > 0 {
		sort.Slice(primaryDurations, func(i, j int) bool {
			return primaryDurations[i] < primaryDurations[j]
		})

		var sum time.Duration
		for _, d := range primaryDurations {
			sum += d
		}

		avg := sum / time.Duration(len(primaryDurations))
		min := primaryDurations[0]
		max := primaryDurations[len(primaryDurations)-1]

		p50idx := len(primaryDurations) * 50 / 100
		p90idx := len(primaryDurations) * 90 / 100
		p99idx := minInt(len(primaryDurations)-1, len(primaryDurations)*99/100)

		p50 := primaryDurations[p50idx]
		p90 := primaryDurations[p90idx]
		p99 := primaryDurations[p99idx]

		fmt.Printf("\nPrimary Backend Response Times:\n")
		fmt.Printf("  Min: %s\n", formatDuration(min))
		fmt.Printf("  Avg: %s\n", formatDuration(avg))
		fmt.Printf("  Max: %s\n", formatDuration(max))
		fmt.Printf("  p50: %s\n", formatDuration(p50))
		fmt.Printf("  p90: %s\n", formatDuration(p90))
		fmt.Printf("  p99: %s\n", formatDuration(p99))
	}

	// Calculate response time statistics for ALL backends
	backendDurations := make(map[string][]time.Duration)
	for _, stat := range sc.requestStats {
		if stat.Error == nil {
			backendDurations[stat.Backend] = append(backendDurations[stat.Backend], stat.Duration)
		}
	}

	// Sort backend names for consistent output
	var backendNames []string
	for backend := range backendDurations {
		backendNames = append(backendNames, backend)
	}
	sort.Strings(backendNames)

	// Print per-backend statistics
	fmt.Printf("\nPer-Backend Response Time Comparison:\n")
	fmt.Printf("Note: 'User Latency' = actual time users wait; 'Backend Time' = winning backend's response time\n")
	fmt.Printf("%-20s %10s %10s %10s %10s %10s %10s %10s\n",
		"Backend", "Count", "Min", "Avg", "Max", "p50", "p90", "p99")
	fmt.Printf("%s\n", strings.Repeat("-", 100))

	// First, show the actual user latency if available
	if len(sc.actualFirstResponseDurations) > 0 {
		actualDurations := make([]time.Duration, len(sc.actualFirstResponseDurations))
		copy(actualDurations, sc.actualFirstResponseDurations)

		sort.Slice(actualDurations, func(i, j int) bool {
			return actualDurations[i] < actualDurations[j]
		})

		var sum time.Duration
		for _, d := range actualDurations {
			sum += d
		}

		avg := sum / time.Duration(len(actualDurations))
		min := actualDurations[0]
		max := actualDurations[len(actualDurations)-1]

		p50idx := len(actualDurations) * 50 / 100
		p90idx := len(actualDurations) * 90 / 100
		p99idx := minInt(len(actualDurations)-1, len(actualDurations)*99/100)

		p50 := actualDurations[p50idx]
		p90 := actualDurations[p90idx]
		p99 := actualDurations[p99idx]

		fmt.Printf("%-20s %10d %10s %10s %10s %10s %10s %10s\n",
			"User Latency", len(actualDurations),
			formatDuration(min), formatDuration(avg), formatDuration(max),
			formatDuration(p50), formatDuration(p90), formatDuration(p99))
	}

	// Then show the backend time (what backend actually took)
	if len(sc.firstResponseDurations) > 0 {
		firstRespDurations := make([]time.Duration, len(sc.firstResponseDurations))
		copy(firstRespDurations, sc.firstResponseDurations)

		sort.Slice(firstRespDurations, func(i, j int) bool {
			return firstRespDurations[i] < firstRespDurations[j]
		})

		var sum time.Duration
		for _, d := range firstRespDurations {
			sum += d
		}

		avg := sum / time.Duration(len(firstRespDurations))
		min := firstRespDurations[0]
		max := firstRespDurations[len(firstRespDurations)-1]

		p50idx := len(firstRespDurations) * 50 / 100
		p90idx := len(firstRespDurations) * 90 / 100
		p99idx := minInt(len(firstRespDurations)-1, len(firstRespDurations)*99/100)

		p50 := firstRespDurations[p50idx]
		p90 := firstRespDurations[p90idx]
		p99 := firstRespDurations[p99idx]

		fmt.Printf("%-20s %10d %10s %10s %10s %10s %10s %10s\n",
			"Backend Time", len(firstRespDurations),
			formatDuration(min), formatDuration(avg), formatDuration(max),
			formatDuration(p50), formatDuration(p90), formatDuration(p99))
		fmt.Printf("%s\n", strings.Repeat("-", 100))
	}

	for _, backend := range backendNames {
		durations := backendDurations[backend]
		if len(durations) == 0 {
			continue
		}

		sort.Slice(durations, func(i, j int) bool {
			return durations[i] < durations[j]
		})

		var sum time.Duration
		for _, d := range durations {
			sum += d
		}

		avg := sum / time.Duration(len(durations))
		min := durations[0]
		max := durations[len(durations)-1]

		p50idx := len(durations) * 50 / 100
		p90idx := len(durations) * 90 / 100
		p99idx := minInt(len(durations)-1, len(durations)*99/100)

		p50 := durations[p50idx]
		p90 := durations[p90idx]
		p99 := durations[p99idx]

		fmt.Printf("%-20s %10d %10s %10s %10s %10s %10s %10s\n",
			backend, len(durations),
			formatDuration(min), formatDuration(avg), formatDuration(max),
			formatDuration(p50), formatDuration(p90), formatDuration(p99))
	}

	// Print backend wins statistics
	fmt.Printf("\nBackend First Response Wins:\n")
	fmt.Printf("%-20s %10s %10s\n", "Backend", "Wins", "Win %")
	fmt.Printf("%s\n", strings.Repeat("-", 42))

	totalWins := 0
	for _, wins := range sc.backendWins {
		totalWins += wins
	}

	// Sort backends by wins for consistent output
	type backendWin struct {
		backend string
		wins    int
	}
	var winList []backendWin
	for backend, wins := range sc.backendWins {
		winList = append(winList, backendWin{backend, wins})
	}
	sort.Slice(winList, func(i, j int) bool {
		return winList[i].wins > winList[j].wins
	})

	for _, bw := range winList {
		winPercentage := float64(bw.wins) / float64(totalWins) * 100
		fmt.Printf("%-20s %10d %9.1f%%\n", bw.backend, bw.wins, winPercentage)
	}

	// Print per-method statistics
	if len(sc.methodStats) > 0 {
		fmt.Printf("\nPer-Method Statistics (Primary Backend):\n")

		// Sort methods by name for consistent output
		methods := make([]string, 0, len(sc.methodStats))
		for method := range sc.methodStats {
			methods = append(methods, method)
		}
		sort.Strings(methods)

		for _, method := range methods {
			var durations []time.Duration
			var displayLabel string

			// If secondary backends are configured and we have actual user latency data, use that
			if sc.hasSecondaryBackends {
				if actualDurations, exists := sc.methodActualFirstResponseDurations[method]; exists && len(actualDurations) > 0 {
					durations = make([]time.Duration, len(actualDurations))
					copy(durations, actualDurations)
					displayLabel = method + " (User Latency)"
				} else {
					// Fall back to primary backend times if no actual latency data
					durations = sc.methodStats[method]
					displayLabel = method + " (Primary Backend)"
				}
			} else {
				// No secondary backends, use primary backend times
				durations = sc.methodStats[method]
				displayLabel = method
			}

			if len(durations) == 0 {
				continue
			}

			sort.Slice(durations, func(i, j int) bool {
				return durations[i] < durations[j]
			})

			var sum time.Duration
			for _, d := range durations {
				sum += d
			}

			avg := sum / time.Duration(len(durations))
			minDuration := durations[0]
			max := durations[len(durations)-1]

			// Only calculate percentiles if we have enough samples
			p50 := minDuration
			p90 := minDuration
			p99 := minDuration

			if len(durations) >= 2 {
				p50idx := len(durations) * 50 / 100
				p90idx := len(durations) * 90 / 100
				p99idx := minInt(len(durations)-1, len(durations)*99/100)

				p50 = durations[p50idx]
				p90 = durations[p90idx]
				p99 = durations[p99idx]
			}

			// Add CU information to the output
			cuPrice := sc.methodCUPrices[method]
			cuEarned := sc.methodCU[method]

			fmt.Printf("  %-50s Count: %-5d Avg: %-10s Min: %-10s Max: %-10s p50: %-10s p90: %-10s p99: %-10s CU: %d (%d)\n",
				displayLabel, len(durations),
				formatDuration(avg), formatDuration(minDuration), formatDuration(max),
				formatDuration(p50), formatDuration(p90), formatDuration(p99),
				cuEarned, cuPrice)
		}
	}

	// Print per-method statistics for ALL backends
	if len(sc.backendMethodStats) > 0 {
		fmt.Printf("\nPer-Method Backend Comparison (Top 3 Methods):\n")

		// Collect all unique methods across all backends with their total counts
		methodCounts := make(map[string]int)
		for _, methods := range sc.backendMethodStats {
			for method, durations := range methods {
				methodCounts[method] += len(durations)
			}
		}

		// Sort methods by total count (descending)
		type methodCount struct {
			method string
			count  int
		}
		var methodList []methodCount
		for method, count := range methodCounts {
			methodList = append(methodList, methodCount{method, count})
		}
		sort.Slice(methodList, func(i, j int) bool {
			return methodList[i].count > methodList[j].count
		})

		// Only show top 3 methods
		maxMethods := 3
		if len(methodList) < maxMethods {
			maxMethods = len(methodList)
		}

		// For each of the top methods, show stats from all backends
		for i := 0; i < maxMethods; i++ {
			method := methodList[i].method

			fmt.Printf("\n  Method: %s (Total requests: %d)\n", method, methodList[i].count)

			// Check if this is a stateful method
			if isStatefulMethod(method) {
				fmt.Printf("  Note: Stateful method - only sent to primary backend\n")
			}

			// Show wins for this method if available
			if methodWins, exists := sc.methodBackendWins[method]; exists {
				fmt.Printf("  First Response Wins: ")
				totalMethodWins := 0
				for _, wins := range methodWins {
					totalMethodWins += wins
				}

				// Sort backends by wins for this method
				var methodWinList []backendWin
				for backend, wins := range methodWins {
					methodWinList = append(methodWinList, backendWin{backend, wins})
				}
				sort.Slice(methodWinList, func(i, j int) bool {
					return methodWinList[i].wins > methodWinList[j].wins
				})

				// Print wins inline
				for idx, bw := range methodWinList {
					if idx > 0 {
						fmt.Printf(", ")
					}
					winPercentage := float64(bw.wins) / float64(totalMethodWins) * 100
					fmt.Printf("%s: %d (%.1f%%)", bw.backend, bw.wins, winPercentage)
				}
				fmt.Printf("\n")
			}

			fmt.Printf("  %-20s %10s %10s %10s %10s %10s %10s %10s\n",
				"Backend", "Count", "Min", "Avg", "Max", "p50", "p90", "p99")
			fmt.Printf("  %s\n", strings.Repeat("-", 98))

			for _, backend := range backendNames {
				durations, exists := sc.backendMethodStats[backend][method]
				if !exists || len(durations) == 0 {
					continue
				}

				sort.Slice(durations, func(i, j int) bool {
					return durations[i] < durations[j]
				})

				var sum time.Duration
				for _, d := range durations {
					sum += d
				}

				avg := sum / time.Duration(len(durations))
				min := durations[0]
				max := durations[len(durations)-1]

				p50 := min
				p90 := min
				p99 := min

				if len(durations) >= 2 {
					p50idx := len(durations) * 50 / 100
					p90idx := len(durations) * 90 / 100
					p99idx := minInt(len(durations)-1, len(durations)*99/100)

					p50 = durations[p50idx]
					p90 = durations[p90idx]
					p99 = durations[p99idx]
				}

				fmt.Printf("  %-20s %10d %10s %10s %10s %10s %10s %10s\n",
					backend, len(durations),
					formatDuration(min), formatDuration(avg), formatDuration(max),
					formatDuration(p50), formatDuration(p90), formatDuration(p99))
			}

			// Show User Latency for this method if available
			if methodActualDurations, exists := sc.methodActualFirstResponseDurations[method]; exists && len(methodActualDurations) > 0 {
				// Make a copy and sort
				durations := make([]time.Duration, len(methodActualDurations))
				copy(durations, methodActualDurations)

				sort.Slice(durations, func(i, j int) bool {
					return durations[i] < durations[j]
				})

				var sum time.Duration
				for _, d := range durations {
					sum += d
				}

				avg := sum / time.Duration(len(durations))
				min := durations[0]
				max := durations[len(durations)-1]

				p50 := min
				p90 := min
				p99 := min

				if len(durations) >= 2 {
					p50idx := len(durations) * 50 / 100
					p90idx := len(durations) * 90 / 100
					p99idx := minInt(len(durations)-1, len(durations)*99/100)

					p50 = durations[p50idx]
					p90 = durations[p90idx]
					p99 = durations[p99idx]
				}

				fmt.Printf("  %-20s %10d %10s %10s %10s %10s %10s %10s\n",
					"User Latency", len(durations),
					formatDuration(min), formatDuration(avg), formatDuration(max),
					formatDuration(p50), formatDuration(p90), formatDuration(p99))
			}

			// Show Backend Time statistics for this method
			if methodFirstDurations, exists := sc.methodFirstResponseDurations[method]; exists && len(methodFirstDurations) > 0 {
				// Make a copy and sort
				durations := make([]time.Duration, len(methodFirstDurations))
				copy(durations, methodFirstDurations)

				sort.Slice(durations, func(i, j int) bool {
					return durations[i] < durations[j]
				})

				var sum time.Duration
				for _, d := range durations {
					sum += d
				}

				avg := sum / time.Duration(len(durations))
				min := durations[0]
				max := durations[len(durations)-1]

				p50 := min
				p90 := min
				p99 := min

				if len(durations) >= 2 {
					p50idx := len(durations) * 50 / 100
					p90idx := len(durations) * 90 / 100
					p99idx := minInt(len(durations)-1, len(durations)*99/100)

					p50 = durations[p50idx]
					p90 = durations[p90idx]
					p99 = durations[p99idx]
				}

				fmt.Printf("  %-20s %10d %10s %10s %10s %10s %10s %10s\n",
					"Backend Time", len(durations),
					formatDuration(min), formatDuration(avg), formatDuration(max),
					formatDuration(p50), formatDuration(p90), formatDuration(p99))
				fmt.Printf("  %s\n", strings.Repeat("-", 98))
			}
		}
	}

	fmt.Printf("================================\n\n")

	// Store current interval's CU data in historical data before resetting
	if sc.totalCU > 0 {
		sc.historicalCU = append(sc.historicalCU, CUDataPoint{
			Timestamp: time.Now(), // Store the end time of the interval
			CU:        sc.totalCU,
		})
	}

	// Clean up old historical data (keep only last 24 hours + some buffer)
	cutoff := time.Now().Add(-25 * time.Hour)
	newStart := 0
	for i, point := range sc.historicalCU {
		if point.Timestamp.After(cutoff) {
			newStart = i
			break
		}
	}
	if newStart > 0 {
		sc.historicalCU = sc.historicalCU[newStart:]
	}

	// Reset statistics for the next interval
	// Keep only the last 1000 requests to prevent unlimited memory growth
	if len(sc.requestStats) > 1000 {
		sc.requestStats = sc.requestStats[len(sc.requestStats)-1000:]
	}

	// Reset method-specific statistics
	for method := range sc.methodStats {
		sc.methodStats[method] = sc.methodStats[method][:0]
	}

	// Reset backend method-specific statistics
	for backend := range sc.backendMethodStats {
		for method := range sc.backendMethodStats[backend] {
			sc.backendMethodStats[backend][method] = sc.backendMethodStats[backend][method][:0]
		}
	}

	// Reset backend wins statistics
	sc.backendWins = make(map[string]int)
	sc.methodBackendWins = make(map[string]map[string]int)

	// Reset first response statistics
	if len(sc.firstResponseDurations) > 1000 {
		sc.firstResponseDurations = sc.firstResponseDurations[len(sc.firstResponseDurations)-1000:]
	} else {
		sc.firstResponseDurations = sc.firstResponseDurations[:0]
	}
	if len(sc.actualFirstResponseDurations) > 1000 {
		sc.actualFirstResponseDurations = sc.actualFirstResponseDurations[len(sc.actualFirstResponseDurations)-1000:]
	} else {
		sc.actualFirstResponseDurations = sc.actualFirstResponseDurations[:0]
	}
	for method := range sc.methodFirstResponseDurations {
		sc.methodFirstResponseDurations[method] = sc.methodFirstResponseDurations[method][:0]
	}
	for method := range sc.methodActualFirstResponseDurations {
		sc.methodActualFirstResponseDurations[method] = sc.methodActualFirstResponseDurations[method][:0]
	}

	// Reset CU counters for the next interval
	sc.totalCU = 0
	sc.methodCU = make(map[string]int)

	// Reset error count for the next interval
	sc.errorCount = 0
	sc.skippedSecondaryRequests = 0
	sc.totalRequests = 0
	sc.totalWsConnections = 0

	// Reset WebSocket connections to prevent memory leak
	sc.wsConnections = sc.wsConnections[:0]

	// Reset the interval start time for the next interval
	sc.intervalStartTime = time.Now()
}

// Helper function to avoid potential index out of bounds
func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// calculateCUForTimeWindow calculates total CU for a given time window
func (sc *StatsCollector) calculateCUForTimeWindow(window time.Duration) (int, bool) {
	now := time.Now()
	cutoff := now.Add(-window)

	totalCU := 0
	var oldestDataStartTime time.Time
	hasData := false

	// Add current interval's CU if it started within the window
	if sc.intervalStartTime.After(cutoff) {
		totalCU += sc.totalCU
		oldestDataStartTime = sc.intervalStartTime
		hasData = true
	}

	// Add historical CU data within the window
	// Historical timestamps represent the END of intervals
	for i := len(sc.historicalCU) - 1; i >= 0; i-- {
		point := sc.historicalCU[i]
		// Calculate the start time of this historical interval
		intervalStart := point.Timestamp.Add(-sc.summaryInterval)

		// Skip if the interval ended before our cutoff
		if point.Timestamp.Before(cutoff) {
			break
		}

		// Include this interval's CU
		totalCU += point.CU

		// Track the oldest data start time
		if !hasData || intervalStart.Before(oldestDataStartTime) {
			oldestDataStartTime = intervalStart
		}
		hasData = true
	}

	// Calculate actual data span
	var actualDataDuration time.Duration
	if hasData {
		actualDataDuration = now.Sub(oldestDataStartTime)
	}

	// We need extrapolation if we don't have enough historical data to cover the window
	needsExtrapolation := hasData && actualDataDuration < window

	return totalCU, needsExtrapolation
}

// extrapolateCU extrapolates CU data when there's insufficient historical data
func (sc *StatsCollector) extrapolateCU(actualCU int, actualDuration, targetDuration time.Duration) int {
	if actualDuration <= 0 {
		return 0
	}

	// Calculate CU per second rate
	cuPerSecond := float64(actualCU) / actualDuration.Seconds()

	// Extrapolate to target duration
	extrapolatedCU := cuPerSecond * targetDuration.Seconds()

	return int(extrapolatedCU)
}

// formatCUWithExtrapolation formats CU value with extrapolation indicator
func formatCUWithExtrapolation(cu int, isExtrapolated bool) string {
	if isExtrapolated {
		return fmt.Sprintf("%d CU (extrapolated)", cu)
	}
	return fmt.Sprintf("%d CU", cu)
}

// GetPrimaryP50 calculates the current p50 latency for the primary backend
func (sc *StatsCollector) GetPrimaryP50() time.Duration {
	sc.mu.Lock()
	defer sc.mu.Unlock()

	// Collect primary backend durations
	var primaryDurations []time.Duration
	for _, stat := range sc.requestStats {
		if stat.Backend == "primary" && stat.Error == nil {
			primaryDurations = append(primaryDurations, stat.Duration)
		}
	}

	// If we don't have enough data, return a sensible default
	if len(primaryDurations) < 10 {
		return 10 * time.Millisecond // Default to 10ms
	}

	// Sort and find p50
	sort.Slice(primaryDurations, func(i, j int) bool {
		return primaryDurations[i] < primaryDurations[j]
	})

	p50idx := len(primaryDurations) * 50 / 100
	return primaryDurations[p50idx]
}

// GetPrimaryP75ForMethod calculates the current p75 latency for a specific method on the primary backend
func (sc *StatsCollector) GetPrimaryP75ForMethod(method string) time.Duration {
	sc.mu.Lock()
	defer sc.mu.Unlock()

	// Get method-specific durations for primary backend
	if durations, exists := sc.methodStats[method]; exists && len(durations) >= 5 {
		// Make a copy to avoid modifying the original
		durationsCopy := make([]time.Duration, len(durations))
		copy(durationsCopy, durations)

		// Sort and find p75
		sort.Slice(durationsCopy, func(i, j int) bool {
			return durationsCopy[i] < durationsCopy[j]
		})

		p75idx := len(durationsCopy) * 75 / 100
		if p75idx >= len(durationsCopy) {
			p75idx = len(durationsCopy) - 1
		}
		return durationsCopy[p75idx]
	}

	// If we don't have enough method-specific data, calculate global p75 here
	// (instead of calling GetPrimaryP50 which would cause nested mutex lock)
	var primaryDurations []time.Duration
	for _, stat := range sc.requestStats {
		if stat.Backend == "primary" && stat.Error == nil {
			primaryDurations = append(primaryDurations, stat.Duration)
		}
	}

	// If we don't have enough data, return a sensible default
	if len(primaryDurations) < 10 {
		return 15 * time.Millisecond // Default to 15ms for p75
	}

	// Sort and find p75
	sort.Slice(primaryDurations, func(i, j int) bool {
		return primaryDurations[i] < primaryDurations[j]
	})

	p75idx := len(primaryDurations) * 75 / 100
	if p75idx >= len(primaryDurations) {
		p75idx = len(primaryDurations) - 1
	}
	return primaryDurations[p75idx]
}

// GetPrimaryP50ForMethod calculates the current p50 latency for a specific method on the primary backend
func (sc *StatsCollector) GetPrimaryP50ForMethod(method string) time.Duration {
	sc.mu.Lock()
	defer sc.mu.Unlock()

	// Get method-specific durations for primary backend
	if durations, exists := sc.methodStats[method]; exists && len(durations) >= 5 {
		// Make a copy to avoid modifying the original
		durationsCopy := make([]time.Duration, len(durations))
		copy(durationsCopy, durations)

		// Sort and find p50
		sort.Slice(durationsCopy, func(i, j int) bool {
			return durationsCopy[i] < durationsCopy[j]
		})

		p50idx := len(durationsCopy) * 50 / 100
		return durationsCopy[p50idx]
	}

	// If we don't have enough method-specific data, calculate global p50 here
	// (instead of calling GetPrimaryP50 which would cause nested mutex lock)
	var primaryDurations []time.Duration
	for _, stat := range sc.requestStats {
		if stat.Backend == "primary" && stat.Error == nil {
			primaryDurations = append(primaryDurations, stat.Duration)
		}
	}

	// If we don't have enough data, return a sensible default
	if len(primaryDurations) < 10 {
		return 10 * time.Millisecond // Default to 10ms
	}

	// Sort and find p50
	sort.Slice(primaryDurations, func(i, j int) bool {
		return primaryDurations[i] < primaryDurations[j]
	})

	p50idx := len(primaryDurations) * 50 / 100
	return primaryDurations[p50idx]
}

// isStatefulMethod returns true if the method requires session state and must always go to primary
func isStatefulMethod(method string) bool {
	statefulMethods := map[string]bool{
		// Filter methods - these create server-side state
		"eth_newFilter":                   true,
		"eth_newBlockFilter":              true,
		"eth_newPendingTransactionFilter": true,
		"eth_getFilterChanges":            true,
		"eth_getFilterLogs":               true,
		"eth_uninstallFilter":             true,

		// Subscription methods (WebSocket) - maintain persistent connections
		"eth_subscribe":    true,
		"eth_unsubscribe":  true,
		"eth_subscription": true, // Notification method

		// Some debug/trace methods might maintain state depending on implementation
		// But these are typically stateless, so not included here
	}

	return statefulMethods[method]
}

// requiresPrimaryOnlyMethod returns true if the method should always go to primary
func requiresPrimaryOnlyMethod(method string) bool {
	primaryOnlyMethods := map[string]bool{
		// Transaction sending methods - must go to primary
		"eth_sendRawTransaction": true,
		"eth_sendTransaction":    true,

		// Mempool/txpool methods - these show pending transactions
		"txpool_content":     true,
		"txpool_inspect":     true,
		"txpool_status":      true,
		"txpool_contentFrom": true,

		// Mining related methods
		"eth_mining":         true,
		"eth_hashrate":       true,
		"eth_getWork":        true,
		"eth_submitWork":     true,
		"eth_submitHashrate": true,

		// Complex methods with special block handling
		"eth_callMany":   true, // Has complex block handling with multiple calls at different blocks
		"eth_simulateV1": true, // Simulation should use primary for consistency

		// Trace methods that depend on transaction data
		"trace_transaction":       true, // Traces already mined transaction by hash
		"trace_replayTransaction": true, // Replays transaction execution by hash
		"trace_rawTransaction":    true, // Simulates raw transaction data

		// Debug methods that should use primary
		"debug_traceTransaction": true, // Debug version of trace by tx hash
		"debug_storageRangeAt":   true, // Accesses internal storage state
	}

	return primaryOnlyMethods[method]
}

// methodMightReturnNull returns true if the method might legitimately return null
// and we should wait for primary's response instead of returning secondary's null
func methodMightReturnNull(method string) bool {
	nullableMethods := map[string]bool{
		"eth_getTransactionReceipt":               true,
		"eth_getTransactionByHash":                true,
		"eth_getTransactionByBlockHashAndIndex":   true,
		"eth_getTransactionByBlockNumberAndIndex": true,
		"eth_getBlockByHash":                      true,
		"eth_getBlockByNumber":                    true,
		"eth_getUncleByBlockHashAndIndex":         true,
		"eth_getUncleByBlockNumberAndIndex":       true,
	}

	return nullableMethods[method]
}

// isNullResponse checks if a JSON-RPC response has a null result
func isNullResponse(respBody []byte) bool {
	// Simple structure to check the result field
	var response struct {
		Result json.RawMessage `json:"result"`
	}

	if err := json.Unmarshal(respBody, &response); err != nil {
		return false
	}

	// Check if result is null
	return string(response.Result) == "null"
}

// flushingResponseWriter wraps http.ResponseWriter to flush after every write
type flushingResponseWriter struct {
	http.ResponseWriter
	flusher http.Flusher
}

func (f *flushingResponseWriter) Write(p []byte) (n int, err error) {
	n, err = f.ResponseWriter.Write(p)
	if err == nil && n > 0 {
		f.flusher.Flush()
	}
	return
}

func main() {
	// Get configuration from environment variables
	listenAddr := getEnv("LISTEN_ADDR", ":8080")
	primaryBackend := getEnv("PRIMARY_BACKEND", "http://localhost:8545")
	secondaryBackendsStr := getEnv("SECONDARY_BACKENDS", "")
	summaryIntervalStr := getEnv("SUMMARY_INTERVAL", "60")        // Default 60 seconds
	enableDetailedLogs := getEnv("ENABLE_DETAILED_LOGS", "false") // Default to disabled

	// Secondary probe configuration
	enableSecondaryProbing := getEnv("ENABLE_SECONDARY_PROBING", "true") == "true"
	probeIntervalStr := getEnv("PROBE_INTERVAL", "10")   // Default 10 seconds
	minDelayBufferStr := getEnv("MIN_DELAY_BUFFER", "2") // Default 2ms buffer
	probeMethodsStr := getEnv("PROBE_METHODS", "eth_blockNumber,net_version,eth_chainId")

	summaryInterval, err := strconv.Atoi(summaryIntervalStr)
	if err != nil {
		log.Printf("Invalid SUMMARY_INTERVAL, using default of 60 seconds")
		summaryInterval = 60
	}

	probeInterval, err := strconv.Atoi(probeIntervalStr)
	if err != nil {
		log.Printf("Invalid PROBE_INTERVAL, using default of 10 seconds")
		probeInterval = 10
	}

	minDelayBuffer, err := strconv.Atoi(minDelayBufferStr)
	if err != nil {
		log.Printf("Invalid MIN_DELAY_BUFFER, using default of 2ms")
		minDelayBuffer = 2
	}

	// Create stats collector for periodic summaries
	statsCollector := NewStatsCollector(time.Duration(summaryInterval)*time.Second, secondaryBackendsStr != "")

	// Configure backends
	var backends []Backend
	backends = append(backends, Backend{
		URL:  primaryBackend,
		Name: "primary",
		Role: "primary",
	})

	if secondaryBackendsStr != "" {
		secondaryList := strings.Split(secondaryBackendsStr, ",")
		for i, url := range secondaryList {
			backends = append(backends, Backend{
				URL:  strings.TrimSpace(url),
				Name: fmt.Sprintf("secondary-%d", i+1),
				Role: "secondary",
			})
		}
	}

	log.Printf("Starting benchmark proxy on %s", listenAddr)
	log.Printf("Primary backend: %s", primaryBackend)
	log.Printf("Secondary backends: %s", secondaryBackendsStr)
	if enableSecondaryProbing && secondaryBackendsStr != "" {
		log.Printf("Secondary probing: enabled (interval: %ds, buffer: %dms)", probeInterval, minDelayBuffer)
	}

	// Set up HTTP client with reasonable timeouts
	client := &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			MaxIdleConns:        200,               // Increased for better connection pooling
			MaxIdleConnsPerHost: 50,                // Increased per-host limit for probing
			IdleConnTimeout:     120 * time.Second, // Longer idle timeout for connection reuse
			DisableCompression:  true,              // Typically JSON-RPC doesn't benefit from compression
			DisableKeepAlives:   false,             // Ensure keep-alives are enabled
			MaxConnsPerHost:     50,                // Limit concurrent connections per host
		},
	}

	// Initialize secondary probe if enabled and we have secondary backends
	var secondaryProbe *SecondaryProbe
	if enableSecondaryProbing && secondaryBackendsStr != "" {
		probeMethods := strings.Split(probeMethodsStr, ",")
		for i := range probeMethods {
			probeMethods[i] = strings.TrimSpace(probeMethods[i])
		}

		secondaryProbe = NewSecondaryProbe(
			backends,
			client,
			time.Duration(probeInterval)*time.Second,
			time.Duration(minDelayBuffer)*time.Millisecond,
			probeMethods,
			enableDetailedLogs == "true",
		)

		if secondaryProbe == nil {
			log.Printf("Secondary probe initialization failed - no secondary backends found")
		} else {
			// Set the probe in stats collector for display
			statsCollector.SetSecondaryProbe(secondaryProbe)
		}
	}

	// Initialize chain head monitor
	var chainHeadMonitor *ChainHeadMonitor
	if len(backends) > 1 { // Only create if we have more than just primary
		chainHeadMonitor = NewChainHeadMonitor(backends, enableDetailedLogs == "true")
		log.Printf("Chain head monitoring: enabled")

		// Set the monitor in stats collector for display
		statsCollector.SetChainHeadMonitor(chainHeadMonitor)
	}

	// Configure websocket upgrader with larger buffer sizes
	// 20MB frame size and 50MB message size
	const (
		maxFrameSize   = 20 * 1024 * 1024 // 20MB
		maxMessageSize = 50 * 1024 * 1024 // 50MB
	)

	upgrader := websocket.Upgrader{
		ReadBufferSize:  maxFrameSize,
		WriteBufferSize: maxFrameSize,
		// Allow all origins
		CheckOrigin: func(r *http.Request) bool { return true },
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Check if this is a WebSocket upgrade request
		if websocket.IsWebSocketUpgrade(r) {
			handleWebSocketRequest(w, r, backends, client, &upgrader, statsCollector)
		} else {
			// Handle regular HTTP request
			handleRequest(w, r, backends, client, enableDetailedLogs == "true", statsCollector, secondaryProbe, chainHeadMonitor)
		}
	})

	log.Fatal(http.ListenAndServe(listenAddr, nil))
}

func handleRequest(w http.ResponseWriter, r *http.Request, backends []Backend, client *http.Client, enableDetailedLogs bool, statsCollector *StatsCollector, secondaryProbe *SecondaryProbe, chainHeadMonitor *ChainHeadMonitor) {
	startTime := time.Now()

	// Create a context that will cancel after 35 seconds (5s buffer over backend timeout)
	ctx, cancel := context.WithTimeout(r.Context(), 35*time.Second)
	defer cancel()

	// Limit request body size to 10MB to prevent memory exhaustion
	const maxBodySize = 10 * 1024 * 1024 // 10MB
	r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)

	// Read the entire request body
	body, err := io.ReadAll(r.Body)
	if err != nil {
		// Check if the error is due to body size limit
		if strings.Contains(err.Error(), "request body too large") {
			http.Error(w, "Request body too large (max 10MB)", http.StatusRequestEntityTooLarge)
		} else {
			http.Error(w, "Error reading request body", http.StatusBadRequest)
		}
		return
	}
	defer r.Body.Close()

	// Parse request to extract method information (handles both single and batch)
	batchInfo, err := parseBatchInfo(body)
	if err != nil {
		http.Error(w, "Invalid JSON-RPC request", http.StatusBadRequest)
		return
	}

	// For logging and stats, use the first method or "batch" for batch requests
	var displayMethod string
	var isStateful bool
	var requiresPrimaryDueToBlockTag bool

	if batchInfo.IsBatch {
		displayMethod = fmt.Sprintf("batch[%d]", batchInfo.RequestCount)
		isStateful = batchInfo.HasStateful
		requiresPrimaryDueToBlockTag = batchInfo.RequiresPrimary
	} else {
		displayMethod = batchInfo.Methods[0]
		if displayMethod == "" {
			displayMethod = "unknown"
		}
		isStateful = batchInfo.HasStateful
		requiresPrimaryDueToBlockTag = batchInfo.RequiresPrimary
	}

	if enableDetailedLogs {
		if batchInfo.IsBatch {
			log.Printf("Batch request: %d requests, methods: %s, block tags: %v",
				batchInfo.RequestCount, formatMethodList(batchInfo.Methods), batchInfo.BlockTags)
		} else {
			var blockTagInfo string
			if len(batchInfo.BlockTags) > 0 {
				blockTagInfo = fmt.Sprintf(", block tag: %s", batchInfo.BlockTags[0])
			}
			log.Printf("Method: %s%s", displayMethod, blockTagInfo)
		}
	}
	// Process backends with adaptive delay strategy
	var wg sync.WaitGroup
	var primaryWg sync.WaitGroup // Separate wait group for primary backend
	statsChan := make(chan ResponseStats, len(backends))
	responseChan := make(chan struct {
		backend string
		resp    *http.Response
		err     error
	}, len(backends))

	// Track if we've already sent a response
	var responseHandled atomic.Bool
	var firstBackendStartTime atomic.Pointer[time.Time]
	primaryResponseChan := make(chan struct{}, 1) // Signal when primary gets a response
	primaryFailedFast := make(chan struct{}, 1)   // Signal when primary fails immediately

	for _, backend := range backends {
		// Skip secondary backends for stateful methods
		if isStateful && backend.Role != "primary" {
			if enableDetailedLogs {
				log.Printf("Skipping secondary backend %s for stateful method %s", backend.Name, displayMethod)
			}
			continue
		}

		// Skip secondary backends if request requires primary due to block tag
		if requiresPrimaryDueToBlockTag && backend.Role != "primary" {
			if enableDetailedLogs {
				log.Printf("Skipping secondary backend %s due to block tag requiring primary", backend.Name)
			}
			continue
		}

		// Check if secondary backend can handle "latest" block tag requests
		if backend.Role == "secondary" && len(batchInfo.BlockTags) > 0 {
			// Check all block tags in the request
			canUseSecondary := true
			for _, blockTag := range batchInfo.BlockTags {
				if !canUseSecondaryForBlockTag(blockTag, backend.Name, chainHeadMonitor) {
					canUseSecondary = false
					if enableDetailedLogs {
						log.Printf("Skipping secondary backend %s for block tag '%s' - not at required height",
							backend.Name, blockTag)
					}
					break
				}
			}
			if !canUseSecondary {
				continue
			}
		}

		// Skip unhealthy secondary backends
		if backend.Role == "secondary" && chainHeadMonitor != nil && !chainHeadMonitor.IsBackendHealthy(backend.Name) {
			if enableDetailedLogs {
				log.Printf("Skipping unhealthy secondary backend %s for %s", backend.Name, displayMethod)
			}
			continue
		}

		wg.Add(1)
		if backend.Role == "primary" {
			primaryWg.Add(1)
		}

		go func(b Backend) {
			defer wg.Done()
			if b.Role == "primary" {
				defer primaryWg.Done()
			}

			// Track when this goroutine actually starts processing
			goroutineStartTime := time.Now()

			// Record the first backend start time (should be primary)
			if b.Role == "primary" {
				t := goroutineStartTime
				firstBackendStartTime.Store(&t)
			}

			// If this is a secondary backend, wait for p75 delay
			if b.Role != "primary" {
				// Get backend-specific delay
				var backendSpecificDelay time.Duration
				if batchInfo.IsBatch {
					// For batch requests, use the maximum delay of all methods for this backend
					backendSpecificDelay = calculateBatchDelay(batchInfo.Methods, b.Name, secondaryProbe, statsCollector)
				} else if secondaryProbe != nil {
					backendSpecificDelay = secondaryProbe.getDelayForBackendAndMethod(b.Name, displayMethod)
				} else {
					// Fallback to method-based delay if no probe
					backendSpecificDelay = statsCollector.GetPrimaryP75ForMethod(displayMethod)
				}

				if enableDetailedLogs {
					log.Printf("Secondary backend %s waiting %s for method %s", b.Name, backendSpecificDelay, displayMethod)
				}

				delayTimer := time.NewTimer(backendSpecificDelay)
				select {
				case <-delayTimer.C:
					// Timer expired, primary is slow, proceed with secondary request
				case <-primaryResponseChan:
					// Primary already got a response, skip secondary
					delayTimer.Stop()

					// Still record that we skipped this backend
					statsChan <- ResponseStats{
						Backend:  b.Name,
						Error:    fmt.Errorf("skipped - primary responded quickly"),
						Method:   displayMethod,
						Duration: time.Since(goroutineStartTime),
					}
					return
				case <-primaryFailedFast:
					// Primary failed immediately, start secondary now
					delayTimer.Stop()
					if enableDetailedLogs {
						log.Printf("Primary failed fast for %s, starting secondary immediately", displayMethod)
					}
				}
			}

			// Create a new request (no longer using context for cancellation)
			backendReq, err := http.NewRequest(r.Method, b.URL, bytes.NewReader(body))
			if err != nil {
				statsChan <- ResponseStats{
					Backend:  b.Name,
					Error:    err,
					Method:   displayMethod,
					Duration: time.Since(goroutineStartTime), // Include any wait time
				}
				return
			}

			// Copy headers
			for name, values := range r.Header {
				for _, value := range values {
					backendReq.Header.Add(name, value)
				}
			}

			// Send the request
			reqStart := time.Now()
			resp, err := client.Do(backendReq)
			reqDuration := time.Since(reqStart)

			if err != nil {
				// If primary failed with connection error, signal secondary to start
				if b.Role == "primary" {
					select {
					case primaryFailedFast <- struct{}{}:
					default:
					}
				}

				statsChan <- ResponseStats{
					Backend:  b.Name,
					Duration: reqDuration, // Keep backend-specific duration
					Error:    err,
					Method:   displayMethod,
				}
				return
			}

			// Don't close resp.Body here - it will be closed by the winner or drained by losers

			// Check if primary returned an error status
			if b.Role == "primary" && resp.StatusCode >= 400 {
				// Any 4xx or 5xx error should trigger immediate secondary
				select {
				case primaryFailedFast <- struct{}{}:
				default:
				}
			}

			// Signal primary response immediately for secondary backends to check
			if b.Role == "primary" && resp.StatusCode < 400 {
				select {
				case primaryResponseChan <- struct{}{}:
				default:
					// Channel already has a signal
				}
			}

			statsChan <- ResponseStats{
				Backend:    b.Name,
				StatusCode: resp.StatusCode,
				Duration:   reqDuration, // This is the backend-specific duration
				Method:     displayMethod,
			}

			// CRITICAL FIX: Only allow secondary backends to win if they have successful responses
			if b.Role == "secondary" && resp.StatusCode >= 400 {
				// Secondary returned an error - DO NOT let it win the race
				if enableDetailedLogs {
					log.Printf("Secondary backend %s returned error status %d for %s - ignoring",
						b.Name, resp.StatusCode, displayMethod)
				}

				// Still need to drain and close the body
				go func() {
					defer resp.Body.Close()
					io.Copy(io.Discard, resp.Body)
				}()
				return
			}

			// CRITICAL FIX 2: Check for null responses from secondary backends for certain methods
			if b.Role == "secondary" && resp.StatusCode == 200 && methodMightReturnNull(displayMethod) {
				// Need to read the body to check if it's null
				bodyBytes, err := io.ReadAll(resp.Body)
				resp.Body.Close() // Close the original body

				if err == nil && isNullResponse(bodyBytes) {
					// Secondary returned null - don't let it win the race
					if enableDetailedLogs {
						log.Printf("Secondary backend %s returned null for %s - waiting for primary",
							b.Name, displayMethod)
					}
					return
				}

				// Not null or couldn't read - recreate the body for potential use
				if err == nil {
					resp.Body = io.NopCloser(bytes.NewReader(bodyBytes))
				}
			}

			// Try to be the first to respond
			if responseHandled.CompareAndSwap(false, true) {
				responseChan <- struct {
					backend string
					resp    *http.Response
					err     error
				}{b.Name, resp, nil}
			} else {
				// Not the winning response, need to drain and close the body
				// Use a goroutine with timeout to prevent hanging
				go func() {
					defer resp.Body.Close()
					// Create a deadline for draining
					done := make(chan struct{})
					go func() {
						io.Copy(io.Discard, resp.Body)
						close(done)
					}()

					select {
					case <-done:
						// Drained successfully
					case <-time.After(5 * time.Second):
						// Timeout draining, just close
						if enableDetailedLogs {
							log.Printf("Timeout draining response from backend %s", b.Name)
						}
					}
				}()
			}
		}(backend)
	}

	// Wait for the first successful response
	var response struct {
		backend string
		resp    *http.Response
		err     error
	}
	var responseReceivedTime time.Time

	select {
	case response = <-responseChan:
		// Got a response
		responseReceivedTime = time.Now()
	case <-time.After(30 * time.Second):
		// Timeout
		if !responseHandled.CompareAndSwap(false, true) {
			// Someone else handled it
			response = <-responseChan
			responseReceivedTime = time.Now()
		} else {
			http.Error(w, "Timeout waiting for any backend", http.StatusGatewayTimeout)
			// Always wait for primary backend to complete before collecting stats
			go func() {
				primaryWg.Wait() // Wait for primary first
				wg.Wait()        // Then wait for all
				close(statsChan)
			}()
			// Collect stats
			var stats []ResponseStats
			for stat := range statsChan {
				stats = append(stats, stat)
			}
			return
		}
	}

	// Send the response to the client
	if response.err == nil && response.resp != nil {
		defer response.resp.Body.Close()

		// Copy response headers
		for name, values := range response.resp.Header {
			for _, value := range values {
				w.Header().Add(name, value)
			}
		}

		// Ensure we flush data as it arrives for better streaming
		flusher, canFlush := w.(http.Flusher)

		w.WriteHeader(response.resp.StatusCode)

		// Track when streaming started
		streamingStartTime := time.Now()

		// Stream the response body to the client with proper error handling
		done := make(chan error, 1)
		go func() {
			// Use a custom writer that flushes periodically
			var err error
			if canFlush {
				// Flush every 32KB for better streaming performance
				flushingWriter := &flushingResponseWriter{
					ResponseWriter: w,
					flusher:        flusher,
				}
				_, err = io.Copy(flushingWriter, response.resp.Body)
			} else {
				_, err = io.Copy(w, response.resp.Body)
			}
			done <- err
		}()

		select {
		case streamErr := <-done:
			if streamErr != nil {
				if enableDetailedLogs {
					log.Printf("Error streaming response body: %v", streamErr)
				}
				// Connection is likely broken, can't send error to client
			}
		case <-ctx.Done():
			// Context timeout - client connection might be gone
			if enableDetailedLogs {
				streamingDuration := time.Since(streamingStartTime)
				totalRequestDuration := time.Since(startTime)

				// Determine if it was a timeout or cancellation
				reason := "timeout"
				if ctx.Err() == context.Canceled {
					reason = "client disconnection"
				}

				log.Printf("Context cancelled while streaming response from backend '%s' (method: %s) after streaming for %s (total request time: %s) - reason: %s",
					response.backend, displayMethod, streamingDuration, totalRequestDuration, reason)
			}
		}
	} else {
		// No valid response received from any backend
		http.Error(w, "All backends failed", http.StatusBadGateway)
	}

	// Collect stats asynchronously to avoid blocking the response
	go func() {
		// Always wait for primary backend to complete before collecting stats
		// This ensures primary backend stats are always included
		primaryWg.Wait() // Wait for primary backend to complete first
		wg.Wait()        // Then wait for all other backends
		close(statsChan)

		// Collect stats
		var stats []ResponseStats
		for stat := range statsChan {
			stats = append(stats, stat)
		}

		// Log response times if enabled
		totalDuration := time.Since(startTime)
		if enableDetailedLogs {
			logResponseStats(totalDuration, stats)
		}

		// Add the actual user-experienced duration for the winning response
		if response.err == nil && response.backend != "" {
			// Find the stat for the winning backend and update it with the actual user-experienced duration
			for i := range stats {
				if stats[i].Backend == response.backend && stats[i].Error == nil {
					// Calculate user latency from when the first backend started processing
					var userLatency time.Duration
					if firstStart := firstBackendStartTime.Load(); firstStart != nil && !responseReceivedTime.IsZero() {
						userLatency = responseReceivedTime.Sub(*firstStart)
					} else {
						// Fallback to original calculation if somehow we don't have the times
						userLatency = time.Since(startTime)
					}

					// Create a special stat entry for the actual first response time
					actualFirstResponseStat := ResponseStats{
						Backend:    "actual-first-response",
						StatusCode: stats[i].StatusCode,
						Duration:   userLatency,
						Error:      nil,
						Method:     stats[i].Method,
					}
					stats = append(stats, actualFirstResponseStat)
					break
				}
			}
		}

		// Send stats to collector
		statsCollector.AddStats(stats, 0)

		// If this was a successful batch request from primary, add batch stats for CU calculation
		if batchInfo.IsBatch && response.err == nil && response.backend == "primary" {
			// Find the primary backend stat with successful response
			for _, stat := range stats {
				if stat.Backend == "primary" && stat.Error == nil {
					statsCollector.AddBatchStats(batchInfo.Methods, stat.Duration, "primary")
					break
				}
			}
		}
	}()

	// Return immediately after sending response to client
	return
}

func logResponseStats(totalDuration time.Duration, stats []ResponseStats) {
	// Format: timestamp | total_time | method | backend1:time1 | backend2:time2 | ...
	var parts []string
	parts = append(parts, time.Now().Format("2006-01-02 15:04:05.000"))
	parts = append(parts, fmt.Sprintf("total:%s", totalDuration))

	// Add method if available (use the first stat with a method)
	method := "unknown"
	for _, stat := range stats {
		if stat.Method != "" {
			method = stat.Method
			break
		}
	}
	parts = append(parts, fmt.Sprintf("method:%s", method))

	for _, stat := range stats {
		if stat.Error != nil {
			parts = append(parts, fmt.Sprintf("%s:error:%s", stat.Backend, stat.Error))
		} else {
			parts = append(parts, fmt.Sprintf("%s:%d:%s", stat.Backend, stat.StatusCode, stat.Duration))
		}
	}

	fmt.Println(strings.Join(parts, " | "))
}

// handleWebSocketRequest manages WebSocket proxying
func handleWebSocketRequest(w http.ResponseWriter, r *http.Request, backends []Backend,
	httpClient *http.Client, upgrader *websocket.Upgrader,
	statsCollector *StatsCollector) {
	// Upgrade the client connection
	clientConn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("Failed to upgrade client connection: %v", err)
		return
	}
	defer clientConn.Close()

	// Set max message size for client connection
	clientConn.SetReadLimit(50 * 1024 * 1024) // 50MB message size limit

	// Connect to all backends
	var wg sync.WaitGroup
	primaryConnected := make(chan bool, 1) // Track if primary connected successfully

	for _, backend := range backends {
		wg.Add(1)
		go func(b Backend) {
			defer wg.Done()

			// Create backend URL with ws/wss instead of http/https
			backendURL := strings.Replace(b.URL, "http://", "ws://", 1)
			backendURL = strings.Replace(backendURL, "https://", "wss://", 1)

			// Create a clean header map for the dialer
			header := http.Header{}

			// Only copy non-WebSocket headers
			if origin := r.Header.Get("Origin"); origin != "" {
				header.Set("Origin", origin)
			}
			if userAgent := r.Header.Get("User-Agent"); userAgent != "" {
				header.Set("User-Agent", userAgent)
			}

			startTime := time.Now()
			// Connect to backend WebSocket with larger buffer sizes
			dialer := &websocket.Dialer{
				ReadBufferSize:  20 * 1024 * 1024, // 20MB
				WriteBufferSize: 20 * 1024 * 1024, // 20MB
			}
			backendConn, resp, err := dialer.Dial(backendURL, header)
			connectDuration := time.Since(startTime)

			stats := WebSocketStats{
				Backend:     b.Name,
				ConnectTime: connectDuration,
				IsActive:    false,
			}

			if err != nil {
				status := 0
				if resp != nil {
					status = resp.StatusCode
				}
				log.Printf("Failed to connect to backend %s: %v (status: %d)", b.Name, err, status)
				stats.Error = err
				statsCollector.AddWebSocketStats(stats)

				// If primary failed to connect, signal that
				if b.Role == "primary" {
					select {
					case primaryConnected <- false:
					default:
					}
				}
				return
			}
			defer backendConn.Close()

			// Set max message size for backend connection
			backendConn.SetReadLimit(50 * 1024 * 1024) // 50MB message size limit

			stats.IsActive = true
			statsCollector.AddWebSocketStats(stats)

			// If this is the primary backend, signal successful connection
			if b.Role == "primary" {
				select {
				case primaryConnected <- true:
				default:
				}
			}

			// If this is the primary backend, set up bidirectional proxying
			if b.Role == "primary" {
				// Channel to signal when primary connection fails
				primaryFailed := make(chan struct{}, 2) // Buffered for 2 signals

				// Forward messages from client to primary backend
				go func() {
					for {
						messageType, message, err := clientConn.ReadMessage()
						if err != nil {
							log.Printf("Error reading from client: %v", err)
							select {
							case primaryFailed <- struct{}{}:
							default:
							}
							return
						}

						err = backendConn.WriteMessage(messageType, message)
						if err != nil {
							log.Printf("Error writing to primary backend: %v", err)
							select {
							case primaryFailed <- struct{}{}:
							default:
							}
							return
						}
					}
				}()

				// Forward messages from primary backend to client
				go func() {
					for {
						messageType, message, err := backendConn.ReadMessage()
						if err != nil {
							log.Printf("Error reading from primary backend: %v", err)
							select {
							case primaryFailed <- struct{}{}:
							default:
							}
							return
						}

						err = clientConn.WriteMessage(messageType, message)
						if err != nil {
							log.Printf("Error writing to client: %v", err)
							select {
							case primaryFailed <- struct{}{}:
							default:
							}
							return
						}
					}
				}()

				// Wait for primary connection failure
				<-primaryFailed

				// Primary backend failed, close client connection with proper close message
				log.Printf("Primary backend WebSocket failed, closing client connection")
				closeMsg := websocket.FormatCloseMessage(websocket.CloseGoingAway,
					"Primary backend unavailable")
				clientConn.WriteControl(websocket.CloseMessage, closeMsg,
					time.Now().Add(time.Second))

				// Return to trigger cleanup
				return
			} else {
				// For secondary backends, just read and discard messages
				for {
					_, _, err := backendConn.ReadMessage()
					if err != nil {
						log.Printf("Secondary backend %s connection closed: %v", b.Name, err)
						return
					}
				}
			}
		}(backend)
	}

	// Wait for all connections to terminate
	wg.Wait()

	// Check if primary connected successfully
	select {
	case connected := <-primaryConnected:
		if !connected {
			// Primary failed to connect, close client connection
			log.Printf("Primary backend WebSocket failed to connect, closing client connection")
			closeMsg := websocket.FormatCloseMessage(websocket.CloseServiceRestart,
				"Primary backend unavailable")
			clientConn.WriteControl(websocket.CloseMessage, closeMsg,
				time.Now().Add(time.Second))
		}
	default:
		// No primary backend in the configuration (shouldn't happen)
		log.Printf("Warning: No primary backend configured for WebSocket")
	}
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}

// NewChainHeadMonitor creates a new chain head monitor
func NewChainHeadMonitor(backends []Backend, enableDetailedLogs bool) *ChainHeadMonitor {
	monitor := &ChainHeadMonitor{
		backends:        backends,
		chainHeads:      make(map[string]*ChainHead),
		enabledBackends: make(map[string]bool),
		blockHashCache:  make(map[string]uint64),
		blockHashOrder:  make([]string, 0, 128),
		wsDialer: &websocket.Dialer{
			ReadBufferSize:  1024 * 1024, // 1MB
			WriteBufferSize: 1024 * 1024, // 1MB
		},
		stopChan:           make(chan struct{}),
		enableDetailedLogs: enableDetailedLogs,
	}

	// Start monitoring
	go monitor.startMonitoring()

	return monitor
}

// IsBackendHealthy checks if a backend is healthy and at the correct chain head
func (m *ChainHeadMonitor) IsBackendHealthy(backendName string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()

	// Primary is always considered healthy for request routing
	if backendName == "primary" {
		return true
	}

	enabled, exists := m.enabledBackends[backendName]
	if !exists {
		return false // Unknown backend
	}

	return enabled
}

// startMonitoring starts WebSocket monitoring for all backends
func (m *ChainHeadMonitor) startMonitoring() {
	// Initial delay to let backends start
	time.Sleep(2 * time.Second)

	for _, backend := range m.backends {
		go m.monitorBackend(backend)
	}

	// Periodic health check
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			m.checkBackendHealth()
		case <-m.stopChan:
			return
		}
	}
}

// monitorBackend monitors a single backend via WebSocket
func (m *ChainHeadMonitor) monitorBackend(backend Backend) {
	backoffDelay := time.Second

	for {
		select {
		case <-m.stopChan:
			return
		default:
		}

		// Create WebSocket URL
		wsURL := strings.Replace(backend.URL, "http://", "ws://", 1)
		wsURL = strings.Replace(wsURL, "https://", "wss://", 1)

		// Connect to WebSocket
		conn, _, err := m.wsDialer.Dial(wsURL, nil)
		if err != nil {
			m.updateBackendStatus(backend.Name, nil, fmt.Sprintf("WebSocket connection failed: %v", err))
			time.Sleep(backoffDelay)
			backoffDelay = min(backoffDelay*2, 30*time.Second)
			continue
		}

		if m.enableDetailedLogs {
			log.Printf("Connected to %s WebSocket for chain head monitoring", backend.Name)
		}

		// Reset backoff on successful connection
		backoffDelay = time.Second

		// Get chain ID first
		chainID, err := m.getChainID(conn, backend.Name)
		if err != nil {
			conn.Close()
			m.updateBackendStatus(backend.Name, nil, fmt.Sprintf("Failed to get chain ID: %v", err))
			time.Sleep(backoffDelay)
			continue
		}

		// Store chain ID (especially important for primary)
		if backend.Role == "primary" {
			m.mu.Lock()
			m.primaryChainID = chainID
			m.mu.Unlock()
		}

		// Subscribe to new heads
		subscribeMsg := json.RawMessage(`{"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}`)
		err = conn.WriteMessage(websocket.TextMessage, subscribeMsg)
		if err != nil {
			conn.Close()
			m.updateBackendStatus(backend.Name, nil, fmt.Sprintf("Failed to subscribe: %v", err))
			time.Sleep(backoffDelay)
			continue
		}

		// Read subscription response
		_, msg, err := conn.ReadMessage()
		if err != nil {
			conn.Close()
			m.updateBackendStatus(backend.Name, nil, fmt.Sprintf("Failed to read subscription response: %v", err))
			time.Sleep(backoffDelay)
			continue
		}

		var subResponse struct {
			Result string `json:"result"`
			Error  *struct {
				Message string `json:"message"`
			} `json:"error"`
		}

		if err := json.Unmarshal(msg, &subResponse); err != nil || subResponse.Error != nil {
			conn.Close()
			errMsg := "Subscription failed"
			if subResponse.Error != nil {
				errMsg = subResponse.Error.Message
			}
			m.updateBackendStatus(backend.Name, nil, errMsg)
			time.Sleep(backoffDelay)
			continue
		}

		// Read new head notifications
		m.readNewHeads(conn, backend.Name, chainID)

		conn.Close()
		time.Sleep(backoffDelay)
	}
}

// getChainID gets the chain ID from a backend
func (m *ChainHeadMonitor) getChainID(conn *websocket.Conn, backendName string) (string, error) {
	// Send eth_chainId request
	chainIDMsg := json.RawMessage(`{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":"chainId"}`)
	if err := conn.WriteMessage(websocket.TextMessage, chainIDMsg); err != nil {
		return "", err
	}

	// Set read deadline
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer conn.SetReadDeadline(time.Time{})

	// Read response
	_, msg, err := conn.ReadMessage()
	if err != nil {
		return "", err
	}

	var response struct {
		Result string `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}

	if err := json.Unmarshal(msg, &response); err != nil {
		return "", err
	}

	if response.Error != nil {
		return "", fmt.Errorf("RPC error: %s", response.Error.Message)
	}

	return response.Result, nil
}

// readNewHeads reads new head notifications from WebSocket
func (m *ChainHeadMonitor) readNewHeads(conn *websocket.Conn, backendName string, chainID string) {
	// Set long read deadline for subscriptions
	conn.SetReadDeadline(time.Now().Add(60 * time.Second))

	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			m.updateBackendStatus(backendName, nil, fmt.Sprintf("WebSocket read error: %v", err))
			return
		}

		// Reset read deadline after successful read
		conn.SetReadDeadline(time.Now().Add(60 * time.Second))

		// Parse the subscription notification
		var notification struct {
			Params struct {
				Result struct {
					Number string `json:"number"` // Hex encoded block number
					Hash   string `json:"hash"`   // Block hash
				} `json:"result"`
			} `json:"params"`
		}

		if err := json.Unmarshal(msg, &notification); err != nil {
			continue // Skip malformed messages
		}

		// Convert hex block number to uint64
		if notification.Params.Result.Number != "" {
			blockNumber, err := strconv.ParseUint(strings.TrimPrefix(notification.Params.Result.Number, "0x"), 16, 64)
			if err != nil {
				continue
			}

			head := &ChainHead{
				BlockNumber: blockNumber,
				BlockHash:   notification.Params.Result.Hash,
				ChainID:     chainID,
				LastUpdate:  time.Now(),
				IsHealthy:   true,
			}

			m.updateBackendStatus(backendName, head, "")

			// Cache block hash if this is from primary backend
			if backendName == "primary" && notification.Params.Result.Hash != "" {
				m.cacheBlockHash(notification.Params.Result.Hash, blockNumber)
			}

			if m.enableDetailedLogs {
				log.Printf("Backend %s at block %d (hash: %s...)",
					backendName, blockNumber, head.BlockHash[:8])
			}
		}
	}
}

// updateBackendStatus updates the status of a backend
func (m *ChainHeadMonitor) updateBackendStatus(backendName string, head *ChainHead, errorMsg string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if head != nil {
		m.chainHeads[backendName] = head
	} else if errorMsg != "" {
		// Update or create entry with error
		if existing, exists := m.chainHeads[backendName]; exists {
			existing.IsHealthy = false
			existing.Error = errorMsg
			existing.LastUpdate = time.Now()
		} else {
			m.chainHeads[backendName] = &ChainHead{
				IsHealthy:  false,
				Error:      errorMsg,
				LastUpdate: time.Now(),
			}
		}
	}

	// Update enabled status
	m.updateEnabledStatus()
}

// updateEnabledStatus updates which backends are enabled based on chain head
func (m *ChainHeadMonitor) updateEnabledStatus() {
	// Get primary chain head
	primaryHead, primaryExists := m.chainHeads["primary"]
	if !primaryExists || !primaryHead.IsHealthy {
		// If primary is not healthy/available (e.g., during restarts), enable all healthy secondary backends
		if m.enableDetailedLogs {
			log.Printf("Primary backend not healthy/available - enabling all healthy secondary backends")
		}

		for _, backend := range m.backends {
			if backend.Role == "primary" {
				m.enabledBackends[backend.Name] = true // Always mark primary as enabled for routing
				continue
			}

			head, exists := m.chainHeads[backend.Name]
			if exists && head.IsHealthy {
				m.enabledBackends[backend.Name] = true
				if m.enableDetailedLogs {
					log.Printf("Backend %s enabled (primary unavailable)", backend.Name)
				}
			} else {
				m.enabledBackends[backend.Name] = false
			}
		}
		return
	}

	// Check each backend
	for _, backend := range m.backends {
		if backend.Role == "primary" {
			m.enabledBackends[backend.Name] = true
			continue
		}

		head, exists := m.chainHeads[backend.Name]
		if !exists || !head.IsHealthy {
			m.enabledBackends[backend.Name] = false
			if m.enableDetailedLogs {
				log.Printf("Backend %s disabled: not healthy", backend.Name)
			}
			continue
		}

		// Check if on same chain
		if head.ChainID != primaryHead.ChainID {
			m.enabledBackends[backend.Name] = false
			if m.enableDetailedLogs {
				log.Printf("Backend %s disabled: wrong chain ID (got %s, want %s)",
					backend.Name, head.ChainID, primaryHead.ChainID)
			}
			continue
		}

		// STRICT RULE: Only allow if secondary matches primary height or is ahead
		if head.BlockNumber < primaryHead.BlockNumber {
			m.enabledBackends[backend.Name] = false
			if m.enableDetailedLogs {
				log.Printf("Backend %s disabled: behind primary (at block %d, primary at %d)",
					backend.Name, head.BlockNumber, primaryHead.BlockNumber)
			}
			continue
		}

		// Secondary is at same height or ahead - enable it
		m.enabledBackends[backend.Name] = true
		if m.enableDetailedLogs {
			if head.BlockNumber > primaryHead.BlockNumber {
				log.Printf("Backend %s enabled: ahead of primary (at block %d, primary at %d)",
					backend.Name, head.BlockNumber, primaryHead.BlockNumber)
			} else {
				log.Printf("Backend %s enabled: at same block as primary (%d)",
					backend.Name, head.BlockNumber)
			}
		}
	}
}

// checkBackendHealth performs periodic health checks
func (m *ChainHeadMonitor) checkBackendHealth() {
	m.mu.Lock()
	defer m.mu.Unlock()

	now := time.Now()

	// Check for stale data (no update in 90 seconds)
	for _, head := range m.chainHeads {
		if now.Sub(head.LastUpdate) > 90*time.Second {
			head.IsHealthy = false
			head.Error = "No recent updates"
		}
	}

	// Update enabled status
	m.updateEnabledStatus()

	// Log current status if detailed logs enabled
	if m.enableDetailedLogs {
		log.Printf("Chain head monitor status:")
		for name, enabled := range m.enabledBackends {
			status := "disabled"
			if enabled {
				status = "enabled"
			}

			if head, exists := m.chainHeads[name]; exists {
				if head.IsHealthy {
					log.Printf("  %s: %s, block %d, chain %s", name, status, head.BlockNumber, head.ChainID)
				} else {
					log.Printf("  %s: %s, error: %s", name, status, head.Error)
				}
			} else {
				log.Printf("  %s: %s, no data", name, status)
			}
		}
	}
}

// GetStatus returns the current status of all backends
func (m *ChainHeadMonitor) GetStatus() map[string]ChainHead {
	m.mu.RLock()
	defer m.mu.RUnlock()

	status := make(map[string]ChainHead)
	for name, head := range m.chainHeads {
		status[name] = *head
	}
	return status
}

// cacheBlockHash adds a block hash to the cache, maintaining a maximum of 128 entries
func (m *ChainHeadMonitor) cacheBlockHash(blockHash string, blockNumber uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Check if hash already exists
	if _, exists := m.blockHashCache[blockHash]; exists {
		return
	}

	// Add to cache
	m.blockHashCache[blockHash] = blockNumber
	m.blockHashOrder = append(m.blockHashOrder, blockHash)

	// Maintain maximum cache size of 128 blocks
	if len(m.blockHashOrder) > 128 {
		// Remove oldest entry
		oldestHash := m.blockHashOrder[0]
		delete(m.blockHashCache, oldestHash)
		m.blockHashOrder = m.blockHashOrder[1:]
	}
}

// GetBlockNumberForHash returns the block number for a given hash if it's in the cache
func (m *ChainHeadMonitor) GetBlockNumberForHash(blockHash string) (uint64, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	blockNumber, exists := m.blockHashCache[blockHash]
	return blockNumber, exists
}
