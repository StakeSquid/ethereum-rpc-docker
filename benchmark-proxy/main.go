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
	ethCallStats                       *EthCallStats     // Track eth_call specific statistics
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

// MethodRouting contains configuration for method routing decisions
type MethodRouting struct {
	SecondaryWhitelist map[string]bool // Methods allowed on secondary backends
	PreferSecondary    map[string]bool // Methods that should prefer secondary backends
}

// RequestInfo contains parsed information about a JSON-RPC request
type RequestInfo struct {
	Method    string
	BlockTag  string
	HasParams bool
}

// EthCallFeatures tracks specific features used in eth_call requests
type EthCallFeatures struct {
	HasStateOverrides bool   // Whether the call includes state overrides
	BlockTagType      string // Type of block tag: latest, pending, safe, finalized, number, hash, earliest
	HasAccessList     bool   // Whether the call includes an access list
	GasLimit          uint64 // Gas limit if specified
	DataSize          int    // Size of the call data
	IsContractCall    bool   // Whether 'to' address is specified
	HasValue          bool   // Whether the call includes value transfer
}

// EthCallStats tracks statistics for eth_call requests by feature category
type EthCallStats struct {
	TotalCount            int
	SecondaryWins         int
	PrimaryOnlyCount      int // Requests that only went to primary
	ErrorCount            int
	ByBlockTagType        map[string]*EthCallCategoryStats
	WithStateOverrides    *EthCallCategoryStats
	WithoutStateOverrides *EthCallCategoryStats
	WithAccessList        *EthCallCategoryStats
	WithoutAccessList     *EthCallCategoryStats
	ByDataSizeRange       map[string]*EthCallCategoryStats // Ranges: small(<1KB), medium(1-10KB), large(>10KB)
}

