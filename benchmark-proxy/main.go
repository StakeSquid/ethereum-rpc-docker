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
}

func NewStatsCollector(summaryInterval time.Duration) *StatsCollector {
	sc := &StatsCollector{
		requestStats:    make([]ResponseStats, 0, 1000),
		methodStats:     make(map[string][]time.Duration),
		startTime:       time.Now(),
		summaryInterval: summaryInterval,
	}

	// Start the periodic summary goroutine
	go sc.periodicSummary()

	return sc
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

func (sc *StatsCollector) printSummary() {
	sc.mu.Lock()
	defer sc.mu.Unlock()

	uptime := time.Since(sc.startTime)
	fmt.Printf("\n=== BENCHMARK PROXY SUMMARY ===\n")
	fmt.Printf("Uptime: %s\n", uptime.Round(time.Second))
	fmt.Printf("Total HTTP Requests: %d\n", sc.totalRequests)
	fmt.Printf("Total WebSocket Connections: %d\n", sc.totalWsConnections)
	fmt.Printf("Error Rate: %.2f%%\n", float64(sc.errorCount)/float64(sc.totalRequests+sc.totalWsConnections)*100)

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
		p99idx := len(primaryDurations) * 99 / 100

		fmt.Printf("\nPrimary Backend Response Times:\n")
		fmt.Printf("  Min: %s\n", min)
		fmt.Printf("  Avg: %s\n", avg)
		fmt.Printf("  Max: %s\n", max)
		fmt.Printf("  p50: %s\n", primaryDurations[p50idx])
		fmt.Printf("  p90: %s\n", primaryDurations[p90idx])
		fmt.Printf("  p99: %s\n", primaryDurations[p99idx])
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

			fmt.Printf("  %-20s Count: %-5d Avg: %-10s Min: %-10s Max: %-10s p50: %-10s p90: %-10s p99: %-10s\n",
				method, len(durations), avg, minDuration, max, p50, p90, p99)
		}
	}

	fmt.Printf("================================\n\n")

	// Keep only the last 1000 requests to prevent unlimited memory growth
	if len(sc.requestStats) > 1000 {
		sc.requestStats = sc.requestStats[len(sc.requestStats)-1000:]
	}

	// Trim method stats to prevent unlimited growth
	for method, durations := range sc.methodStats {
		if len(durations) > 1000 {
			sc.methodStats[method] = durations[len(durations)-1000:]
		}
	}

	// Keep only the last 1000 websocket connections to prevent unlimited memory growth
	if len(sc.wsConnections) > 1000 {
		sc.wsConnections = sc.wsConnections[len(sc.wsConnections)-1000:]
	}
}

// Helper function to avoid potential index out of bounds
func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func main() {
	// Get configuration from environment variables
	listenAddr := getEnv("LISTEN_ADDR", ":8080")
	primaryBackend := getEnv("PRIMARY_BACKEND", "http://localhost:8545")
	secondaryBackendsStr := getEnv("SECONDARY_BACKENDS", "")
	summaryIntervalStr := getEnv("SUMMARY_INTERVAL", "60") // Default 60 seconds

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

	// Configure websocket upgrader
	upgrader := websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		// Allow all origins
		CheckOrigin: func(r *http.Request) bool { return true },
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Check if this is a WebSocket upgrade request
		if websocket.IsWebSocketUpgrade(r) {
			handleWebSocketRequest(w, r, backends, client, &upgrader, statsCollector)
		} else {
			// Handle regular HTTP request
			stats := handleRequest(w, r, backends, client)
			statsCollector.AddStats(stats, 0) // The 0 is a placeholder, we're not using totalDuration in the collector
		}
	})

	log.Fatal(http.ListenAndServe(listenAddr, nil))
}

func handleRequest(w http.ResponseWriter, r *http.Request, backends []Backend, client *http.Client) []ResponseStats {
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

	// Log response times
	totalDuration := time.Since(startTime)
	logResponseStats(totalDuration, stats)
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

	// Connect to all backends
	var wg sync.WaitGroup
	for _, backend := range backends {
		wg.Add(1)
		go func(b Backend) {
			defer wg.Done()

			// Create backend URL with ws/wss instead of http/https
			backendURL := strings.Replace(b.URL, "http://", "ws://", 1)
			backendURL = strings.Replace(backendURL, "https://", "wss://", 1)

			// Copy headers for the dialer
			header := http.Header{}
			for name, values := range r.Header {
				for _, value := range values {
					header.Add(name, value)
				}
			}

			startTime := time.Now()
			// Connect to backend WebSocket
			dialer := websocket.DefaultDialer
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
