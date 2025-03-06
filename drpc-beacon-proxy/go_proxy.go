package main

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
)

var targetBaseURL string

func init() {
	// Set the target base URL from environment variable or default value
	targetBaseURL = os.Getenv("TARGET_URL")
	if targetBaseURL == "" {
		targetBaseURL = "https://lb.drpc.org/rest/eth-beacon-chain-holesky"
	}
}

func proxyHandler(w http.ResponseWriter, r *http.Request) {
	// Parse the incoming request
	subpath := r.URL.Path
	query := r.URL.Query()

	// Add the dkey parameter to the query string
	dkey := os.Getenv("DKEY")
	if dkey == "" {
		dkey = "your-default-dkey"
	}
	query.Set("dkey", dkey)

	// Build the new URL for the request
	proxyURL := fmt.Sprintf("%s%s?%s", targetBaseURL, subpath, query.Encode())
	log.Printf("Forwarding request to: %s", proxyURL)

	// Create a new HTTP request to forward to the upstream API
	req, err := http.NewRequest(r.Method, proxyURL, r.Body)
	if err != nil {
		http.Error(w, "Error creating request: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Copy the incoming request headers to the new request, except for 'Host' and 'Accept-Encoding'
	req.Header = r.Header.Clone()
	req.Header.Del("Host")
	req.Header.Del("Accept-Encoding")

	// Send the request to the upstream API
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, "Error forwarding request: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()

	// Handle the response
	body := resp.Body
	if resp.Header.Get("Content-Encoding") == "gzip" {
		log.Println("Response is gzipped, decompressing...")
		// Decompress the gzip response
		gzipReader, err := gzip.NewReader(resp.Body)
		if err != nil {
			http.Error(w, "Error decompressing gzip response: "+err.Error(), http.StatusInternalServerError)
			return
		}
		defer gzipReader.Close()
		body = gzipReader
	}

	// Write the response headers and body back to the client
	for key, values := range resp.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, body)
}

func main() {
	// Set up the HTTP server
	http.HandleFunc("/", proxyHandler)

	port := ":80"
	log.Printf("Starting proxy server on port %s", port)
	err := http.ListenAndServe(port, nil)
	if err != nil {
		log.Fatalf("Error starting server: %s", err)
	}
}
