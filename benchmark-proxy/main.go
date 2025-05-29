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
	methodCUPrices                     map[string]int  // Map of method names to CU prices
	totalCU                            int             // Total CU earned
	methodCU                           map[string]int  // Track CU earned per method
	historicalCU                       []CUDataPoint   // Historical CU data for different time windows
	hasSecondaryBackends               bool            // Track if secondary backends are configured
	skippedSecondaryRequests           int             // Track how many secondary requests were skipped
	secondaryProbe                     *SecondaryProbe // Reference to secondary probe
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
			reqBody := []byte(fmt.Sprintf(
				`{"jsonrpc":"2.0","method":"%s","params":[],"id":"probe-%d"}`,
				method, time.Now().UnixNano(),
			))

			req, err := http.NewRequest("POST", backend.URL, bytes.NewReader(reqBody))
			if err != nil {
				continue
			}

			req.Header.Set("Content-Type", "application/json")

			start := time.Now()
			resp, err := sp.client.Do(req)
			duration := time.Since(start)

			if err == nil && resp != nil {
				resp.Body.Close()

				if resp.StatusCode == 200 {
					successfulProbes++

					// Update method timing (use minimum across all backends)
					if currentMin, exists := newMethodTimings[method]; !exists || duration < currentMin {
						newMethodTimings[method] = duration
					}

					// Track backend minimum
					if duration < backendMin {
						backendMin = duration
					}

					if sp.enableDetailedLogs {
						log.Printf("Probe: backend=%s method=%s duration=%s status=%d",
							backend.Name, method, duration, resp.StatusCode)
					}
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

	sc.totalRequests++
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

		if sc.secondaryProbe.failureCount > 0 {
			fmt.Printf("Probe Failures: %d consecutive\n", sc.secondaryProbe.failureCount)
		}

		sc.secondaryProbe.mu.RUnlock()
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

			fmt.Printf("  %-50s Count: %-5d Avg: %-10s Min: %-10s Max: %-10s p50: %-10s p90: %-10s p99: %-10s CU: %d x %d = %d\n",
				displayLabel, len(durations),
				formatDuration(avg), formatDuration(minDuration), formatDuration(max),
				formatDuration(p50), formatDuration(p90), formatDuration(p99),
				cuPrice, len(durations), cuEarned)
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
			MaxIdleConns:        100,
			MaxIdleConnsPerHost: 100,
			IdleConnTimeout:     90 * time.Second,
			DisableCompression:  true, // Typically JSON-RPC doesn't benefit from compression
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
			handleRequest(w, r, backends, client, enableDetailedLogs == "true", statsCollector, secondaryProbe)
		}
	})

	log.Fatal(http.ListenAndServe(listenAddr, nil))
}

func handleRequest(w http.ResponseWriter, r *http.Request, backends []Backend, client *http.Client, enableDetailedLogs bool, statsCollector *StatsCollector, secondaryProbe *SecondaryProbe) {
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

	// Try to parse the method from the JSON-RPC request
	method := "unknown"
	var jsonRPCReq JSONRPCRequest
	if err := json.Unmarshal(body, &jsonRPCReq); err == nil && jsonRPCReq.Method != "" {
		method = jsonRPCReq.Method
	}

	// Get delay threshold for secondary backends
	var secondaryDelay time.Duration
	if secondaryProbe != nil {
		// Use probe-based delay
		secondaryDelay = secondaryProbe.getDelayForMethod(method)
	} else {
		// Fall back to p75 approach
		secondaryDelay = statsCollector.GetPrimaryP75ForMethod(method)
	}

	if enableDetailedLogs {
		log.Printf("Method: %s, Secondary delay: %s (probe-based: %v)",
			method, secondaryDelay, secondaryProbe != nil)
	}

	// Check if this is a stateful method that must go to primary only
	isStateful := isStatefulMethod(method)

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
				delayTimer := time.NewTimer(secondaryDelay)
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
						Method:   method,
						Duration: time.Since(goroutineStartTime),
					}
					return
				case <-primaryFailedFast:
					// Primary failed immediately, start secondary now
					delayTimer.Stop()
					if enableDetailedLogs {
						log.Printf("Primary failed fast for %s, starting secondary immediately", method)
					}
				}
			}

			// Create a new request (no longer using context for cancellation)
			backendReq, err := http.NewRequest(r.Method, b.URL, bytes.NewReader(body))
			if err != nil {
				statsChan <- ResponseStats{
					Backend:  b.Name,
					Error:    err,
					Method:   method,
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
					Method:   method,
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
				Method:     method,
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
					response.backend, method, streamingDuration, totalRequestDuration, reason)
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
