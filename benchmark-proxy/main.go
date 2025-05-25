// hi

package main

import (
	"bytes"
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
	Timestamp time.Time
	CU        int
}

// StatsCollector maintains statistics for periodic summaries
type StatsCollector struct {
	mu                 sync.Mutex
	requestStats       []ResponseStats
	methodStats        map[string][]time.Duration // Track durations by method
	totalRequests      int
	errorCount         int
	wsConnections      []WebSocketStats // Track websocket connections
	totalWsConnections int
	startTime          time.Time
	summaryInterval    time.Duration
	methodCUPrices     map[string]int // Map of method names to CU prices
	totalCU            int            // Total CU earned
	methodCU           map[string]int // Track CU earned per method
	historicalCU       []CUDataPoint  // Historical CU data for different time windows
}

func NewStatsCollector(summaryInterval time.Duration) *StatsCollector {
	sc := &StatsCollector{
		requestStats:    make([]ResponseStats, 0, 1000),
		methodStats:     make(map[string][]time.Duration),
		startTime:       time.Now(),
		summaryInterval: summaryInterval,
		methodCUPrices:  initCUPrices(), // Initialize CU prices
		methodCU:        make(map[string]int),
		historicalCU:    make([]CUDataPoint, 0, 2000), // Store up to ~24 hours of 1-minute intervals
	}

	// Start the periodic summary goroutine
	go sc.periodicSummary()

	return sc
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

	// Add stats to the collection
	for _, stat := range stats {
		sc.requestStats = append(sc.requestStats, stat)
		if stat.Error != nil {
			sc.errorCount++
		}

		// Track method-specific stats for primary backend
		if stat.Backend == "primary" && stat.Error == nil {
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

	uptime := time.Since(sc.startTime)
	fmt.Printf("\n=== BENCHMARK PROXY SUMMARY ===\n")
	fmt.Printf("Uptime: %s\n", uptime.Round(time.Second))
	fmt.Printf("Total HTTP Requests: %d\n", sc.totalRequests)
	fmt.Printf("Total WebSocket Connections: %d\n", sc.totalWsConnections)
	fmt.Printf("Error Rate: %.2f%%\n", float64(sc.errorCount)/float64(sc.totalRequests+sc.totalWsConnections)*100)
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
			actualDuration := time.Duration(0)

			// Check current interval
			if sc.startTime.After(cutoff) {
				actualDuration = now.Sub(sc.startTime)
			}

			// Check historical data
			for i := len(sc.historicalCU) - 1; i >= 0; i-- {
				point := sc.historicalCU[i]
				if point.Timestamp.Before(cutoff) {
					break
				}
				actualDuration = now.Sub(point.Timestamp)
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
			durations := sc.methodStats[method]
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

			fmt.Printf("  %-30s Count: %-5d Avg: %-10s Min: %-10s Max: %-10s p50: %-10s p90: %-10s p99: %-10s CU: %d x %d = %d\n",
				method, len(durations),
				formatDuration(avg), formatDuration(minDuration), formatDuration(max),
				formatDuration(p50), formatDuration(p90), formatDuration(p99),
				cuPrice, len(durations), cuEarned)
		}
	}

	fmt.Printf("================================\n\n")

	// Store current interval's CU data in historical data before resetting
	if sc.totalCU > 0 {
		sc.historicalCU = append(sc.historicalCU, CUDataPoint{
			Timestamp: time.Now(),
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

	// Reset CU counters for the next interval
	sc.totalCU = 0
	sc.methodCU = make(map[string]int)

	// Reset error count for the next interval
	sc.errorCount = 0
	sc.totalRequests = 0
	sc.totalWsConnections = 0

	// Reset the start time for the next interval
	sc.startTime = time.Now()
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
	actualDataDuration := time.Duration(0)

	// First add the current interval's CU if it's within the window
	if sc.startTime.After(cutoff) {
		totalCU += sc.totalCU
		actualDataDuration = now.Sub(sc.startTime)
	}

	// Add historical CU data within the window
	for i := len(sc.historicalCU) - 1; i >= 0; i-- {
		point := sc.historicalCU[i]
		if point.Timestamp.Before(cutoff) {
			break // Data is too old
		}
		totalCU += point.CU

		// Update actual data duration
		if actualDataDuration == 0 {
			actualDataDuration = now.Sub(point.Timestamp)
		} else {
			actualDataDuration = now.Sub(point.Timestamp)
		}
	}

	// Check if we need extrapolation
	needsExtrapolation := actualDataDuration < window && actualDataDuration > 0

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

func main() {
	// Get configuration from environment variables
	listenAddr := getEnv("LISTEN_ADDR", ":8080")
	primaryBackend := getEnv("PRIMARY_BACKEND", "http://localhost:8545")
	secondaryBackendsStr := getEnv("SECONDARY_BACKENDS", "")
	summaryIntervalStr := getEnv("SUMMARY_INTERVAL", "60")        // Default 60 seconds
	enableDetailedLogs := getEnv("ENABLE_DETAILED_LOGS", "false") // Default to disabled

	summaryInterval, err := strconv.Atoi(summaryIntervalStr)
	if err != nil {
		log.Printf("Invalid SUMMARY_INTERVAL, using default of 60 seconds")
		summaryInterval = 60
	}

	// Create stats collector for periodic summaries
	statsCollector := NewStatsCollector(time.Duration(summaryInterval) * time.Second)

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
			stats := handleRequest(w, r, backends, client, enableDetailedLogs == "true")
			statsCollector.AddStats(stats, 0) // The 0 is a placeholder, we're not using totalDuration in the collector
		}
	})

	log.Fatal(http.ListenAndServe(listenAddr, nil))
}

func handleRequest(w http.ResponseWriter, r *http.Request, backends []Backend, client *http.Client, enableDetailedLogs bool) []ResponseStats {
	startTime := time.Now()

	// Read the entire request body
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Error reading request body", http.StatusBadRequest)
		return nil
	}
	defer r.Body.Close()

	// Try to parse the method from the JSON-RPC request
	method := "unknown"
	var jsonRPCReq JSONRPCRequest
	if err := json.Unmarshal(body, &jsonRPCReq); err == nil && jsonRPCReq.Method != "" {
		method = jsonRPCReq.Method
	}

	// Process backends in parallel
	var wg sync.WaitGroup
	statsChan := make(chan ResponseStats, len(backends))
	primaryRespChan := make(chan *http.Response, 1)
	primaryErrChan := make(chan error, 1)

	for _, backend := range backends {
		wg.Add(1)
		go func(b Backend) {
			defer wg.Done()

			// Create a new request
			backendReq, err := http.NewRequest(r.Method, b.URL, bytes.NewReader(body))
			if err != nil {
				statsChan <- ResponseStats{
					Backend: b.Name,
					Error:   err,
					Method:  method,
				}
				if b.Role == "primary" {
					primaryErrChan <- err
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
				statsChan <- ResponseStats{
					Backend:  b.Name,
					Duration: reqDuration,
					Error:    err,
					Method:   method,
				}
				if b.Role == "primary" {
					primaryErrChan <- err
				}
				return
			}
			defer resp.Body.Close()

			statsChan <- ResponseStats{
				Backend:    b.Name,
				StatusCode: resp.StatusCode,
				Duration:   reqDuration,
				Method:     method,
			}

			if b.Role == "primary" {
				// For primary, we need to return this response to the client
				respBody, err := io.ReadAll(resp.Body)
				if err != nil {
					primaryErrChan <- err
					return
				}

				// Create a new response to send back to client
				primaryResp := *resp
				primaryResp.Body = io.NopCloser(bytes.NewReader(respBody))
				primaryRespChan <- &primaryResp
			}
		}(backend)
	}

	// Wait for primary response
	select {
	case primaryResp := <-primaryRespChan:
		// Copy the response to the client
		for name, values := range primaryResp.Header {
			for _, value := range values {
				w.Header().Add(name, value)
			}
		}
		w.WriteHeader(primaryResp.StatusCode)
		io.Copy(w, primaryResp.Body)
	case err := <-primaryErrChan:
		http.Error(w, "Error from primary backend: "+err.Error(), http.StatusBadGateway)
	case <-time.After(30 * time.Second):
		http.Error(w, "Timeout waiting for primary backend", http.StatusGatewayTimeout)
	}

	// Wait for all goroutines to complete
	go func() {
		wg.Wait()
		close(statsChan)
	}()

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
	return stats
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
				return
			}
			defer backendConn.Close()

			// Set max message size for backend connection
			backendConn.SetReadLimit(50 * 1024 * 1024) // 50MB message size limit

			stats.IsActive = true
			statsCollector.AddWebSocketStats(stats)

			// If this is the primary backend, set up bidirectional proxying
			if b.Role == "primary" {
				// Forward messages from client to primary backend
				go func() {
					for {
						messageType, message, err := clientConn.ReadMessage()
						if err != nil {
							log.Printf("Error reading from client: %v", err)
							return
						}

						err = backendConn.WriteMessage(messageType, message)
						if err != nil {
							log.Printf("Error writing to primary backend: %v", err)
							return
						}
					}
				}()

				// Forward messages from primary backend to client
				for {
					messageType, message, err := backendConn.ReadMessage()
					if err != nil {
						log.Printf("Error reading from primary backend: %v", err)
						return
					}

					err = clientConn.WriteMessage(messageType, message)
					if err != nil {
						log.Printf("Error writing to client: %v", err)
						return
					}
				}
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
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}
