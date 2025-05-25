# Multi-stage build for reth with architecture-specific optimizations
ARG LLVM_IMAGE=snowstep/llvm
ARG LLVM_VERSION=20250514100911
FROM ${LLVM_IMAGE}:${LLVM_VERSION} as builder

# Install build dependencies and tools
RUN apt-get update && apt-get install -y \
    curl \
    git \
    libssl-dev \
    pkg-config \
    wget \
    ninja-build \
    ccache \
    && rm -rf /var/lib/apt/lists/*

# Install Rust
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --no-modify-path --default-toolchain stable --profile minimal

# Install mold linker (faster than lld)
RUN wget https://github.com/rui314/mold/releases/download/v2.30.0/mold-2.30.0-x86_64-linux.tar.gz && \
    tar xf mold-2.30.0-x86_64-linux.tar.gz && \
    cp mold-2.30.0-x86_64-linux/bin/mold /usr/local/bin/ && \
    cp -r mold-2.30.0-x86_64-linux/lib/* /usr/local/lib/ && \
    rm -rf mold-2.30.0-x86_64-linux*

# Install sccache for build caching
RUN wget https://github.com/mozilla/sccache/releases/download/v0.7.4/sccache-v0.7.4-x86_64-unknown-linux-musl.tar.gz && \
    tar xf sccache-v0.7.4-x86_64-unknown-linux-musl.tar.gz && \
    mv sccache-v0.7.4-x86_64-unknown-linux-musl/sccache /usr/local/bin/ && \
    rm -rf sccache-v0.7.4-x86_64-unknown-linux-musl*

# Build arguments for customization
ARG ARCH_TARGET=native
ARG RETH_VERSION=v1.4.3
ARG RETH_REPO=https://github.com/paradigmxyz/reth
ARG ENABLE_LTO=true
ARG PROFILE=maxperf
ARG BUILD_OP_RETH=false

# Set up cargo for maximum performance with aggressive optimizations
RUN mkdir -p /root/.cargo && \
    echo '[profile.maxperf]' >> /root/.cargo/config.toml && \
    echo 'inherits = "release"' >> /root/.cargo/config.toml && \
    echo 'lto = "fat"' >> /root/.cargo/config.toml && \
    echo 'codegen-units = 1' >> /root/.cargo/config.toml && \
    echo 'panic = "abort"' >> /root/.cargo/config.toml && \
    echo 'strip = true' >> /root/.cargo/config.toml && \
    echo 'opt-level = 3' >> /root/.cargo/config.toml && \
    echo 'overflow-checks = false' >> /root/.cargo/config.toml && \
    echo 'debug = false' >> /root/.cargo/config.toml && \
    echo 'debug-assertions = false' >> /root/.cargo/config.toml && \
    echo '' >> /root/.cargo/config.toml && \
    echo '[target.x86_64-unknown-linux-gnu]' >> /root/.cargo/config.toml && \
    echo 'linker = "/usr/local/bin/clang"' >> /root/.cargo/config.toml && \
    echo 'rustflags = ["-C", "link-arg=-fuse-ld=/usr/local/bin/mold", "-C", "link-arg=-Wl,--as-needed", "-C", "link-arg=-Wl,--gc-sections"]' >> /root/.cargo/config.toml

# Clone and build reth
WORKDIR /build
RUN git clone $RETH_REPO . && \
    git checkout $RETH_VERSION

# Set environment variables for optimization
# The snowstep/llvm image already has clang and LLVM tools in PATH
ENV CC=clang
ENV CXX=clang++
ENV AR=llvm-ar
ENV RANLIB=llvm-ranlib
ENV LD=/usr/local/bin/mold
ENV SCCACHE_DIR=/tmp/sccache
ENV RUSTC_WRAPPER=/usr/local/bin/sccache

# Set aggressive C/C++ flags for dependencies (will be overridden per architecture)
ENV CFLAGS_BASE="-O3 -flto=thin -fomit-frame-pointer -fno-semantic-interposition -funroll-loops -ffast-math"
ENV CXXFLAGS_BASE="-O3 -flto=thin -fomit-frame-pointer -fno-semantic-interposition -funroll-loops -ffast-math"
ENV LDFLAGS="-Wl,-O3 -Wl,--as-needed -Wl,--gc-sections -fuse-ld=/usr/local/bin/mold"

# Create build script with architecture-specific optimizations
RUN cat > /build/build.sh << 'EOF'
#!/bin/bash
set -e

# Base flags
RUSTFLAGS_BASE="-C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3"
CFLAGS_BASE="-O3 -flto=thin -fomit-frame-pointer -fno-semantic-interposition -funroll-loops -ffast-math"
CXXFLAGS_BASE="-O3 -flto=thin -fomit-frame-pointer -fno-semantic-interposition -funroll-loops -ffast-math"

# Configure CPU-specific optimizations
case "$ARCH_TARGET" in
    "zen5")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=znver5 -C llvm-args=-enable-machine-outliner -C llvm-args=-enable-gvn-hoist -C llvm-args=-enable-dfa-jump-thread"
        export CFLAGS="$CFLAGS_BASE -march=znver5"
        export CXXFLAGS="$CXXFLAGS_BASE -march=znver5"
        ;;
    "zen4")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=znver4 -C llvm-args=-enable-machine-outliner"
        export CFLAGS="$CFLAGS_BASE -march=znver4"
        export CXXFLAGS="$CXXFLAGS_BASE -march=znver4"
        ;;
    "zen3")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=znver3"
        export CFLAGS="$CFLAGS_BASE -march=znver3"
        export CXXFLAGS="$CXXFLAGS_BASE -march=znver3"
        ;;
    "zen2")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=znver2"
        export CFLAGS="$CFLAGS_BASE -march=znver2"
        export CXXFLAGS="$CXXFLAGS_BASE -march=znver2"
        ;;
    "skylake")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=skylake"
        export CFLAGS="$CFLAGS_BASE -march=skylake"
        export CXXFLAGS="$CXXFLAGS_BASE -march=skylake"
        ;;
    "cascadelake")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=cascadelake"
        export CFLAGS="$CFLAGS_BASE -march=cascadelake"
        export CXXFLAGS="$CXXFLAGS_BASE -march=cascadelake"
        ;;
    "icelake")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=icelake-server"
        export CFLAGS="$CFLAGS_BASE -march=icelake-server"
        export CXXFLAGS="$CXXFLAGS_BASE -march=icelake-server"
        ;;
    "sapphirerapids")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=sapphirerapids"
        export CFLAGS="$CFLAGS_BASE -march=sapphirerapids"
        export CXXFLAGS="$CXXFLAGS_BASE -march=sapphirerapids"
        ;;
    "emeraldrapids")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=emeraldrapids"
        export CFLAGS="$CFLAGS_BASE -march=emeraldrapids"
        export CXXFLAGS="$CXXFLAGS_BASE -march=emeraldrapids"
        ;;
    "alderlake")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=alderlake"
        export CFLAGS="$CFLAGS_BASE -march=alderlake"
        export CXXFLAGS="$CXXFLAGS_BASE -march=alderlake"
        ;;
    "raptorlake")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=raptorlake"
        export CFLAGS="$CFLAGS_BASE -march=raptorlake"
        export CXXFLAGS="$CXXFLAGS_BASE -march=raptorlake"
        ;;
    "x86-64-v3")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=x86-64-v3"
        export CFLAGS="$CFLAGS_BASE -march=x86-64-v3"
        export CXXFLAGS="$CXXFLAGS_BASE -march=x86-64-v3"
        ;;
    "x86-64-v4")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=x86-64-v4"
        export CFLAGS="$CFLAGS_BASE -march=x86-64-v4"
        export CXXFLAGS="$CXXFLAGS_BASE -march=x86-64-v4"
        ;;
    "native")
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=native"
        export CFLAGS="$CFLAGS_BASE -march=native"
        export CXXFLAGS="$CXXFLAGS_BASE -march=native"
        ;;
    *)
        export RUSTFLAGS="$RUSTFLAGS_BASE -C target-cpu=$ARCH_TARGET"
        export CFLAGS="$CFLAGS_BASE -march=$ARCH_TARGET"
        export CXXFLAGS="$CXXFLAGS_BASE -march=$ARCH_TARGET"
        ;;
esac

echo "Building with RUSTFLAGS: $RUSTFLAGS"
echo "Building with CFLAGS: $CFLAGS"

if [ "$BUILD_OP_RETH" = "true" ]; then
    echo "Building op-reth with optimism feature"
    cargo build --profile $PROFILE --locked --bin op-reth --features optimism,jemalloc,asm-keccak
else
    echo "Building standard reth"
    cargo build --profile $PROFILE --locked --bin reth --features jemalloc,asm-keccak
fi
EOF

RUN chmod +x /build/build.sh

# Run the build
RUN /build/build.sh

# Final stage - minimal runtime
FROM debian:bookworm-slim

# Install runtime dependencies including jemalloc for better memory performance
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    libjemalloc2 \
    && rm -rf /var/lib/apt/lists/*

# Copy the optimized binary (handle both reth and op-reth)
ARG BUILD_OP_RETH=false
RUN --mount=type=bind,from=builder,source=/build/target,target=/build/target \
    if [ "$BUILD_OP_RETH" = "true" ]; then \
        echo "Copying op-reth binary" && \
        cp /build/target/*/op-reth /usr/local/bin/op-reth && \
        ln -s /usr/local/bin/op-reth /usr/local/bin/reth; \
    else \
        echo "Copying standard reth binary" && \
        cp /build/target/*/reth /usr/local/bin/reth; \
    fi

# Create non-root user
RUN useradd -m -u 1000 -s /bin/bash reth

# Set up data directory
RUN mkdir -p /root/.local/share/reth && \
    chown -R reth:reth /root/.local/share

# Use jemalloc for better memory performance
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
ENV MALLOC_CONF="background_thread:true,metadata_thp:auto,dirty_decay_ms:30000,muzzy_decay_ms:30000"

USER reth

EXPOSE 30303 30303/udp 9001 8545 8546

# Dynamic entrypoint based on build type
ENTRYPOINT ["/usr/local/bin/reth"]