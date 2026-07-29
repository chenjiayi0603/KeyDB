#!/bin/bash
# ============================================================
#  KeyDB + RocksDB FLASH 主从集群 — 部署管理脚本
#
#  用法:
#    ./dockercompose_deploy.sh start      # 构建镜像并启动集群
#    ./dockercompose_deploy.sh stop       # 停止集群 (保留数据卷)
#    ./dockercompose_deploy.sh restart    # 重启集群
#    ./dockercompose_deploy.sh status     # 查看完整状态 (容器/复制/FLASH/资源)
#    ./dockercompose_deploy.sh down       # 停止并清除所有数据 (需确认)
#    ./dockercompose_deploy.sh logs       # 查看实时日志
#
#  节点端口:
#    Master     localhost:6379
#    Replica-1  localhost:6380
#    Replica-2  localhost:6381
# ============================================================
set -e

cd "$(dirname "$0")"

usage() {
    echo "用法: $0 <command>"
    echo ""
    echo "命令:"
    echo "  start      构建镜像并启动集群"
    echo "  stop       停止集群 (保留数据)"
    echo "  restart    重启集群"
    echo "  status     查看集群完整状态"
    echo "  down       停止并清除所有数据"
    echo "  logs       查看所有节点日志"
    echo ""
    echo "示例:"
    echo "  $0 start"
    echo "  $0 status"
    echo "  $0 logs"
    exit 1
}

cmd_start() {
    echo "============================================"
    echo "   KeyDB + RocksDB FLASH Cluster — 启动"
    echo "============================================"
    echo ""
    echo "[1/3] 构建 Docker 镜像..."
    docker compose build --quiet 2>&1
    echo "      镜像构建完成"

    echo "[2/3] 启动集群..."
    docker compose up -d --wait 2>&1

    echo "[3/3] 等待节点就绪..."
    sleep 2

    echo ""
    echo "============================================"
    echo "   集群启动完成"
    echo "============================================"
    echo ""
    printf "  %-15s %s\n" "Master"    "localhost:6379"
    printf "  %-15s %s\n" "Replica-1" "localhost:6380"
    printf "  %-15s %s\n" "Replica-2" "localhost:6381"
    echo ""
}

cmd_stop() {
    echo "============================================"
    echo "   KeyDB + RocksDB FLASH Cluster — 关闭"
    echo "============================================"
    echo ""

    RUNNING=$(docker compose ps --status running -q 2>/dev/null | wc -l)
    if [ "$RUNNING" -eq 0 ]; then
        echo "集群未运行，无需关闭。"
        exit 0
    fi

    docker compose stop 2>&1
    echo ""
    echo "集群已关闭 (数据卷已保留)。"
}

cmd_restart() {
    echo "重启集群..."
    docker compose restart --timeout 10 2>&1
    sleep 2
    echo "重启完成。"
    cmd_status
}

cmd_status() {
    echo "============================================"
    echo "   KeyDB + RocksDB FLASH Cluster — 状态"
    echo "============================================"
    echo ""

    RUNNING=$(docker compose ps --status running -q 2>/dev/null | wc -l)
    if [ "$RUNNING" -eq 0 ]; then
        echo "⚠️  集群未运行 (启动: $0 start)"
        exit 0
    fi

    echo "▸ 容器:"
    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
    echo ""

    echo "▸ 复制拓扑:"
    docker exec keydb-master keydb-cli INFO replication 2>/dev/null \
        | grep -E "role|connected_slaves|slave[0-9]" | sed 's/^/  /'
    echo ""

    echo "▸ 数据量:"
    for node in keydb-master keydb-replica-1 keydb-replica-2; do
        DBSIZE=$(docker exec "$node" keydb-cli DBSIZE 2>/dev/null || echo "-")
        printf "  %-16s DBSIZE = %s\n" "$node" "$DBSIZE"
    done
    echo ""

    echo "▸ 复制延迟:"
    docker exec keydb-master keydb-cli INFO replication 2>/dev/null \
        | grep "lag" | sed 's/^/  /'
    echo ""

    echo "▸ FLASH 磁盘:"
    for node in keydb-master keydb-replica-1 keydb-replica-2; do
        SIZE=$(docker exec "$node" du -sh /data/flash/ 2>/dev/null | awk '{print $1}')
        echo "  $node → /data/flash = $SIZE"
    done
    echo ""

    echo "▸ 资源:"
    docker stats --no-stream \
        --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" \
        $(docker compose ps -q) 2>/dev/null

    echo ""
    echo "连接: :6379(master) :6380(replica-1) :6381(replica-2)"
}

cmd_down() {
    echo "============================================"
    echo "   警告: 即将删除所有数据!"
    echo "============================================"
    echo ""
    read -p "确认删除? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "已取消。"
        exit 0
    fi
    echo ""
    docker compose down -v 2>&1
    echo ""
    echo "集群已停止，所有数据已清除。"
}

cmd_logs() {
    docker compose logs -f --tail=50
}

case "${1:-}" in
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    restart)  cmd_restart ;;
    status)   cmd_status ;;
    down)     cmd_down ;;
    logs)     cmd_logs ;;
    *)        usage ;;
esac
