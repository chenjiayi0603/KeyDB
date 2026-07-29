#!/bin/bash
# KeyDB + RocksDB FLASH 真实场景压测
# 模拟: 数据量>内存, 持续写入, 混合读写, eviction 常态化
set -e

CLI=./src/keydb-cli
BENCH=./src/keydb-benchmark
HOST="127.0.0.1"
PORT="${1:-6379}"
DUR=120  # 每阶段 2 分钟

echo "=============================================="
echo " FLASH 真实场景压测"
echo " 目标: $HOST:$PORT  |  每阶段: ${DUR}s"
echo "=============================================="

# 阶段1: 预载数据到超出 maxmemory
echo ""
echo "=== 阶段1: 预载 1GB 数据 (maxmemory=512MB, 强制触发 eviction) ==="
echo "写入 100 万个 1KB key (共 ~1GB)..."
$BENCH -h $HOST -p $PORT -t set -n 1000000 -d 1024 -P 16 -c 50 --threads 4 -r 3000000 --csv 2>/dev/null | tail -1
echo "数据量: $($CLI -h $HOST -p $PORT DBSIZE 2>/dev/null)"
echo "内存: $($CLI -h $HOST -p $PORT INFO memory 2>/dev/null | grep used_memory_human)"

# 阶段2: 持续写入 + 后台读取 (模拟生产: 写不断, 读命中 dict cache)
echo ""
echo "=== 阶段2: 持续 SET (1KB) — 模拟生产写入 ==="
$BENCH -h $HOST -p $PORT -t set -n 10000000 -d 1024 -P 16 -c 50 --threads 4 -r 5000000 --csv 2>/dev/null > /tmp/bench_real_set.csv &
SET_PID=$!
sleep $DUR
kill $SET_PID 2>/dev/null; wait $SET_PID 2>/dev/null
echo "SET 结果:"
tail -1 /tmp/bench_real_set.csv

# 阶段3: 混合读写 (80% 读热数据 + 20% 写新数据)
echo ""
echo "=== 阶段3: 混合读写 — 80% GET 热数据 + 20% SET 新数据 ==="
# 读: 80% 命中已有数据 (key范围0~800K), 20% 命中新写入
# 写: 写入新 key (800K~1M 范围)
$BENCH -h $HOST -p $PORT -t get -n 8000000 -d 1024 -P 16 -c 40 --threads 4 -r 800000 --csv 2>/dev/null > /tmp/bench_real_get.csv &
GET_PID=$!
$BENCH -h $HOST -p $PORT -t set -n 2000000 -d 1024 -P 8 -c 10 --threads 2 -r 200000 --csv 2>/dev/null > /tmp/bench_real_mix_set.csv &
SET2_PID=$!
sleep $DUR
kill $GET_PID $SET2_PID 2>/dev/null; wait 2>/dev/null
echo "GET (80%):"
tail -1 /tmp/bench_real_get.csv
echo "SET (20%):"
tail -1 /tmp/bench_real_mix_set.csv

# 阶段4: 纯读 (数据已全部 evict 到 FLASH, 从 RocksDB 回读)
echo ""
echo "=== 阶段4: 纯读冷数据 (FLUSHALL CACHE, 强制从 RocksDB 读) ==="
$CLI -h $HOST -p $PORT FLUSHALL CACHE 2>/dev/null
echo "内存: $($CLI -h $HOST -p $PORT INFO memory 2>/dev/null | grep used_memory_human)"
$BENCH -h $HOST -p $PORT -t get -n 5000000 -d 1024 -P 8 -c 30 --threads 4 -r 1000000 --csv 2>/dev/null > /tmp/bench_real_cold.csv &
COLD_PID=$!
sleep $DUR
kill $COLD_PID 2>/dev/null; wait $COLD_PID 2>/dev/null
echo "冷数据 GET:"
tail -1 /tmp/bench_real_cold.csv

echo ""
echo "=============================================="
echo " 真实场景压测完成"
echo "=============================================="
echo ""
echo "| 场景 | RPS | p50 | p95 |"
echo "|------|:---:|:---:|:---:|"
for f in /tmp/bench_real_set.csv /tmp/bench_real_get.csv /tmp/bench_real_mix_set.csv /tmp/bench_real_cold.csv; do
  label=$(basename $f .csv | sed 's/bench_real_//')
  awk -F',' -v l="$label" '{printf "| %s | %s | %s | %s |\n", l, $2, $5, $6}' "$f" | tail -1
done
