#!/bin/bash
# KeyDB + RocksDB FLASH 性能压测
# 小→大数据包, 读/写/混合, 每项3分钟
# keydb-benchmark 不支持 -l 时长参数, 用 timeout 控制

# timeout 返回非零, 不要中途退出
# set -e

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6379}"
CLI="${KEYDB_CLI:-./src/keydb-cli} -h $HOST -p $PORT"
BENCH="${KEYDB_BENCH:-./src/keydb-benchmark} -h $HOST -p $PORT"
OUTDIR="${OUTDIR:-/tmp/bench_results}"
DURATION="${DURATION:-180}"   # seconds per test

mkdir -p "$OUTDIR"
echo "=============================================="
echo " KeyDB+FLASH 性能压测"
echo " 目标: $HOST:$PORT  |  每项: ${DURATION}s"
echo "=============================================="

# 运行压测: 后台启动 → sleep DURATION → kill → 取最后一行 CSV
run_bench() {
    local label="$1"; shift
    local outfile="$OUTDIR/${label}.csv"
    echo ""
    echo "--- [$label] $(date '+%H:%M:%S') ---"

    # 后台运行, 输出直接写文件 (不用 pipe/timeout, 避免 buffers 截断)
    $BENCH "$@" --csv -l > "$outfile" 2>/dev/null &
    local pid=$!
    sleep ${DURATION}
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null

    # CSV格式: "test","rps",...  跳过表头, 取最后一行的rps
    local last=$(grep -v '"test"' "$outfile" | tail -1 | awk -F',' '{gsub(/"/,"",$2); print $2}')
    local lines=$(grep -cv '"test"' "$outfile")
    echo "  采样点: $lines,  最后RPS: ${last:-N/A}"
    echo "${last:-0}" > "$OUTDIR/${label}.rps"
}

echo ""
echo "========== 1. SET 写压测 =========="

for SIZE in 16 128 1024 4096 16384 65536 262144 1048576; do
    LABEL=$SIZE
    if [ $SIZE -lt 1024 ]; then LABEL="${SIZE}B"
    elif [ $SIZE -lt 1048576 ]; then LABEL="$((SIZE/1024))KB"
    else LABEL="$((SIZE/1048576))MB"; fi

    PIPE=16; CLIENTS=50
    [ $SIZE -ge 65536 ] && PIPE=4
    [ $SIZE -ge 262144 ] && PIPE=2
    [ $SIZE -ge 1048576 ] && PIPE=1 && CLIENTS=10

    run_bench "SET_${LABEL}" \
        -t set -d $SIZE -P $PIPE -c $CLIENTS --threads 4 \
        -r 3000000 -l
done

echo ""
echo "========== 2. GET 读压测 =========="

# 预载数据
preload() { local size=$1 keys=$2
    [ $size -lt 1024 ] && sl="${size}B" || sl="$((size/1024))KB"
    echo "[预载] ${keys} 个 ${sl} keys..."
    $BENCH -t set -n $keys -d $size -P 16 -c 50 --threads 4 -r $((keys*2)) --csv 2>/dev/null | tail -1
}

preload 16    2000000
preload 128   1000000
preload 1024   500000
preload 4096   200000
preload 16384  100000
preload 65536   50000

for SIZE in 16 128 1024 4096 16384 65536; do
    LABEL=$SIZE; KEYS=500000
    if [ $SIZE -lt 1024 ]; then LABEL="${SIZE}B"; KEYS=2000000
    else LABEL="$((SIZE/1024))KB"; fi
    [ $SIZE -eq 65536 ] && KEYS=50000

    PIPE=16; CLIENTS=50
    [ $SIZE -ge 4096 ] && PIPE=8

    run_bench "GET_${LABEL}" \
        -t get -d $SIZE -P $PIPE -c $CLIENTS --threads 4 \
        -r $KEYS -l
done

echo ""
echo "========== 3. 混合读写 (GET 占多) =========="

for SIZE in 16 1024 4096 65536; do
    LABEL=$SIZE; KEYS=500000
    if [ $SIZE -lt 1024 ]; then LABEL="${SIZE}B"; KEYS=2000000
    else LABEL="$((SIZE/1024))KB"; fi
    [ $SIZE -eq 65536 ] && KEYS=50000

    PIPE=16; CLIENTS=40
    [ $SIZE -ge 65536 ] && PIPE=4

    run_bench "MIX_READ_${LABEL}" \
        -t get -d $SIZE -P $PIPE -c $CLIENTS --threads 4 \
        -r $KEYS -l
    run_bench "MIX_WRITE_${LABEL}" \
        -t set -d $SIZE -P 4 -c 10 --threads 2 \
        -r $KEYS -l
done

echo ""
echo "========== 4. Pipeline 批量写 (1KB value) =========="

for PL in 1 4 16 64 128; do
    run_bench "PIPE_${PL}" \
        -t set -d 1024 -P $PL -c 50 --threads 4 \
        -r 2000000 -l
done

echo ""
echo "========== 5. 持续大VALUE写入 (RocksDB compaction 观测) =========="

run_bench "BULK_1MB" \
    -t set -d 1048576 -P 1 -c 5 --threads 4 \
    -r 500000 -l

# ========== 汇总 ==========
echo ""
echo "=============================================="
echo " 压测完成! 结果目录: $OUTDIR"
echo "=============================================="
echo ""
echo "| 场景 | Value大小 | 最终 RPS |"
echo "|------|:---:|:---:|"
for f in "$OUTDIR"/*.rps; do
    name=$(basename "$f" .rps)
    val=$(cat "$f")
    echo "| $name | - | $val |"
done

