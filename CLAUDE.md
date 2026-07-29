# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build / Test / Run Commands

```bash
# Build (default: TLS enabled, jemalloc on Linux, C++17, link-time optimization)
make

# Build with systemd support
make USE_SYSTEMD=yes

# Build without TLS
make BUILD_TLS=no

# Build with FLASH storage support (experimental)
make ENABLE_FLASH=yes

# Build with specific allocator
make MALLOC=libc       # force libc malloc
make MALLOC=jemalloc   # force jemalloc
make MALLOC=tcmalloc   # use tcmalloc

# Clean build (run after changing deps or build flags)
make distclean

# Build with sanitizers
make SANITIZE=address   # or =thread, =leak, =undefined

# Debug build
make noopt       # -O0
make valgrind    # -O0 + libc malloc + no asm spinlocks

# Run the server
./src/keydb-server [config-file]
# With config overrides:
./src/keydb-server --port 9999 --replicaof 127.0.0.1 6379

# CLI
./src/keydb-cli

# Install to /usr/local/bin
make install
make PREFIX=/some/other/directory install
```

### Running Tests

Tests are written in TCL and require `tcl 8.5+` and `tcl-tls` (for TLS tests).

```bash
# Generate TLS test certificates (needed for TLS tests)
./utils/gen-test-certs.sh

# Run all unit + integration tests (single-threaded server)
./runtest

# Run with TLS
./runtest --tls

# Run specific test file:
./runtest --single unit/type/string

# Run tests with multiple server threads
./runtest --config server-threads 3

# Cluster tests
./runtest-cluster [--tls]

# Sentinel tests
./runtest-sentinel

# Module API tests
./runtest-moduleapi

# Rotation tests (TLS certificate rotation)
./runtest-rotation

# Run with verbose output and multiple clients (matching CI)
./runtest --clients 4 --verbose --tls
```

## Code Architecture

### Multithreading Model

KeyDB runs multiple instances of the Redis event loop, each on its own thread. This is the core architectural difference from upstream Redis.

- **`MAX_EVENT_LOOPS`** = 16 (max threads). Configured via `server-threads N` in keydb.conf (default: 2, recommended: 4).
- **Thread 0 (`IDX_EVENT_LOOP_MAIN`)** runs `serverCron` (expiration, replication, AOF, rehashing, defrag, stats). This thread is the only one that performs periodic maintenance.
- **Other threads** (1..N-1) run `serverCronLite`, a lightweight cron that only handles blocked client unblocking.
- **Connection distribution**: SO_REUSEPORT distributes new connections to threads. `active-client-balancing` (default on) further balances clients across threads.
- Thread affinity (`server-thread-affinity`) pins threads to specific cores starting at `threadAffinityOffset`.

### Locking Hierarchy

- **`fastlock`** — custom ticket-based spinlock with futex fallback. Used as the main server lock (the "ae lock"). Protects access to the core data structures (hashtable/dict, key space). Contention is low because hash table operations are extremely fast.
- **`aeAcquireLock()` / `aeReleaseLock()`** — acquire/release the global server spinlock. Must be held when accessing shared mutable state like the key-value dictionary.
- **`aeThreadOnline()` / `aeThreadOffline()`** — marks a thread as holding the lock for MVCC epoch tracking.
- **`AeLocker`** — RAII wrapper for the ae lock (in `aelocker.h`). Use with `arm()`/`disarm()` or scoped construction.
- **Module GIL** (`moduleAcquireGIL`/`moduleReleaseGIL`) — acquired by all server threads before sleep, released after wake. Ensures module threads see a consistent state.
- **Client-level locks** — each client has its own `fastlock`, allowing fine-grained client state protection.

### Key Global Variables

- **`g_pserver`** (`redisServer*`) — the global mutable server state.
- **`cserver`** (`redisServerConst`) — server configuration constants set before thread launch (never mutated after worker threads start).
- **`serverTL`** (`thread_local redisServerThreadVars*`) — per-thread server state, safe to access without the global lock.

### MVCC / Snapshot Architecture

KeyDB uses an epoch-based MVCC approach for non-blocking operations like `KEYS` and `SCAN`:

- **`redisDbPersistentDataSnapshot`** — a snapshot of a database's primary dict at a point in time. Created via `redisDbPersistentData::createSnapshot()`.
- **`GarbageCollectorCollection`** / **`GarbageCollector<T>`** (in `gc.h`) — epoch-based garbage collection. Objects freed when no thread's epoch references them. Each thread holds a `gcEpoch` in its `redisServerThreadVars`.
- **`SnapshotPayloadParseState`** — parses snapshot payloads for CRON-like operations on snapshots.
- The snapshot is used by `keysCommand`, `scanCommand`, and the `RREPLAY` active-replication protocol to iterate without holding the lock.

### Core Data Structures

