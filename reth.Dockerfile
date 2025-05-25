# Multi-stage build for reth with architecture-specific optimizations
ARG LLVM_IMAGE=snowstep/llvm
ARG LLVM_VERSION=20250514100911
FROM ${LLVM_IMAGE}:${LLVM_VERSION} as builder

# Install Rust and nightly toolchain for advanced optimizations
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustup toolchain install nightly && \
    rustup component add rust-src --toolchain nightly

# Install additional build dependencies
RUN apt-get update && apt-get install -y \
    git \
    libssl-dev \
    pkg-config \
    wget \
    ninja-build \
    ccache \
    && rm -rf /var/lib/apt/lists/*

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

# Configure CPU-specific optimizations with enhanced flags
# Map common architecture names to LLVM target-cpu values
RUN if [ "$ARCH_TARGET" = "zen5" ]; then \
        export RUSTFLAGS="-C target-cpu=znver5 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=znver5 -C llvm-args=-enable-machine-outliner -C llvm-args=-enable-gvn-hoist -C llvm-args=-enable-dfa-jump-thread"; \
        export CFLAGS="$CFLAGS_BASE -march=znver5"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=znver5"; \
    elif [ "$ARCH_TARGET" = "zen4" ]; then \
        export RUSTFLAGS="-C target-cpu=znver4 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=znver4 -C llvm-args=-enable-machine-outliner"; \
        export CFLAGS="$CFLAGS_BASE -march=znver4"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=znver4"; \
    elif [ "$ARCH_TARGET" = "zen3" ]; then \
        export RUSTFLAGS="-C target-cpu=znver3 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=znver3"; \
        export CFLAGS="$CFLAGS_BASE -march=znver3"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=znver3"; \
    elif [ "$ARCH_TARGET" = "zen2" ]; then \
        export RUSTFLAGS="-C target-cpu=znver2 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=znver2"; \
        export CFLAGS="$CFLAGS_BASE -march=znver2"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=znver2"; \
    elif [ "$ARCH_TARGET" = "skylake" ]; then \
        export RUSTFLAGS="-C target-cpu=skylake -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=skylake"; \
        export CFLAGS="$CFLAGS_BASE -march=skylake"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=skylake"; \
    elif [ "$ARCH_TARGET" = "cascadelake" ]; then \
        export RUSTFLAGS="-C target-cpu=cascadelake -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=cascadelake"; \
        export CFLAGS="$CFLAGS_BASE -march=cascadelake"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=cascadelake"; \
    elif [ "$ARCH_TARGET" = "icelake" ]; then \
        export RUSTFLAGS="-C target-cpu=icelake-server -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=icelake-server"; \
        export CFLAGS="$CFLAGS_BASE -march=icelake-server"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=icelake-server"; \
    elif [ "$ARCH_TARGET" = "sapphirerapids" ]; then \
        export RUSTFLAGS="-C target-cpu=sapphirerapids -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=sapphirerapids"; \
        export CFLAGS="$CFLAGS_BASE -march=sapphirerapids"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=sapphirerapids"; \
    elif [ "$ARCH_TARGET" = "emeraldrapids" ]; then \
        export RUSTFLAGS="-C target-cpu=emeraldrapids -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=emeraldrapids"; \
        export CFLAGS="$CFLAGS_BASE -march=emeraldrapids"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=emeraldrapids"; \
    elif [ "$ARCH_TARGET" = "alderlake" ]; then \
        export RUSTFLAGS="-C target-cpu=alderlake -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=alderlake"; \
        export CFLAGS="$CFLAGS_BASE -march=alderlake"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=alderlake"; \
    elif [ "$ARCH_TARGET" = "raptorlake" ]; then \
        export RUSTFLAGS="-C target-cpu=raptorlake -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -Z tune-cpu=raptorlake"; \
        export CFLAGS="$CFLAGS_BASE -march=raptorlake"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=raptorlake"; \
    elif [ "$ARCH_TARGET" = "x86-64-v3" ]; then \
        export RUSTFLAGS="-C target-cpu=x86-64-v3 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3"; \
        export CFLAGS="$CFLAGS_BASE -march=x86-64-v3"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=x86-64-v3"; \
    elif [ "$ARCH_TARGET" = "x86-64-v4" ]; then \
        export RUSTFLAGS="-C target-cpu=x86-64-v4 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3"; \
        export CFLAGS="$CFLAGS_BASE -march=x86-64-v4"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=x86-64-v4"; \
    elif [ "$ARCH_TARGET" = "native" ]; then \
        export RUSTFLAGS="-C target-cpu=native -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3"; \
        export CFLAGS="$CFLAGS_BASE -march=native"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=native"; \
    else \
        export RUSTFLAGS="-C target-cpu=$ARCH_TARGET -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3"; \
        export CFLAGS="$CFLAGS_BASE -march=$ARCH_TARGET"; \
        export CXXFLAGS="$CXXFLAGS_BASE -march=$ARCH_TARGET"; \
    fi && \
    echo "Building with RUSTFLAGS: $RUSTFLAGS" && \
    if [ "$BUILD_OP_RETH" = "true" ]; then \
        echo "Building op-reth with optimism feature" && \
        cargo +nightly build --profile $PROFILE --locked --bin op-reth --features optimism,jemalloc,asm-keccak -Z build-std=std,panic_abort -Z build-std-features=panic_immediate_abort; \
    else \
        echo "Building standard reth" && \
        cargo +nightly build --profile $PROFILE --locked --bin reth --features jemalloc,asm-keccak -Z build-std=std,panic_abort -Z build-std-features=panic_immediate_abort; \
    fi

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