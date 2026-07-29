FROM ubuntu:resolute

# Install runtime dependencies for KeyDB + RocksDB FLASH
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4 \
    libuuid1 \
    libbz2-1.0 \
    liblz4-1 \
    libsnappy1v5 \
    libzstd1 \
    libssl3 \
    libgflags2.2 \
    libatomic1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy stripped binaries
COPY src/keydb-server /usr/local/bin/keydb-server
COPY src/keydb-cli /usr/local/bin/keydb-cli
COPY src/keydb-benchmark /usr/local/bin/keydb-benchmark
COPY src/keydb-sentinel /usr/local/bin/keydb-sentinel
COPY src/keydb-check-rdb /usr/local/bin/keydb-check-rdb
COPY src/keydb-check-aof /usr/local/bin/keydb-check-aof

RUN mkdir -p /data /etc/keydb
VOLUME /data
EXPOSE 6379

ENTRYPOINT ["keydb-server"]
CMD ["/etc/keydb/keydb.conf"]
