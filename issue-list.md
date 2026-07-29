# Keydb 全量测试 & 代码检查 — 问题清单

> 状态说明: 🔴 阻塞 / 🟠 待处理(高) / 🟡 待处理(中) / 🔵 优化建议 / ⚪ 记录(信息) / ✅ 已修复

---

## 🟡 优化 KeyDB + RocksDB FLASH 写入性能

**背景**: 基准测试 (`docs/TEST_RESULTS.md §5`) 显示 NVMe SSD 上 SET 1KB 吞吐 ~75K rps (p95=44ms), 4KB 降到 ~16K rps (p95=64ms)。Bloom filter 已启用，吞吐相较优化前已翻倍，仍有提升空间。

**当前配置**: `src/storage/rocksdbfactory.cpp` — Leveled compaction, kNoCompression, max_background_compactions=4

**优化项** (按优先级):

1. 🟠 **启用压缩** — `kNoCompression` → `kLZ4Compression`
   - 预期: SST 大小减半, compaction I/O 减半, 1KB SET 吞吐再提 30-50%

2. 🟠 **恢复 -O2 -flto 编译** — 当前 debug build (-O0) 拖慢 CPU 路径
   - 修复 `.make-settings` 的 LTO 循环重建问题
   - 预期: RESP 解析 + dict 操作提速 20-40%

3. 🟡 **增加 compaction 并行度** — `max_background_compactions: 4 → 8`
   - 预期: write stall 进一步减少

4. 🟡 **考虑 Universal Compaction** — 写放大从 ~10x 降到 ~2x
   - 适合 FLASH 的写入密集场景, 需评估读放大增加的影响

5. 🔵 **增大 block cache** — 当前默认 8MB → 256MB
   - 预期: 更多热数据缓存在 RocksDB 内存, 减少磁盘读取

6. 🔵 **增大 maxmemory** — 512MB → 2~4GB
   - 预期: KeyDB dict cache 命中率提升, 减少 RocksDB 读取

**参考**: `docs/TEST_RESULTS.md §6`