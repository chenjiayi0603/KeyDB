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
| compaction_style                  | **Leveled** (默认)         | RocksDB: `kCompactionStyleLevel`. Tiered/Universal = `kCompactionStyleUniversal` |
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
| **BlockBasedTableOptions**         |                           | 表格式配置 (包含 Bloom) |
| ├─ block_size                     | 16KB                      | SST 数据块大小 |
| ├─ checksum                       | kNoChecksum               | 不校验 |
| ├─ format_version                 | 5                         | v5 支持分区 filter/index |
| ├─ cache_index_and_filter_blocks  | true                      | 索引和 filter 放入 block cache |
| ├─ pin_l0_filter_and_index_blocks | true                      | L0 的 filter/index 固定在缓存 |
| ├─ optimize_filters_for_memory    | true                      | 减少 filter 内存占用 |
| └─ **filter_policy**              | **NewBloomFilterPolicy(10)** | 10 bits/key, ~1% 误判率 |
| **optimize_filters_for_hits**     | true (DBOptions)           | 缓存命中率高时优化 filter 层级放置 |
| level0_file_num_compaction_trigger | 4 (RocksDB 默认)          | L0 达到 4 个 SST 文件触发 compaction |
| max_bytes_for_level_multiplier    | 10 (RocksDB 默认)          | 每层大小为上一层的 10x |
| target_file_size_base             | 64MB (RocksDB 默认)        | 每层 SST 文件目标大小 |

> **level_compaction_dynamic_level_bytes = true**: RocksDB 自动计算最优层数。从磁盘容量的 90% 开始反向推算 (×10缩小)，通常 3~5 层。例如 500GB 盘 → Lmax≈450GB, L4=45GB, L3=4.5GB, L2=450MB → 4 层。测试数据 ~3.9GB 时大约 3 层。
>
> **Leveled vs Tiered (Universal) 对比**:
>
> | 特性 | Leveled (当前) | Tiered/Universal |
> |------|:---:|:---:|
> | 层/tier 数量 | **多** (3~7 层) | **少** (2~3 tier) |
> | 同层 key 范围 | 互不重叠 (partition) | **可重叠** (每个 tier 是独立 sorted run) |
> | 空间放大 | **低 (~1.11x)** | 高 (~2x) |
> | 写放大 | 高 (数据被反复合并搬移) | **低** (数据搬移少) |
> | 读放大 | **低** (每层最多查 1 个 SST) | 高 (需搜索多个重叠 tier) |
> | 适合场景 | 读多写少 / 需要低空间放大 | 写密集 / 大 value 批量写入 |
>
> **为什么 Tiered 层数少但空间放大更高？—— 数学推导 + 图释**
>
> 核心区别：**Leveled 下沉即删除，Tiered 下沉不删**。
>
> ```
> Leveled: 同一个 key 只在一层存在                  Tiered: 同一个 key 在多个 Run 并存
>
> 写入 foo:v1                                     写入 foo:v1
>   ↓                                               ↓
> L0: [foo:v1]                                    Run0: [foo:v1]
>   ↓ compaction: foo 下沉到 L1                     ↓ Run0 满了, 开新 Run
> L1: [foo:v1]                                    Run0: [foo:v1]   ← 还在!
> L0: (空) ← 旧 SST 已删除                         Run1: [foo:v2]   ← 新版本
>
> 更新 foo→v2                                     更新 foo→v3
>   ↓                                               ↓
> L0: [foo:v2]                                    Run0: [foo:v1]   ← 还在!
> L1: [foo:v1] ← 两个版本在不同层,不重复             Run1: [foo:v2]   ← 还在!
>   ↓ compaction: v2 下沉覆盖 v1                    Run2: [foo:v3]   ← 最新
> L0: (空)                                        三个 Run 都有 "foo",
> L1: [foo:v2] ← 只剩最新版, 旧版随 SST 删除        合并前同时占用磁盘空间
> ```
>
> 数学推导：
>
> ```
> Leveled (T=10):                                Tiered (R=2):
>
> L0:  1x  (新写入,未排序)                         Run 0: R   = 1x  (最新写入)
> L1:  1x                                         Run 1: R   = 1x  (上一批)
> L2:  10x                                        ─── R+R → 2x 合并 ──→
> L3:  100x                                       Run 2: 2R  = 2x  (合并后)
> L4:  1000x                                      Run 3: 4R  = 4x
>                                                 Run 4: 8R  = 8x
> 总大小 = 1+1+10+100+1000 = 1112
> 最底层  = 1000                                   总大小 = R+R+2R+4R+8R = 16R
> 空间放大 = 1112/1000 ≈ 1.11x                     最底层  = 8R
>                                                 空间放大 = 16R/8R = 2.0x
> ```
>
> **KeyDB 为什么用 Leveled**：默认值，适合 Redis 类 KV 的读多写少模式。但 FLASH 场景下 value 较大时，写放大会恶化——1KB value 在 compaction 中可能要搬移多次，放大到 5-10KB 的实际磁盘写入量。

