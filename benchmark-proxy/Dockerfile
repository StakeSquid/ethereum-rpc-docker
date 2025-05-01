# Build stage
FROM golang:1.21-alpine AS builder

WORKDIR /app

# Initialize Go modules if not already done
RUN go mod init benchmark-proxy

# Add the dependency before building
RUN go get github.com/gorilla/websocket

# Copy source code
COPY . .

# Build the application with CGO disabled for a static binary
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o benchmark-proxy main.go

# Runtime stage (if you're using a multi-stage build)
FROM alpine:latest

WORKDIR /app

# Copy the binary from the build stage
COPY --from=builder /app/benchmark-proxy .

# Run the application
ENTRYPOINT ["./benchmark-proxy"]