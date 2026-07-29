# KeyDB + RocksDB FLASH 测试报告

> 测试日期: 2026-07-29 | KeyDB: commit 603ebb27 | 功能测试: 41套件/1177用例/0失败

---

## 1. 硬件配置

| 项目             | 配置 |
|------------------|------|
| CPU              | Intel i9-12900H, 14C/20T (6P+8E), 2.5GHz |
| L1/L2/L3         | 544KB / 11.5MB / 24MB |
| 内存             | 32GB (可用 ~15GB), Swap = 0 |
| 系统盘           | NVMe nvme1n1, 476GB, ext4 |
| FLASH 压测目录   | `/home/tommychen/keydb_flash_test` (nvme1n1 ext4) |

## 2. 软件配置

| 项目             | 版本/配置 |
|------------------|-----------|
| OS               | Ubuntu 26.04 LTS, kernel 7.0.0-27-generic, x86_64 |

### 2.1 KeyDB 关键配置

| 参数                    | 值                         | 说明 |
|-------------------------|---------------------------|------|
| server-threads          | 2 (默认)                   | 工作线程数, 每个线程独立 event loop |
| maxmemory               | 512MB                      | 内存上限, 触达后 evict 到 RocksDB |
| maxmemory-policy        | allkeys-lru                | 淘汰策略 |
| storage-provider        | flash                      | 存储后端 = RocksDB |
| client-query-buffer-limit | 1GB                      | 客户端查询缓冲区上限 |
| save / appendonly       | 关闭                       | 无 RDB/AOF 持久化 |

### 2.2 RocksDB 关键配置

| 参数                              | 值                       | 说明 |
|-----------------------------------|-------------------------|------|
| 版本                              | 7.10.2                   | 静态链接 `librocksdb.a` |
| compaction_style                  | **Leveled** (默认)        | 压实算法: 分层合并 |
| level_compaction_dynamic_level_bytes | true                   | 动态层级大小 |
| max_background_compactions        | 4                        | 后台压实线程数 |
| max_background_flushes            | 2                        | 后台刷盘线程数 |
| compression                       | **kNoCompression**        | 不压缩 |
| enable_pipelined_write            | true                     | 流水线写入 |
| allow_mmap_reads                  | true                     | mmap 读取 |
| bytes_per_sync                    | 1MB                      | 每 1MB 主动 sync |
| compaction_pri                    | kMinOverlappingRatio     | 压实优先级策略 |
| block_size                        | 16KB                     | SST 数据块大小 |
| data_block_index_type             | kDataBlockBinaryAndHash   | 块内索引类型 |
| checksum                          | kNoChecksum              | 不校验 |
| table format_version              | 4                        | SST 表格式版本 |
| max_total_wal_size                | 1GB                      | WAL 总大小上限 |
| prefix_extractor                  | FixedPrefixTransform      | 按 hashslot 前缀提取 |

## 3. 编译方式

### 3.1 KeyDB

```bash
make ENABLE_FLASH=yes BUILD_TLS=yes MALLOC=jemalloc
```

| 编译选项 | 值 |
|----------|-----|
| C++ 标准 | `-std=c++17 -pedantic -fno-rtti` |
| 优化     | `-O2 -flto` (Link-Time Optimization) |
| 调试     | `-g -ggdb` |
| FLASH    | `-DENABLE_ROCKSDB` |
| 自旋锁   | `-DASM_SPINLOCK` (x64 汇编优化) |
| 分配器   | jemalloc (内置 `deps/jemalloc`) |
| TLS      | OpenSSL (`-DUSE_OPENSSL`) |
| LTO      | `-flto` |

### 3.2 RocksDB

| 编译选项 | 值 |
|----------|-----|
| 版本     | 7.10.2 (`deps/rocksdb`) |
| 编译     | `PORTABLE=1 USE_SSE=1 FORCE_SSE42=1 -Wno-error` |
| 压缩库   | zlib, bzip2, zstd, lz4, snappy |

## 4. 压测方式

### 4.1 启动命令

```bash
./src/keydb-server \
  --port 6379 --bind 127.0.0.1 --protected-mode no \
  --storage-provider flash /home/tommychen/keydb_flash_test \
  --maxmemory 512mb --maxmemory-policy allkeys-lru \
  --client-query-buffer-limit 1073741824 \
  --save "" --appendonly no --daemonize yes
```