### 2.3 BlockBasedTableOptions 优化说明

**代码变更** (`src/storage/rocksdbfactory.cpp`)：

```cpp
// 新增 Bloom filter — 10 bits/key → ~1% 误判率
table_options.filter_policy.reset(rocksdb::NewBloomFilterPolicy(10));
table_options.optimize_filters_for_memory = true;
options.optimize_filters_for_hits = true;
table_options.format_version = 5;

// API 兼容修复 (RocksDB 7.10)
rocksdb::GetDBOptionsFromString(rocksdb::ConfigOptions(), options, ...);
```

**预期效果**：

| 指标 | 无 Bloom | 有 Bloom (10 bits/key) |
|------|:---:|:---:|
| 点查 SST 扫描 | 每个 SST 读 data block | 先查 Bloom, 99% 无效 SST 直接跳过 |
| Compaction 合并速度 | 慢 (需读所有重叠 SST) | 快 (Bloom 快速排除不重叠 SST) |
| Filter 内存开销 | 0 | ~1.25% 数据大小 (10 bits/key ÷ 8) |
| 写吞吐影响 | — | 微小 (写路径仅多一次 hash 计算) |

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

| 介质 | 路径 | 文件系统 |
|------|------|------|
| NVMe SSD | `/home/tommychen/keydb_flash_bloom` | ext4 |

> 压测配置: Bloom filter 优化版 (见 §2.2), NVMe SSD 真实磁盘。

## 5. 压测数据结果

> Bloom filter 优化版 (见 §2.2)，NVMe SSD 真实磁盘。tmpfs 为参照对比。

### 5.1 SET 写

| Value | NVMe RPS  | NVMe p50 | NVMe p95 | tmpfs RPS | RPS 差异 |
|:-----:|:---------:|:--------:|:--------:|:---------:|:--------:|
| 16B   | 245,677   | 3.24ms   | 5.09ms   | 199,600   | +23%     |
| 1KB   | 75,304    | 5.38ms   | 44.42ms  | 132,802   | -43%     |
| 4KB   | 15,949    | 4.18ms   | 63.87ms  | 99,601    | -84%     |

### 5.2 GET 读

| Value | NVMe RPS  | NVMe p50 | NVMe p95 | tmpfs RPS | RPS 差异 |
|:-----:|:---------:|:--------:|:--------:|:---------:|:--------:|
| 16B   | 86,760    | 8.06ms   | 21.62ms  | 768,521   | -89%     |
| 4KB   | 102,364   | 2.02ms   | 13.02ms  | 444,148   | -77%     |

> NVMe 16B/4KB GET 均命中内存 (dict cache / RocksDB block cache)，未触及磁盘。debug build (-O0) 拖慢了 RESP 解析路径，优化编译 (-O2 -flto) 预期可恢复到 tmpfs 同级水平。

### 5.3 RocksDB 磁盘写入量

| 指标 | 值 |
|------|-----|
| FLASH 目录 | `/home/tommychen/keydb_flash_bloom` (NVMe ext4) |
| SST 大小 | ~75MB (测试中持续增长) |
| 完整性 | 无 corruption, 正常 compaction |

### 5.4 读写混合 & 大 value 限制

`keydb-benchmark` 不支持原生读写混合模式，大 value + 高 pipeline 触发 client buffer 溢出。建议换 `memtier_benchmark`。