// EthCallCategoryStats tracks stats for a specific category of eth_call
type EthCallCategoryStats struct {
	Count            int
	SecondaryWins    int
	PrimaryOnlyCount int
	ErrorCount       int
	AverageDuration  time.Duration
	P50Duration      time.Duration
	P90Duration      time.Duration
	Durations        []time.Duration // For calculating percentiles
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

// parseEthCallFeatures extracts feature information from an eth_call request
func parseEthCallFeatures(params json.RawMessage, blockTag string) (*EthCallFeatures, error) {
	features := &EthCallFeatures{
		BlockTagType: classifyBlockTag(blockTag),
	}

	// eth_call params: [call_object, block_tag, state_overrides]
	var paramArray []json.RawMessage
	if err := json.Unmarshal(params, &paramArray); err != nil {
		return nil, err
	}

	if len(paramArray) == 0 {
		return nil, fmt.Errorf("eth_call requires at least one parameter")
	}

	// Parse the call object (first parameter)
	var callObject struct {
		From       json.RawMessage `json:"from"`
		To         json.RawMessage `json:"to"`
		Gas        json.RawMessage `json:"gas"`
		GasPrice   json.RawMessage `json:"gasPrice"`
		Value      json.RawMessage `json:"value"`
		Data       json.RawMessage `json:"data"`
		AccessList json.RawMessage `json:"accessList"`
	}

	if err := json.Unmarshal(paramArray[0], &callObject); err != nil {
		return nil, err
	}

	// Check if contract call (has 'to' address)
	if len(callObject.To) > 0 {
		var to string
		if err := json.Unmarshal(callObject.To, &to); err == nil && to != "" && to != "0x0" {
			features.IsContractCall = true
		}
	}

	// Check if has value
	if len(callObject.Value) > 0 {
		var value string
		if err := json.Unmarshal(callObject.Value, &value); err == nil && value != "" && value != "0x0" {
			features.HasValue = true
		}
	}

	// Check data size
	if len(callObject.Data) > 0 {
		var data string
		if err := json.Unmarshal(callObject.Data, &data); err == nil {
			// Remove 0x prefix and calculate byte size
			if strings.HasPrefix(data, "0x") {
				features.DataSize = (len(data) - 2) / 2 // Each byte is 2 hex chars
			}
		}
	}

	// Check gas limit
	if len(callObject.Gas) > 0 {
		var gasHex string
		if err := json.Unmarshal(callObject.Gas, &gasHex); err == nil && gasHex != "" {
			if strings.HasPrefix(gasHex, "0x") {
				gas, err := strconv.ParseUint(gasHex[2:], 16, 64)
				if err == nil {
					features.GasLimit = gas
				}
			}
		}
	}

	// Check for access list
	if len(callObject.AccessList) > 0 && string(callObject.AccessList) != "null" {
		features.HasAccessList = true
	}

	// Check for state overrides (third parameter)
	if len(paramArray) >= 3 && len(paramArray[2]) > 0 && string(paramArray[2]) != "null" && string(paramArray[2]) != "{}" {
		features.HasStateOverrides = true
	}

	return features, nil
}

// classifyBlockTag categorizes a block tag into types
func classifyBlockTag(blockTag string) string {
	if blockTag == "" {
		return "latest" // Default
	}

	// Check for special tags
	switch blockTag {
	case "latest", "pending", "safe", "finalized", "earliest":
		return blockTag
	}

	// Check if it's a block hash (0x followed by 64 hex chars)
	if len(blockTag) == 66 && strings.HasPrefix(blockTag, "0x") {
		return "hash"
	}

	// Check if it's a block number (hex)
	if strings.HasPrefix(blockTag, "0x") {
		_, err := strconv.ParseUint(strings.TrimPrefix(blockTag, "0x"), 16, 64)
		if err == nil {
			return "number"
		}
	}

	return "unknown"
}

// getDataSizeRange categorizes data size into ranges
func getDataSizeRange(dataSize int) string {
	if dataSize < 1024 { // Less than 1KB
		return "small"
	} else if dataSize <= 10240 { // 1KB to 10KB
		return "medium"
	}
	return "large" // More than 10KB
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

// initEthCallStats initializes the eth_call statistics structure
func initEthCallStats() *EthCallStats {
	return &EthCallStats{
		ByBlockTagType: map[string]*EthCallCategoryStats{
			"latest":    &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
			"pending":   &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
			"safe":      &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
			"finalized": &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
			"earliest":  &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
			"number":    &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
			"hash":      &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
		},
		WithStateOverrides:    &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
		WithoutStateOverrides: &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
		WithAccessList:        &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
		WithoutAccessList:     &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
		ByDataSizeRange: map[string]*EthCallCategoryStats{
			"small":  &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
			"medium": &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
			"large":  &EthCallCategoryStats{Durations: make([]time.Duration, 0, 100)},
		},
	}
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
		ethCallStats:                       initEthCallStats(), // Initialize eth_call stats
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

// AddEthCallStats adds statistics for an eth_call request
func (sc *StatsCollector) AddEthCallStats(features *EthCallFeatures, winningBackend string,
	duration time.Duration, hasError bool, sentToSecondary bool) {

	sc.mu.Lock()
	defer sc.mu.Unlock()

	// Update total count
	sc.ethCallStats.TotalCount++

	// Update error count
	if hasError {
		sc.ethCallStats.ErrorCount++
	}

	// Update wins
	if winningBackend != "" && winningBackend != "primary" {
		sc.ethCallStats.SecondaryWins++
	}

	// Update primary-only count
	if !sentToSecondary {
		sc.ethCallStats.PrimaryOnlyCount++
	}

	// Update block tag type stats
	if catStats, exists := sc.ethCallStats.ByBlockTagType[features.BlockTagType]; exists {
		catStats.Count++
		if hasError {
			catStats.ErrorCount++
		}
		if winningBackend != "" && winningBackend != "primary" {
			catStats.SecondaryWins++
		}
		if !sentToSecondary {
			catStats.PrimaryOnlyCount++
		}
		if !hasError {
			catStats.Durations = append(catStats.Durations, duration)
		}
	}

	// Update state override stats
	if features.HasStateOverrides {
		sc.ethCallStats.WithStateOverrides.Count++
		if hasError {
			sc.ethCallStats.WithStateOverrides.ErrorCount++
		}
		if winningBackend != "" && winningBackend != "primary" {
			sc.ethCallStats.WithStateOverrides.SecondaryWins++
		}
		if !sentToSecondary {
			sc.ethCallStats.WithStateOverrides.PrimaryOnlyCount++
		}
		if !hasError {
			sc.ethCallStats.WithStateOverrides.Durations = append(sc.ethCallStats.WithStateOverrides.Durations, duration)
		}
	} else {
		sc.ethCallStats.WithoutStateOverrides.Count++
		if hasError {
			sc.ethCallStats.WithoutStateOverrides.ErrorCount++
		}
		if winningBackend != "" && winningBackend != "primary" {
			sc.ethCallStats.WithoutStateOverrides.SecondaryWins++
		}
		if !sentToSecondary {
			sc.ethCallStats.WithoutStateOverrides.PrimaryOnlyCount++
		}
		if !hasError {
			sc.ethCallStats.WithoutStateOverrides.Durations = append(sc.ethCallStats.WithoutStateOverrides.Durations, duration)
		}
	}

	// Update access list stats
	if features.HasAccessList {
		sc.ethCallStats.WithAccessList.Count++
		if hasError {
			sc.ethCallStats.WithAccessList.ErrorCount++
		}
		if winningBackend != "" && winningBackend != "primary" {
			sc.ethCallStats.WithAccessList.SecondaryWins++
		}
		if !sentToSecondary {
			sc.ethCallStats.WithAccessList.PrimaryOnlyCount++
		}
		if !hasError {
			sc.ethCallStats.WithAccessList.Durations = append(sc.ethCallStats.WithAccessList.Durations, duration)
		}
	} else {
		sc.ethCallStats.WithoutAccessList.Count++
		if hasError {
			sc.ethCallStats.WithoutAccessList.ErrorCount++
		}
		if winningBackend != "" && winningBackend != "primary" {
			sc.ethCallStats.WithoutAccessList.SecondaryWins++
		}
		if !sentToSecondary {
			sc.ethCallStats.WithoutAccessList.PrimaryOnlyCount++
		}
		if !hasError {
			sc.ethCallStats.WithoutAccessList.Durations = append(sc.ethCallStats.WithoutAccessList.Durations, duration)
		}
	}

	// Update data size range stats
	dataSizeRange := getDataSizeRange(features.DataSize)
	if catStats, exists := sc.ethCallStats.ByDataSizeRange[dataSizeRange]; exists {
		catStats.Count++
		if hasError {
			catStats.ErrorCount++
		}
		if winningBackend != "" && winningBackend != "primary" {
			catStats.SecondaryWins++
		}
		if !sentToSecondary {
			catStats.PrimaryOnlyCount++
		}
		if !hasError {
			catStats.Durations = append(catStats.Durations, duration)
		}
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