- **`dict`** (in `dict.h`/`dict.cpp`) — the core hash table used for the main keyspace and many internal structures. Supports incremental rehashing.
- **`sds`** (Simple Dynamic Strings, in `sds.h`/`sds.c`) — length-prefixed C strings used everywhere.
- **`robj`** (`redisObject`) — wrappers for keys and values with reference counting, encoding, and LRU metadata.
- **`quicklist`**, **`ziplist`**, **`listpack`**, **`intset`**, **`rax`** — specialized data structures for different value types.

### Important Source Files

| File | Purpose |
|------|---------|
| `server.h` | Central header — structs (`redisServer`, `redisServerThreadVars`, `redisServerConst`, `redisDb`), macros, globals |
| `server.cpp` | Main server init, cron, `main()`, thread management, command dispatch |
| `networking.cpp` | Client connection handling, `createClient()`, query parsing, reply writing |
| `db.cpp` | Core key-value operations: lookup, set, delete, expire, `KEYS`, `SCAN` |
| `dict.cpp` | Hash table implementation with incremental rehash |
| `replication.cpp` | Master-replica replication, `RREPLAY` protocol for active replication |
| `cluster.cpp` | Redis cluster protocol (slot-based sharding) |
| `aof.cpp` | Append-Only File persistence |
| `rdb.cpp` | RDB snapshot save/load |
| `snapshot.cpp` | MVCC snapshot creation and consolidation |
| `fastlock.cpp` / `fastlock_x64.asm` | Spinlock implementation (C + x64 assembly optimization) |
| `ae.cpp` / `ae_epoll.cpp` | Event loop library (epoll backend on Linux) |
| `module.cpp` | Redis Module API |
| `scripting.cpp` | Lua scripting (EVAL/EVALSHA) |
| `storage.cpp` / `StorageCache.cpp` / `IStorage.h` | FLASH storage provider interface and cache |
| `defrag.cpp` | Active memory defragmentation |
| `expire.cpp` | Key expiration (active + passive) |
| `evict.cpp` | Max-memory eviction |
| `config.cpp` | Configuration file parsing |
| `acl.cpp` | Access Control Lists |
| `tls.cpp` | TLS/SSL support |
| `multi.cpp` | MULTI/EXEC transaction support |
| `pubsub.cpp` | Pub/Sub channels and patterns |
| `blocked.cpp` | Blocking operations (BLPOP, etc.) |
| `tracking.cpp` | Client-side caching invalidation |
| `lazyfree.cpp` | Asynchronous key deletion |
| `t_hash.cpp`, `t_list.cpp`, `t_set.cpp`, `t_zset.cpp`, `t_string.cpp`, `t_stream.cpp`, `t_nhash.cpp` | Type-specific command implementations |
| `keydb-diagnostic-tool.cpp` | Standalone diagnostic binary |

### Binary Targets

- **`keydb-server`** — the main server binary. Also installed as `keydb-sentinel` and `keydb-check-rdb`/`keydb-check-aof` (hard links/copies).
- **`keydb-cli`** — command-line client.
- **`keydb-benchmark`** — benchmarking tool (single-threaded; use `memtier` for accurate benchmarking).
- **`keydb-diagnostic-tool`** — diagnostics utility.

### Configuration

- `keydb.conf` — self-documented configuration file in the repo root.
- KeyDB-specific configs: `server-threads`, `server-thread-affinity`, `min-clients-per-thread`, `replica-weighting-factor`, `active-client-balancing`, `active-replica`, `multi-master-no-forward`, `db-s3-object`, `storage-provider`.
- Build-time settings are cached in `.make-settings` and `.make-prerequisites`.

### Dependencies

All dependencies are in `deps/` and built alongside KeyDB:
- **linenoise** — CLI line editing
- **lua** — scripting engine
- **hiredis** — C Redis client library
- **jemalloc** — memory allocator (default on Linux x86_64)
- **concurrentqueue** (Moody Camel) — lock-free concurrent queue for async work
- **hdr_histogram** — high-dynamic-range histogram for benchmark
- **rocksdb** — FLASH storage backend (only when `ENABLE_FLASH=yes`)

Use `USE_SYSTEM_*` flags to link against system-provided versions: `USE_SYSTEM_JEMALLOC=yes`, `USE_SYSTEM_HIREDIS=yes`, `USE_SYSTEM_ROCKSDB=yes`, `USE_SYSTEM_CONCURRENTQUEUE=yes`.

### Code Style Notes

- The codebase is a mix of C and C++17. Core data structures (dict, sds, ziplist) are C; newer code is C++.
- C++ features used: templates, `std::function`, `std::unique_ptr`, `std::vector`, lambdas, RAII, `std::atomic`.
- RTTI is disabled (`-fno-rtti`).
- C files compile with `-std=c11` (or `-std=c99` if C11 atomic not available).
- C++ files compile with `-std=c++17 -pedantic`.
- The `server.h` header includes everything — it's the single include for most source files.
- `extern "C"` blocks wrap C APIs exposed to C++ code.
- Memory allocation uses the `zmalloc` wrapper (supports jemalloc/tcmalloc/libc, tracks memory usage).