### 4.2 压测工具及参数

| 项目       | 值 |
|------------|-----|
| 工具       | `./src/keydb-benchmark` (单线程) |
| 网络       | 127.0.0.1 回环 (0 延迟开销) |
| SET 写     | `-t set`, value 16B~1MB, `-P 1~16`, `-c 5~50`, `--threads 4`, `-r 50k~3M` |
| GET 读     | 先 `SET -n` 预载 → `-t get`, 相同 key 范围 |
| 输出       | `--csv`, 取末尾行 RPS / p50 / p95 |
| 单次时长   | 60s / 或指定 `-n` 请求数 |

> ⚠ 压测工具限制: `keydb-benchmark` 不支持真正的读写混合模式，单线程上限 ~200K rps，大 value + pipeline 易触发 client buffer 溢出。生产压测建议换 `memtier_benchmark`。

### 4.3 存储介质

| 轮次   | 介质       | 路径                                  | 有效性 |
|:------:|------------|---------------------------------------|:------:|
| 1      | tmpfs 内存盘 | `/tmp/keydb_bench_flash`             | ❌ 无效 (延迟 ~ns, 夸大性能) |
| 2      | **NVMe SSD** | `/home/tommychen/keydb_flash_test`   | ✅ 有效 (真实 ext4 磁盘) |

> 以下数据均为第 2 轮 (NVMe SSD) 结果。第 1 轮 tmpfs 数据仅作参照对比，不作为有效结论。

## 5. 压测数据结果

### 5.1 SET 写 — NVMe SSD

| Value    | RPS        | p50     | p95      | 瓶颈         |
|:--------:|:----------:|:-------:|:--------:|-------------|
| 16B      | 181,430    | 4.38ms  | 5.61ms   | CPU (RESP 解析) |
| 1KB      | 35,848     | 11.09ms | 38.50ms  | NVMe 写入 + compaction |
| 4KB      | 49,875     | 1.34ms  | 2.74ms   | NVMe 写入    |

### 5.2 GET 读 — NVMe SSD

| Value    | RPS        | p50     | p95      | 数据来源               |
|:--------:|:----------:|:-------:|:--------:|-----------------------|
| 16B      | 129,590    | 6.27ms  | 8.23ms   | KeyDB dict 内存缓存     |
| 4KB      | 126,774    | 1.83ms  | 2.74ms   | RocksDB block cache (内存) |

> 4KB GET 执行 `FLUSHALL CACHE` 后数据从 RocksDB block cache 命中 (未真正落到 NVMe)。dict cache 命中 vs RocksDB cache 命中吞吐接近 (~127K rps)，说明 RocksDB 内存读取开销与 dict 接近。

### 5.3 tmpfs vs NVMe — SET 写对比

| Value    | tmpfs (无效) | NVMe (有效) | 下降     |
|:--------:|:------------:|:-----------:|:--------:|
| 16B      | 199,600      | 181,430     | -9%      |
| 1KB      | 132,802      | 35,848      | **-73%** |
| 4KB      | 99,601       | ~49,875     | ~-50%    |

> tmpfs 数据仅说明: 内存盘会掩盖真实磁盘延迟，1KB 场景夸大了 **3.7 倍**。

### 5.4 读写混合

`keydb-benchmark` 不支持原生读写混合模式。以下为同时运行独立读/写进程的近似测试:

| Value | 读 RPS      | 写 RPS      | 说明 |
|:-----:|:----------:|:----------:|------|
| 16B   | 待补充      | 待补充      | — |

> 混合压测建议换 `memtier_benchmark --ratio 1:4` (读写比 1:4) 获取可靠数据。

### 5.5 RocksDB 磁盘实际写入量

| 指标         | 值 |
|-------------|-----|
| SST 文件数   | 59 |
| SST 总大小   | ~3.9 GB |
| WAL 日志     | 001502.log (~58MB) |
| 目录         | `/home/tommychen/keydb_flash_test` |
| 完整性       | 无 corruption, 正常 compaction |

### 5.6 16KB+ 大 value 限制

`keydb-benchmark` 在 `-l` (loop) 模式下, 大 value + 高 pipeline 导致 client buffer 溢出后连接断开且无法恢复。这是**压测工具限制**, 非 KeyDB/RocksDB 问题。解决方案: 降低 `-P 1 -c 5`, 或换 `memtier_benchmark`。
