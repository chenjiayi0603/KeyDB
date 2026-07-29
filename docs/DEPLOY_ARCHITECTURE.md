
## 3. 云缓存服务架构（对标阿里云 Tair 磁盘型）

### 3.1 Tair 磁盘型 = 本项目 KeyDB+RocksDB 的对标产品

| 维度 | Tair 企业版 磁盘型 | 本项目 KeyDB+RocksDB FLASH |
|------|:---:|:---:|
| 存储引擎 | LevelDB 魔改版 LSM [1] | RocksDB 7.10.2 |
| 存储介质 | ESSD 云盘 / 本地 SSD | NVMe / SSD |
| 成本 | Redis 纯内存的 ~15% | 取决于 SSD 单价 |
| 性能 | Redis 纯内存的 ~60% | 取决于硬件 |
| 数据模型 | 全量在磁盘 + 内存做缓存 | 全量在 RocksDB + 内存 Dict（双写）|
| 兼容性 | Redis 6.0 协议 [2] | Redis 全协议兼容 |
| 持久化 | LSM 引擎自身 + 额外 AOF/RDB | RocksDB WAL + SST |
| 部署架构 | 标准(主备) / 集群(分片) / 读写分离 | 当前: 主从复制 |

> [1] Tair 开源仓库 `src/storage/ldb/` — LevelDB-based storage engine
> [2] [阿里云帮助中心 - 云数据库 Tair](https://help.aliyun.com/zh/redis/product-overview/what-is-apsaradb-for-redis)

### 3.2 Tair 架构（官方文档可确认的部分）

```
                    用户 VPC
                       │
              ┌────────▼────────┐
              │  Proxy 层        │  ← 智能连接管理 / 路由
              │  (代理模式) 或    │
              │  直连模式         │
              └────────┬────────┘
                       │
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
   ┌──────────┐ ┌──────────┐ ┌──────────┐
   │ 分片 0    │ │ 分片 1    │ │ 分片 2    │  ← 集群架构: 数据按 slot 分布
   │ M  │ R   │ │ M  │ R   │ │ M  │ R   │
   └────┴─────┘ └────┴─────┘ └────┴─────┘

   ┌──────────────────────────────────────┐
   │         每个分片内部 (磁盘型)           │
   │                                      │
   │   ┌──────────┐    ┌──────────────┐   │
   │   │ 内存缓存   │◄──►│ LSM 引擎      │   │
   │   │ (热数据)  │    │ (ESSD/SSD)   │   │
   │   │ ~ns       │    │ ~μs          │   │
   │   └──────────┘    │ 全量持久化     │   │
   │                    └──────────────┘   │
   └──────────────────────────────────────┘
```

**官方可确认的部署架构：**

| 架构模式 | 说明 |
|---------|------|
| 标准架构 | 1 Master + 1 Replica，双机热备，自动故障切换 |
| 集群架构 | 多分片，每分片独立 Master+Replica，数据按 slot 分布 |
| 读写分离 | 主节点挂载只读副本（1~9个），星型或链式复制 |
| Serverless | 自动扩缩容，按量付费 |

### 3.3 数据面与控制面分离

```
 ┌──────────────────────────────────────────────┐
 │               Control Plane (管控面)           │
 │      (独立部署，不承载用户数据流量)             │
 │                                               │
 │  职责: 资源编排 / 调度 / 监控 / 备份 / 计费    │
 │  ⚠ 具体实现细节未公开                        │
 └──────────────┬───────────────────────────────┘
                │ 管理链路
                ▼
 ┌──────────────────────────────────────────────┐
 │               Data Plane (数据面)              │
 │      (承载用户读写流量，低延迟要求)             │
 │                                               │
 │  职责: 执行 KV 命令 / 复制 / 持久化            │
 └──────────────────────────────────────────────┘
```

**未公开的细节（⚠ 以下为合理推断，未经官方确认）：**

| 问题 | 推断 | 置信度 |
|------|------|:---:|
| 实例是容器还是 VM？ | 早期用 VM，云原生版可能用容器+独占资源 | 中 |
| 物理机如何分配实例？ | 调度器按资源池分配，同分片主备不同机器(反亲和) | 高 |
| 扩容时数据如何迁移？ | slot 迁移（类似 Redis Cluster），非全量同步 | 高 |
| 磁盘型的内存淘汰策略？ | 类似 LRU/LFU，与 Redis maxmemory-policy 对齐 | 中 |

---

## 4. 部署模式详细对比

### 4.1 模式 A：Docker Compose 单机（当前 ✅）

```
资源: 1 台机器
部署: docker compose up -d
扩缩: 手动改 compose
故障: 全挂
```

| 适用 | 不适用 |
|------|--------|
| 开发测试 | 生产环境 |
| CI/CD 集成测试 | 需要高可用 |
| 本地验证 | 流量超单机容量 |

---

### 4.2 模式 B：多机直装（生产环境起步）

```
┌──────────────────────────────────────────────────────────┐
│                    多机部署                                │
│                                                          │
│   Host-1                   Host-2                        │
│   ┌──────────────────┐    ┌──────────────────┐           │
│   │ keydb-server      │    │ keydb-server      │           │
│   │ role: master      │◄───│ role: replica     │           │
│   │ :6379             │    │ :6379             │           │
│   │ FLASH: /data/flash│    │ FLASH: /data/flash│           │
│   └──────────────────┘    └──────────────────┘           │
│                                                          │
│   Host-3                                                  │
│   ┌──────────────────┐                                   │
│   │ keydb-server      │                                   │
│   │ role: replica     │                                   │
│   │ FLASH: /data/flash│                                   │
│   └──────────────────┘                                   │
└──────────────────────────────────────────────────────────┘
```

部署方式可以选择：

| 部署方式 | 安装 | 优点 | 缺点 |
|---------|------|------|------|
| 二进制直装 | scp + systemd | 最简单，性能最好 | 手动管理 |
| Docker 镜像 | docker run | 环境一致 | 网络/磁盘多一层 |
| VM 镜像 | cloud-init/自制镜像 | 内核可调优，完全隔离 | 制作成本高 |

> ⚠ 阿里云具体用哪种未公开。Tair 开源版是 C++ 二进制 + LevelDB，云版部署细节属内部实现。

**关于一机一实例 vs 一机多实例：**

```
一台物理机可跑多个实例，关键看资源隔离需求。

一机多实例:                    一实例独占机器:
┌─────────────────┐           ┌─────────┐ ┌─────────┐
│  PM (64C/256G)   │           │  PM-1   │ │  PM-2   │
│  ┌───┐┌───┐┌───┐ │           │ M:6379  │ │ R:6379  │
│  │ M ││R1 ││R2 │ │           │ NVMe    │ │ NVMe    │
│  └───┘└───┘└───┘ │           └─────────┘ └─────────┘
│  共享 NVMe 带宽    │           独占 NVMe 带宽
│  故障域: 1台       │           故障域: 独立
│  成本: 低          │           成本: 高
│  适合: 开发/小规模  │           适合: 生产/高性能要求
└─────────────────┘
```

> 云厂商通常选"每实例独占资源"以保证性能 SLA 可预测。自己部署按需选择。

| 对比维度 | Docker Compose | 多机直装 |
|---------|:---:|:---:|
| 跨机部署 | 需改造 | ✅ |
| 高可用 | ❌ 单机全挂 | ✅ 多机冗余 |
| 网络延迟 | bridge 一跳 | 裸网卡 |
| 磁盘延迟 | overlay2 | NVMe 裸盘 |
| 扩容 | 手动 | 手动+脚本 |
| 运维 | 低 | 中 |

---

### 4.3 模式 C：K8s StatefulSet + Local PV

```
┌────────────────────────────────────────────────────────────┐
│                      K8s Cluster                            │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                  StatefulSet: keydb                    │   │
│  │                                                       │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │   │
│  │  │ keydb-0     │  │ keydb-1     │  │ keydb-2     │   │   │
│  │  │ (Master)    │  │ (Replica)   │  │ (Replica)   │   │   │
│  │  │ PVC: nvme-0 │  │ PVC: nvme-1 │  │ PVC: nvme-2 │   │   │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘   │   │
│  └─────────┼────────────────┼────────────────┼───────────┘   │
│            │                │                │               │
│  ┌─────────▼────────────────▼────────────────▼───────────┐   │
│  │              Headless Service: keydb-svc               │   │
│  │   DNS: keydb-0.keydb-svc, keydb-1.keydb-svc ...       │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              StorageClass: local-nvme                  │   │
│  │   provisioner: kubernetes.io/no-provisioner            │   │
│  │   volumeBindingMode: WaitForFirstConsumer             │   │
│  └──────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────┘
```

| 优势 | 劣势 |
|------|------|
| 声明式管理，自动调度 | 网络性能损耗 (CNI overlay) |
| 滚动更新、自动重启 | Local PV 绑定节点，Pod 不能漂移 |
| 生态完善（监控/日志/Ingress） | 运维复杂度高 |
| 适合已有 K8s 基础设施的团队 | 有状态扩缩需 Operator 支持 |

---

## 5. 管控面设计（参考云厂商模式，自行实现）

> ⚠ 阿里云管控面具体实现未公开，以下为通用设计模式。

### 5.1 功能模块

```
                    ┌───────────────────────────┐
                    │       API Server           │
                    │   POST /instances          │
                    │   PUT  /instances/:id/scale│
                    │   GET  /instances/:id/info │
                    │   POST /backups            │
                    └─────────────┬─────────────┘
                                  │
        ┌─────────────┬───────────┼────────────┬───────────┐
        ▼             ▼           ▼            ▼           ▼
  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
  │ 实例管理  │ │ 调度引擎  │ │ 监控告警  │ │ 备份恢复  │ │ 配置中心  │
  │Manager   │ │Scheduler │ │Monitor   │ │Backup    │ │Config    │
  ├──────────┤ ├──────────┤ ├──────────┤ ├──────────┤ ├──────────┤
  │创建/删除  │ │选主机     │ │Metrics   │ │定时快照   │ │参数模板   │
  │变配/升降级│ │反亲和     │ │Alert     │ │增量备份   │ │版本管理   │
  │重启/迁移  │ │资源池     │ │Dashboard │ │跨地域容灾  │ │热更新     │
  └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘

  ┌──────────────────────────────────────────────────────────────┐
  │                    元数据库                                    │
  │  instance: {id, spec, status, master_ip, replicas, config}   │
  │  host_pool: {host_id, cpu, mem, disk, available}              │
  │  task: {id, type, status, instance_id}                        │
  │  backup: {id, instance_id, path, size, type}                  │
  └──────────────────────────────────────────────────────────────┘
```

### 5.2 扩容调度流程

```
用户请求: 扩容 (增加 Replica)
        │
        ▼
┌───────────────┐
│   API Server   │  参数校验 → 写任务到元数据库
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Scheduler    │  定时扫描待处理任务
└───────┬───────┘
        │
        ▼
┌───────────────┐
│  选主机策略     │
│  ① 过滤:       │
│    CPU/Mem/Disk 余量充足
│    不在同一物理机 (反亲和)
│    同地域/可用区 (低延迟)
│    节点健康
│  ② 排序:       │
│    资源碎片最少优先
│    负载最低优先
└───────┬───────┘
        │
        ▼
┌───────────────┐
│  执行引擎      │
│  ① 拉取镜像/安装包
│  ② 创建实例
│  ③ 下发配置:
│     storage-provider flash /data
│     replicaof <master_ip> 6379
│  ④ 启动 keydb-server
│  ⑤ 等待复制同步完成
│  ⑥ 更新元数据库状态
└───────────────┘
```

### 5.3 故障自愈流程

```
  Monitor 检测到 Master 不可达
            │
            ▼
  ┌──────────────────┐
  │ 多次探测确认故障    │
  └────────┬─────────┘
           │
           ▼
  ┌──────────────────┐
  │  选新 Master:     │
  │  复制 offset 最大的 Replica
  │
  │  执行切换:        │
  │  SLAVEOF NO ONE
  │  更新 VIP/Proxy 指向
  │  其他 Replica 改指新 Master
  │
  │  补 Replica:     │
  │  自动创建新节点补足目标数
  └──────────────────┘
```

---

## 6. 方案选型决策树

```
  ├── 只有 1 台机器？
  │   └── YES → Docker Compose (当前 ✅)
  │
  ├── 有多台机器？
  │   └── YES → 多机直装 (二进制/docker均可)
  │
  ├── 已有 K8s 集群？
  │   └── YES → StatefulSet + Local PV
  │
  ├── 需要自动扩缩容 + 多租户？
  │   └── YES → 管控面 + 调度引擎 (第5节)
  │
  └── 直接用云厂商托管？
      └── YES → 阿里云 Tair / AWS ElastiCache
```

---

## 7. 各模式性能对比

| 指标 | Docker Compose | 多机直装(二进制) | K8s Local PV | Tair 磁盘型 |
|------|:---:|:---:|:---:|:---:|
| 内存读写延迟 | ~ns | ~ns | ~ns | ~ns |
| 磁盘读取 | ~100μs (overlay2) | ~50μs (裸盘) | ~100μs | ~50μs |
| 网络 RTT | ~0.1ms | ~0.1ms | ~0.3ms (CNI) | ~0.1ms (VPC) |
| CPU 损耗 | ~2% (容器) | ~0% | ~5% | 未公开 |
| 故障恢复 | 手动 | 手动/分钟 | 自动/分钟 | 自动/秒 |
| 运维投入 | 低 | 中 | 高 | 零(托管) |

---

## 8. 建议演进路径

```
Phase 1 (当前)       Phase 2 (小规模生产)       Phase 3 (平台化)
───────────────────  ────────────────────────  ────────────────────
Docker Compose  →    多机直装  →               管控面 + 自动调度
   ✅ 已完成           下一步                     未来方向

                     关键动作:                   关键动作:
                     ① 多机验证主从复制          ① API Server
                     ② 监控接入                  ② 元数据库设计
                     ③ 备份策略                  ③ 调度 + 自愈
                     ④ 写部署脚本                 ④ 多租户
```

---

## 9. 文件清单

```
docs/
├── DESIGN.md                  # 系统设计文档 (代码架构)
└── DEPLOY_ARCHITECTURE.md     # 本文档 (部署架构)
```

---

## 10. 复制架构：KeyDB 为何不需要零拷贝 (sendfile/splice) bypass

### 10.1 背景：分布式存储的零拷贝需求

分布式存储系统（如 Ceph）在复制磁盘数据块时，典型链路为：

```
磁盘 → 内核 Page Cache → [用户态 buffer 拷贝] → Socket 内核缓冲区 → 网络
```

`sendfile()` / `splice()` 等系统调用的作用是 bypass 用户态那次内存拷贝，让数据直接在内核态完成 disk fd → socket fd 的传输：

```
磁盘 → 内核 Page Cache ──sendfile──→ Socket 内核缓冲区 → 网络
          (零拷贝，数据不出内核态)
```

这对 GB~TB 级磁盘块复制至关重要——节省的 CPU 拷贝开销随数据量线性放大。

### 10.2 KeyDB 不需要零拷贝的四个原因

**原因 1：常规复制走命令流，数据来源是内存**

常规主从复制是**命令流**：master 执行写命令后，`replicationFeedSlaves()` 将命令序列化为 RESP 协议字节，通过 `addReply` → client output buffer → socket 直接发送。

```
复制链路：内存 redisObject → RESP 序列化 → addReply → socket
                        (全程内存操作，无磁盘参与)
```

单条命令通常几十~几百字节，用户态拷贝开销相比命令执行本身可忽略。数据源头是内存中的 redisObject，不存在"从磁盘读出再发送"的场景，sendfile 根本不适用。

**原因 2：全量同步有 Fast Sync，省掉磁盘 I/O 和一次用户态拷入**

KeyDB 独创的 `SLAVE_CAPA_KEYDB_FASTSYNC` 机制 (`replication.cpp:1150 rdbSaveSnapshotForReplication()`) 直接从内存 MVCC 快照构造数据发给 slave：

```
内存 MVCC 快照 → replicationBuffer::addData (memcpy, 用户态构造 RESP)
    → flushData → addReplyProto → client reply chain
    → connSocketWrite → write(fd, buf, len)  ← 用户→内核拷贝 (socket send buffer)
    → TCP/IP 协议栈 → DMA → NIC
```

对比 RDB 文件路径：
```
RDB 文件 → read() → 用户态 buffer [内核→用户拷贝]
    → write() → socket 内核缓冲区 [用户→内核拷贝]
    → TCP/IP 协议栈 → NIC
```

两者都逃不掉 `write()` 系统调用的**用户→内核拷贝**——这是 TCP socket 通信固有的。Fast Sync 的优化在于：
- 省掉了 `read()` 的磁盘 I/O + 内核→用户拷贝
- 省掉了 fork 子进程生成 RDB 的开销
- 但并不消除 socket 层的用户→内核拷贝（任何用户态内存数据写 TCP socket 都必须经过这次拷贝）

`sendfile()` 场景（KeyDB 未采用）：数据从内核 Page Cache 直接进 socket 缓冲区，**0 次用户空间拷贝**。但代价是必须先有 RDB 文件落盘 + TLS 下不可用。

| 路径 | 拷贝次数 | 磁盘 I/O |
|------|:---:|:---:|
| RDB `read()`+`write()` | 2 (内核→用户 + 用户→内核) | 有 |
| Fast Sync `write()` only | 1 (用户→内核) | **无** |
| `sendfile()` (未采用) | 0 | 有 |

**原因 3：TLS 默认开启，阻止内核态零拷贝**

KeyDB 默认 `BUILD_TLS=yes`。`sendBulkToSlave()` 注释明确声明：

> `/* try to use sendfile system call if supported, unless tls is enabled. fallback to normal read+write otherwise. */`

TLS 加密必须在用户态完成（加密、封装 TLS record），数据必须先读到用户态内存 → 加密 → 再写回 socket。无法走内核态的 sendfile，所以即使有 RDB 文件 fd，TLS 场景下也只能用 `read()` + `connWrite()`。

**原因 4：即使 RDB 文件路径，数据量级不同**

传统 RDB 同步路径：子进程 fork → 写 RDB 到磁盘/pipe → 父进程 `sendBulkToSlave()` 用 `read()` + `connWrite()`（`PROTO_IOBUF_LEN` = 16KB buffer）。KeyDB 的 RDB 通常在 MB~GB 级别，远小于分布式存储，16KB 粒度的用户态读写在现代 CPU 上开销极低。

### 10.3 两种复制模式

**传统模式 (raw protocol forwarding)**：
- master 把命令序列化为 `*N\r\n$L\r\n...` RESP 字节流
- 通过 `feedReplicationBacklog()` 写 backlog + `addReply` 推送 slave output buffer
- slave event loop: `readQueryFromClient` → `processInputBuffer` 读取执行
- slave 连接就是普通 `client` + `CLIENT_SLAVE` flag，与普通客户端共用事件循环

**Active Replication 模式 (RREPLAY)**：
- master 封装命令为 `RREPLAY <uuid> <cmd_buf> [dbid] [mvcc]`
- UUID 用于 multi-master 去重，MVCC timestamp 用于幂等和乱序检测
- 接收端 `replicaReplayCommand()`: 提取 cmd_buf → 注入 fake client querybuf → `processInputBuffer` 执行
- `alsoPropagate()` 在 multi-master 拓扑中继续转发

### 10.4 syncWithMaster 连接建立状态机

```
REPL_STATE_CONNECTING → REPLPING/PING
  → REPL_STATE_RECEIVE_PING_REPLY → +PONG
  → REPL_STATE_SEND_HANDSHAKE → AUTH + REPLCONF
  → REPL_STATE_RECEIVE_AUTH_REPLY → ...
  → REPL_STATE_SEND_PSYNC → PSYNC <replid> <offset>
  → REPL_STATE_RECEIVE_PSYNC_REPLY → +CONTINUE(增量) 或 +FULLRESYNC(全量)
  → (全量) readSyncBulkPayload → 接收 RDB/快照
  → REPL_STATE_CONNECTED → 持续接收命令流
```

### 10.5 拷贝路径对照

**RDB 全量同步（传统路径）**：
```
RDB 文件 on disk
  → read(fd, buf, PROTO_IOBUF_LEN)  ← 内核→用户态拷贝 (1)
  → sendBulkToSlave() → connSocketWrite() → write(fd, buf, len) ← 用户态→内核拷贝 (2)
  → 内核 socket send buffer → TCP/IP 协议栈 (sk_buff 分配、分段等) → DMA → NIC
```
共 2 次跨态拷贝 + 磁盘 I/O。

**Fast Sync 全量同步**：
```
内存 redisObject
  → RESP 序列化 → replicationBuffer::addData() → memcpy → reply->buf()  (用户态构造)
  → flushData() → addReplyProto → client reply 链
  → sendReplyToClient → connSocketWrite() → write(fd, buf, len) ← 用户态→内核拷贝 (1)
  → 内核 socket send buffer → TCP/IP 协议栈 → DMA → NIC
```
共 1 次跨态拷贝（write syscall），没有磁盘 I/O。

**sendfile（KeyDB 未采用，TLS 下不可用）**：
```
RDB 文件 on disk
  → sendfile(socket_fd, file_fd, &offset, count)  ← 内核内部直接传输，无用户态参与
  → 内核 socket send buffer → TCP/IP → NIC
```
共 0 次跨态拷贝。节省了 CPU，但需文件 fd + 不能加密。

**结论**：Fast Sync 优化的本质是去掉**磁盘 I/O 和一次 read() 拷贝**，而非消除协议栈拷贝。TCP socket 的 `write()` 系统调用必然触发用户→内核拷贝——这是所有用户态程序的硬限制。真正能绕过这一层的只有 `sendfile()`/`splice()`，但它们要求数据源头是文件描述符（内核态），且与 TLS 互斥。

### 10.6 总结对照

| 方面 | 分布式存储 (Ceph) | KeyDB |
|------|-------------------|-------|
| 数据来源 | 磁盘 (块/对象) | 内存 (KV) |
| 单次传输量 | MB~GB 级 | 几十B~KB (命令) / MB级 (全量) |
| 常规复制路径 | 磁盘→socket (可选零拷贝) | 内存→socket (1次 write() 拷贝) |
| 全量同步优化 | sendfile/splice: 0 次跨态拷贝 | Fast Sync: 1 次跨态拷贝, 无磁盘 I/O |
| 零拷贝适用性 | ✅ (数据在磁盘, 有 fd) | ❌ (数据在内存, `write()` 拷贝不可避免) |
| TLS | 内部网络常不用 | 默认开启, 阻止 sendfile |
| 协议层 | 独立 Messenger 层 | 复制=普通 client + flag |

---

## 参考资料

- [阿里云 Tair 产品概述](https://help.aliyun.com/zh/redis/product-overview/what-is-apsaradb-for-redis)
- [Tair 开源仓库](https://github.com/alibaba/tair) — `src/storage/ldb/` LevelDB 存储引擎
- [Redis Cluster Specification](https://redis.io/docs/reference/cluster-spec/) — slot 分片参考
