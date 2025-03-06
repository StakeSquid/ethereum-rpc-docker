# Use a Go base image
FROM golang:1.20-alpine

# Set the working directory in the container
WORKDIR /app

# Copy the Go files into the container
COPY . .

# Build the Go application
RUN go build -o proxy-server .

# Set environment variables for DKEY and TARGET_URL
ENV DKEY="Ate9WjrXn0VNqbW90nyMLzBECtvs-kcR754SnqSgS7QB"
ENV TARGET_URL="https://lb.drpc.org/rest/eth-beacon-chain-holesky"

# Expose port 80
EXPOSE 80

# Run the Go proxy server
CMD ["./proxy-server"]
