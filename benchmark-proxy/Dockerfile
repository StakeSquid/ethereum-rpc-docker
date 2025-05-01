FROM golang:1.21-alpine as builder

WORKDIR /app
COPY . .

# Build with optimization flags
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o benchmark-proxy main.go

FROM alpine:3.18

RUN apk --no-cache add ca-certificates tzdata
WORKDIR /app
COPY --from=builder /app/benchmark-proxy .

EXPOSE 8080
CMD ["./benchmark-proxy"] 