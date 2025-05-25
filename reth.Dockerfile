# Multi-stage build for reth with architecture-specific optimizations
ARG LLVM_IMAGE=snowstep/llvm
ARG LLVM_VERSION=20250514100911
FROM ${LLVM_IMAGE}:${LLVM_VERSION} AS builder

# Install build dependencies and tools
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    git \
    libssl-dev \
    pkg-config \
    wget \
    ninja-build \
    ccache \
    autoconf \
    automake \
    libtool \
    && rm -rf /var/lib/apt/lists/*

# Set up clang as default C/C++ compiler
RUN update-alternatives --install /usr/bin/cc cc /usr/bin/clang 100 && \
    update-alternatives --install /usr/bin/c++ c++ /usr/bin/clang++ 100

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

# Set C/C++ flags for dependencies
ENV CFLAGS_BASE="-O3 -fomit-frame-pointer -fno-semantic-interposition -funroll-loops -ffast-math"
ENV CXXFLAGS_BASE="-O3 -fomit-frame-pointer -fno-semantic-interposition -funroll-loops -ffast-math"
ENV LDFLAGS="-Wl,-O3 -Wl,--as-needed -Wl,--gc-sections"

# Configure architecture-specific flags and build
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/build/target \
    if [ "$ARCH_TARGET" = "zen5" ]; then \
        RUSTFLAGS="-C target-cpu=znver5 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -C llvm-args=-enable-machine-outliner -C llvm-args=-enable-gvn-hoist -C llvm-args=-enable-dfa-jump-thread" \
        CFLAGS="$CFLAGS_BASE -march=znver5" \
        CXXFLAGS="$CXXFLAGS_BASE -march=znver5"; \
    elif [ "$ARCH_TARGET" = "9950x" ] || [ "$ARCH_TARGET" = "zen5-9950x" ]; then \
        RUSTFLAGS="-C target-cpu=znver5 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -C llvm-args=-enable-machine-outliner -C llvm-args=-enable-gvn-hoist -C llvm-args=-enable-dfa-jump-thread -C llvm-args=-slp-vectorize-hor-store" \
        CFLAGS="$CFLAGS_BASE -march=znver5 -mtune=znver5 --param l1-cache-line-size=64 --param l1-cache-size=48 --param l2-cache-size=2048 --param l3-cache-size=65536" \
        CXXFLAGS="$CXXFLAGS_BASE -march=znver5 -mtune=znver5 --param l1-cache-line-size=64 --param l1-cache-size=48 --param l2-cache-size=2048 --param l3-cache-size=65536"; \
    elif [ "$ARCH_TARGET" = "epyc-4564p" ] || [ "$ARCH_TARGET" = "zen4c-4564p" ]; then \
        RUSTFLAGS="-C target-cpu=znver4 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -C llvm-args=-enable-machine-outliner -C llvm-args=-enable-gvn-hoist -C llvm-args=-enable-dfa-jump-thread -C llvm-args=-slp-vectorize-hor-store -C llvm-args=-data-sections -C llvm-args=-function-sections" \
        CFLAGS="$CFLAGS_BASE -march=znver4 -mtune=znver4 --param l1-cache-line-size=64 --param l1-cache-size=32 --param l2-cache-size=1024 --param l3-cache-size=65536" \
        CXXFLAGS="$CXXFLAGS_BASE -march=znver4 -mtune=znver4 --param l1-cache-line-size=64 --param l1-cache-size=32 --param l2-cache-size=1024 --param l3-cache-size=65536"; \
    elif [ "$ARCH_TARGET" = "zen4" ]; then \
        RUSTFLAGS="-C target-cpu=znver4 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -C llvm-args=-enable-machine-outliner" \
        CFLAGS="$CFLAGS_BASE -march=znver4" \
        CXXFLAGS="$CXXFLAGS_BASE -march=znver4"; \
    elif [ "$ARCH_TARGET" = "7950x3d" ] || [ "$ARCH_TARGET" = "zen4-x3d" ]; then \
        RUSTFLAGS="-C target-cpu=znver4 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -C llvm-args=-enable-machine-outliner -C llvm-args=-slp-vectorize-hor-store -C llvm-args=-data-sections -C llvm-args=-function-sections" \
        CFLAGS="$CFLAGS_BASE -march=znver4 -mtune=znver4 --param l1-cache-line-size=64 --param l1-cache-size=32 --param l2-cache-size=1024 --param l3-cache-size=98304" \
        CXXFLAGS="$CXXFLAGS_BASE -march=znver4 -mtune=znver4 --param l1-cache-line-size=64 --param l1-cache-size=32 --param l2-cache-size=1024 --param l3-cache-size=98304"; \
    elif [ "$ARCH_TARGET" = "zen3" ]; then \
        RUSTFLAGS="-C target-cpu=znver3 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=znver3" \
        CXXFLAGS="$CXXFLAGS_BASE -march=znver3"; \
    elif [ "$ARCH_TARGET" = "zen2" ]; then \
        RUSTFLAGS="-C target-cpu=znver2 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=znver2" \
        CXXFLAGS="$CXXFLAGS_BASE -march=znver2"; \
    elif [ "$ARCH_TARGET" = "skylake" ]; then \
        RUSTFLAGS="-C target-cpu=skylake -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=skylake" \
        CXXFLAGS="$CXXFLAGS_BASE -march=skylake"; \
    elif [ "$ARCH_TARGET" = "cascadelake" ]; then \
        RUSTFLAGS="-C target-cpu=cascadelake -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=cascadelake" \
        CXXFLAGS="$CXXFLAGS_BASE -march=cascadelake"; \
    elif [ "$ARCH_TARGET" = "icelake" ]; then \
        RUSTFLAGS="-C target-cpu=icelake-server -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=icelake-server" \
        CXXFLAGS="$CXXFLAGS_BASE -march=icelake-server"; \
    elif [ "$ARCH_TARGET" = "sapphirerapids" ]; then \
        RUSTFLAGS="-C target-cpu=sapphirerapids -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=sapphirerapids" \
        CXXFLAGS="$CXXFLAGS_BASE -march=sapphirerapids"; \
    elif [ "$ARCH_TARGET" = "emeraldrapids" ]; then \
        RUSTFLAGS="-C target-cpu=emeraldrapids -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=emeraldrapids" \
        CXXFLAGS="$CXXFLAGS_BASE -march=emeraldrapids"; \
    elif [ "$ARCH_TARGET" = "alderlake" ]; then \
        RUSTFLAGS="-C target-cpu=alderlake -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=alderlake" \
        CXXFLAGS="$CXXFLAGS_BASE -march=alderlake"; \
    elif [ "$ARCH_TARGET" = "raptorlake" ]; then \
        RUSTFLAGS="-C target-cpu=raptorlake -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=raptorlake" \
        CXXFLAGS="$CXXFLAGS_BASE -march=raptorlake"; \
    elif [ "$ARCH_TARGET" = "x86-64-v3" ]; then \
        RUSTFLAGS="-C target-cpu=x86-64-v3 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=x86-64-v3" \
        CXXFLAGS="$CXXFLAGS_BASE -march=x86-64-v3"; \
    elif [ "$ARCH_TARGET" = "x86-64-v4" ]; then \
        RUSTFLAGS="-C target-cpu=x86-64-v4 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=x86-64-v4" \
        CXXFLAGS="$CXXFLAGS_BASE -march=x86-64-v4"; \
    elif [ "$ARCH_TARGET" = "native" ]; then \
        RUSTFLAGS="-C target-cpu=native -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=native" \
        CXXFLAGS="$CXXFLAGS_BASE -march=native"; \
    elif [ "$ARCH_TARGET" = "multinode-zen4" ] || [ "$ARCH_TARGET" = "multinode-7950x" ]; then \
        # Optimized for multiple nodes on same machine - reduced cache assumptions
        RUSTFLAGS="-C target-cpu=znver4 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -C llvm-args=-enable-machine-outliner" \
        CFLAGS="$CFLAGS_BASE -march=znver4 -mtune=znver4 --param l1-cache-line-size=64 --param l1-cache-size=32 --param l2-cache-size=512" \
        CXXFLAGS="$CXXFLAGS_BASE -march=znver4 -mtune=znver4 --param l1-cache-line-size=64 --param l1-cache-size=32 --param l2-cache-size=512"; \
    elif [ "$ARCH_TARGET" = "multinode-zen5" ] || [ "$ARCH_TARGET" = "multinode-9950x" ]; then \
        # Optimized for multiple nodes on same machine - reduced cache assumptions
        RUSTFLAGS="-C target-cpu=znver5 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3 -C llvm-args=-enable-machine-outliner" \
        CFLAGS="$CFLAGS_BASE -march=znver5 -mtune=znver5 --param l1-cache-line-size=64 --param l1-cache-size=48 --param l2-cache-size=512" \
        CXXFLAGS="$CXXFLAGS_BASE -march=znver5 -mtune=znver5 --param l1-cache-line-size=64 --param l1-cache-size=48 --param l2-cache-size=512"; \
    elif [ "$ARCH_TARGET" = "multinode-epyc" ]; then \
        # Optimized for multiple nodes on EPYC systems - assume shared resources
        RUSTFLAGS="-C target-cpu=znver4 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=znver4 -mtune=znver4 --param l1-cache-line-size=64 --param l1-cache-size=32 --param l2-cache-size=256" \
        CXXFLAGS="$CXXFLAGS_BASE -march=znver4 -mtune=znver4 --param l1-cache-line-size=64 --param l1-cache-size=32 --param l2-cache-size=256"; \
    elif [ "$ARCH_TARGET" = "multinode-generic" ]; then \
        # Generic multinode optimization - conservative cache assumptions
        RUSTFLAGS="-C target-cpu=x86-64-v3 -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=x86-64-v3 --param l1-cache-line-size=64 --param l1-cache-size=32 --param l2-cache-size=256" \
        CXXFLAGS="$CXXFLAGS_BASE -march=x86-64-v3 --param l1-cache-line-size=64 --param l1-cache-size=32 --param l2-cache-size=256"; \
    else \
        RUSTFLAGS="-C target-cpu=$ARCH_TARGET -C link-arg=-fuse-ld=/usr/local/bin/mold -C opt-level=3" \
        CFLAGS="$CFLAGS_BASE -march=$ARCH_TARGET" \
        CXXFLAGS="$CXXFLAGS_BASE -march=$ARCH_TARGET"; \
    fi && \
    export RUSTFLAGS CFLAGS CXXFLAGS && \
    echo "Building with RUSTFLAGS: $RUSTFLAGS" && \
    if [ "$BUILD_OP_RETH" = "true" ]; then \
        echo "Building op-reth with optimism feature" && \
        cargo build --profile $PROFILE --locked --bin op-reth --features jemalloc,asm-keccak --manifest-path crates/optimism/bin/Cargo.toml && \
        cp target/$PROFILE/op-reth /usr/local/bin/op-reth; \
    else \
        echo "Building standard reth" && \
        cargo build --profile $PROFILE --locked --bin reth --features jemalloc,asm-keccak && \
        cp target/$PROFILE/reth /usr/local/bin/reth; \
    fi

# Final stage - minimal runtime
FROM debian:trixie-slim

# Install runtime dependencies including jemalloc for better memory performance
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    libjemalloc2 \
    && rm -rf /var/lib/apt/lists/*

# Copy the optimized binary (only one will exist)
# Use wildcards to avoid errors when copying non-existent files
COPY --from=builder /usr/local/bin/reth* /usr/local/bin/
COPY --from=builder /usr/local/bin/op-reth* /usr/local/bin/

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