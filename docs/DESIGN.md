# KeyDB + RocksDB FLASH Storage — 系统设计文档

> 基于 KeyDB 6.x 分支，集成 RocksDB 作为 FLASH 存储后端，
> 支持主从集群部署。数据采用双写模型：写内存的同时写 RocksDB，
> RocksDB 持有全量数据（热+冷），内存淘汰不影响磁盘数据完整性。

---

## 1. 项目概览

### 1.1 项目来源

```
Snapchat/KeyDB (官方)
    └── chenjiayi0603/KeyDB (上游 fork)
            └── 本项目 (二次开发)
```

| 属性     | 说明                                       |
| -------- | ------------------------------------------ |
| 上游仓库 | `https://github.com/chenjiayi0603/KeyDB`   |
| 开发分支 | `main` (跟踪上游) / `stable` (本地开发分支) |
| 构建模式 | `ENABLE_FLASH=yes`                         |
| RocksDB  | v7.10.2 (静态链接)                         |
| 编译器   | GCC 15 (Ubuntu 26.04)                      |

### 1.2 核心特性

- **FLASH 存储**：热数据在内存，冷数据自动换出到 RocksDB（SSD）
- **主从复制**：1 Master + N Replica，全量同步 + 增量同步
- **持久化**：基于 RocksDB 的 WAL + SST 文件，重启自动恢复
- **兼容 Redis 协议**：完全兼容 Redis 命令集
- **容器化部署**：Docker Compose 一键编排

---

## 2. 系统架构

### 2.1 总体架构图

```
┌──────────────────────────────────────────────────────────────┐
│                     Client Applications                       │
│              (Redis Protocol, any Redis client)               │
└──────┬───────────────────────┬───────────────────┬───────────┘
       │ :6379                 │ :6380              │ :6381
       ▼                       ▼                    ▼
┌──────────────┐   replication   ┌──────────────┐   ┌──────────────┐
│              │◄───────────────►│              │   │              │
│  keydb-master│                 │keydb-replica-1│  │keydb-replica-2│
│  role:master │                 │role:replica   │   │role:replica  │
│              │                 │              │   │              │
│  ┌────────┐  │                 │  ┌────────┐  │   │  ┌────────┐  │
│  │ Memory │  │                 │  │ Memory │  │   │  │ Memory │  │
│  │ (Hot)  │  │                 │  │ (Hot)  │  │   │  │ (Hot)  │  │
│  └───┬────┘  │                 │  └───┬────┘  │   │  └───┬────┘  │
│      │FLASH  │                 │      │FLASH  │   │      │FLASH  │
│  ┌───▼────┐  │                 │  ┌───▼────┐  │   │  ┌───▼────┐  │
│  │RocksDB │  │                 │  │RocksDB │  │   │  │RocksDB │  │
│  │(Cold)  │  │                 │  │(Cold)  │  │   │  │(Cold)  │  │
│  └───┬────┘  │                 │  └───┬────┘  │   │  └───┬────┘  │
└──────┼───────┘                 └──────┼───────┘   └──────┼───────┘
       │                                │                    │
       ▼                                ▼                    ▼
┌─────────────┐              ┌─────────────┐      ┌─────────────┐
│  Volume:    │              │  Volume:    │      │  Volume:    │
│master_data  │              │replica1_data│      │replica2_data│
│ /data/flash │              │ /data/flash │      │ /data/flash │
│  (SSD/NVMe) │              │  (SSD/NVMe) │      │  (SSD/NVMe) │
└─────────────┘              └─────────────┘      └─────────────┘
```

### 2.2 冷热数据逻辑视图

> 概念层：从数据访问模式角度理解系统行为

```
                     ┌─────────────────────┐
                     │    Client Request     │
                     └──────────┬────────────┘
                                │
                        SET key value
                                │
                     ┌──────────▼──────────┐
                     │   KeyDB Server Core  │
                     └──────────┬───────────┘
                                │
              ┌─────────────────┼─────────────────┐
              │ 双写：同时写入内存和磁盘                   │
              ▼                 │                 ▼
   ┌──────────────────┐        │    ┌──────────────────────┐
   │   Memory (热层)   │        │    │   FLASH / RocksDB     │
   │                  │        │    │   (全量持久化层)        │
   │  ┌─────────────┐ │        │    │  ┌──────────────────┐ │
   │  │ key1 → val1 │◄┼────────┼────┤  │ key1 → val1 (热)  │ │
   │  │ key2 → val2 │ │ 双写   │    │  │ key2 → val2 (热)  │ │
   │  │ key3 → val3 │ │        │    │  │ key3 → val3 (热)  │ │
   │  └─────────────┘ │        │    │  │ key4 → val4 (冷)  │ │
   │                  │        │    │  │ key5 → val5 (冷)  │ │
   │  访问延迟: ~ns    │        │    │  └──────────────────┘ │
   │  容量: 受内存限制  │        │    │  访问延迟: ~μs         │
   └────────┬─────────┘        │    │  容量: SSD/NVMe       │
            │                  │    └──────────┬───────────┘
            │                  │               │
   ┌────────▼──────────┐       │    ┌──────────▼───────────┐
   │  淘汰 (eviction)   │       │    │  Compaction          │
   │  仅删除内存 key     │       │    │  SST 文件合并压缩     │
   │  RocksDB 不受影响  │       │    │  释放磁盘空间          │
   └───────────────────┘       │    └──────────────────────┘
                               │
         ┌─────────────────────┘
         │
         ▼
  ┌─────────────────────────────────────────────────────┐
  │  读取路径                                              │
  │                                                       │
  │  GET key ──► 查内存 Dict ──hit──► 返回                 │
  │                  │                                   │
  │                miss                                  │
  │                  │                                   │
  │                  ▼                                   │
  │            查 RocksDB ──► 加载回内存(cache fill) + 返回 │
  └─────────────────────────────────────────────────────┘
```

**冷热分层对比表：**

| 维度 | 热数据 (Memory) | 冷数据 (FLASH/RocksDB) |
|------|:---:|:---:|
| 位置 | 内存 Dict | SSD/NVMe |
| 延迟 | ~ns | ~μs |
| 容量 | GB 级 (受 RAM 限制) | TB 级 |
| 持久化 | ❌ 重启丢失 | ✅ WAL+SST 持久化 |
| 淘汰影响 | 被删除 | 不受影响，完整保留 |
| 数据范围 | 子集 (高频访问) | 全量 (热+冷) |
| 恢复方式 | 从 RocksDB 加载 | 文件系统保留 |

### 2.3 RocksDB 内部实现视图

> 实现层：KeyDB 数据在 RocksDB 中的物理存储结构

```
  KeyDB Server
       │
       │  IStorage 接口: insert/erase/retrieve
       ▼
┌──────────────────────────────────────┐
│      RocksDBStorageProvider           │
│  实现 IStorage，对接 RocksDB API       │
└──────────────────┬───────────────────┘
                   │
     ┌─────────────┼─────────────┐
     ▼             ▼             ▼
┌─────────┐ ┌──────────┐ ┌──────────┐
│ColumnFamily│ColumnFamily│ColumnFamily│
│ default  │ │ expire   │ │ metadata │
├─────────┤ ├──────────┤ ├──────────┤
│ key→val │ │ key→ttl  │ │ 系统元数据│
│ (业务数据)│ │(过期时间) │ │(DB映射等)│
└────┬────┘ └────┬─────┘ └────┬─────┘
     │           │            │
     └───────────┼────────────┘
                 │
                 ▼
┌──────────────────────────────────────┐
│         RocksDB LSM Engine           │
│                                      │
│  写入路径：                           │
│  ┌──────────┐    flush    ┌────────┐ │
│  │ MemTable │────────────►│  SST   │ │
│  │ (内存)   │             │ Level0 │ │
│  └────┬─────┘             └───┬────┘ │
│       │ WAL (预写日志)        │       │
│       ▼                      │ comp- │
│  ┌──────────┐                │ action │
│  │ WAL File │                ▼       │
│  │ 000004.log              ┌────────┐│
│  └──────────┘         ┌───►│  SST   ││
│                       │    │ Level1 ││
│  读取路径：            │    └───┬────┘│
│  MemTable → L0 → L1   │        │    │
│  → L2 ... → Lmax      ├────────┘    │
│                       │             │
│                       ▼             │
│                  ┌────────┐         │
│                  │  SST   │         │
│                  │ LevelN │         │
│                  └────────┘         │
└─────────────────────────────────────┘

磁盘文件结构:
/data/flash/
├── 000004.log          ← WAL (预写日志, 防崩溃)
├── CURRENT             ← 当前 MANIFEST 版本指针
├── IDENTITY            ← 数据库唯一 ID
├── LOCK                ← 进程级文件锁
├── LOG                 ← RocksDB 引擎日志
├── MANIFEST-000005     ← 版本元数据 (记录 SST 文件列表+层级)
├── OPTIONS-000073      ← ColumnFamily 配置持久化
└── 000xxx.sst          ← Sorted String Table (数据文件)
```

**ColumnFamily 数据格式：**

| ColumnFamily | Key 格式 | Value | 操作 |
|---|---|---|---|
| `default` | `{db_id}:{user_key}` | 序列化的 Redis Object | `Put`/`Get`/`Delete` |
| `expire` | `{db_id}:{user_key}` | expire timestamp (int64) | `Put`/`Delete` |
| `metadata` | `dbid_mapping_{index}` | storage_id | `Put`/`Get` |

**RocksDB 关键数据结构：**

| 结构 | 作用 | 持久化 |
|---|---|---|
| **MemTable** | 内存写缓冲区, skiplist 结构 | ❌ 内存 |
| **WAL** | 预写日志, 顺序写, 崩溃恢复 | ✅ `000004.log` |
| **SST File (L0)** | MemTable flush 产物, key 范围可重叠 | ✅ `*.sst` |
| **SST File (L1~N)** | Compaction 产物, key 范围有序不重叠 | ✅ `*.sst` |
| **MANIFEST** | 记录所有 SST 文件的版本和层级 | ✅ `MANIFEST-*` |
| **CURRENT** | 指向当前有效 MANIFEST 文件 | ✅ |
| **Bloom Filter** | SST 文件内嵌, 快速判断 key 是否存在 | ✅ 在 SST 内 |
| **Block Cache** | 缓存热点 SST Block, 加速读 | ❌ 内存 |

---

## 3. 核心模块设计

### 3.1 存储接口层 (`src/IStorage.h`)

```cpp
                     ┌──────────────────────┐
                     │    IStorageFactory    │ ← 工厂模式，创建存储实例
                     ├──────────────────────┤
                     │ + create(db, iter)    │
                     │ + createMetadataDb()  │
                     │ + name() : const char*│
                     │ + totalDiskspaceUsed()│
                     │ + FSlow() : bool      │
                     └──────────┬───────────┘
                                │ instantiates
                                ▼
                     ┌──────────────────────┐
                     │      IStorage         │ ← 抽象存储接口
                     ├──────────────────────┤
                     │ + insert(k,v)         │
                     │ + erase(k)            │
                     │ + retrieve(k, cb)     │
                     │ + clear()             │
                     │ + enumerate(cb)       │
                     │ + bulkInsert(...)      │
                     │ + getExpirationCandidates() │
                     │ + getEvictionCandidates()   │
                     │ + setExpire(k, ttl)   │
                     │ + flush()             │
                     │ + clone()             │
                     └──────────────────────┘
```

### 3.2 RocksDB 实现 (`src/storage/`)

```
storage/
├── rocksdb.h                RocksDBStorageProvider 类声明
├── rocksdb.cpp              insert/erase/retrieve/bulkInsert 实现
├── rocksdbfactory.h         工厂入口函数声明
├── rocksdbfactory.cpp       DB::Open / ColumnFamily 管理
│   ├── RocksDBStorageFactory::create()
│   │   ├── 打开/创建 RocksDB 实例
│   │   ├── 管理 ColumnFamily (default, expire, metadata)
│   │   └── 返回 RocksDBStorageProvider
│   └── RocksDBStorageFactory::createMetadataDb()
│       └── 独立的元数据库 (跨 DB 共享信息)
└── rocksdbfactor_internal.h 工厂内部辅助结构
```

**ColumnFamily 设计：**

| ColumnFamily | 用途 | Key 格式 | Value |
|---|---|---|---|
| `default` | 数据存储 | `{db}:{user_key}` | `{value_data}` |
| `expire` | 过期时间索引 | `{db}:{user_key}` | `{expire_timestamp}` |
| `metadata` | 元数据 | 系统内部 key | 数据库元信息 |

### 3.3 存储缓存层 (`src/StorageCache.cpp`)

StorageCache 是内存和 FLASH 之间的中间层：

```
         ┌─────────────────────────────┐
         │       KeyDB Write Path       │
         └─────────────┬───────────────┘
                       │
         ┌─────────────▼───────────────┐
         │     Memory Dict (热数据)      │
         │     缓存层，受淘汰影响          │
         └─────────────┬───────────────┘
                       │ miss (读) / 淘汰 (写)
         ┌─────────────▼───────────────┐
         │       StorageCache           │
         │  ┌─────────────────────────┐│
         │  │ hash 表 (访问计数)        ││
         │  │ 追踪 key 访问热度         ││
         │  └─────────────┬───────────┘│
         │                │ miss        │
         │  ┌─────────────▼───────────┐│
         │  │  m_spstorage->insert()   ││ ← 写入 RocksDB
         │  │  m_spstorage->retrieve() ││ ← 从 RocksDB 读取
         │  │  m_spstorage->erase()    ││ ← 从 RocksDB 删除
         │  └─────────────┬───────────┘│
         └────────────────┼────────────┘
                          │
         ┌────────────────▼────────────┐
         │      RocksDB (全量)           │
         │      热数据 + 冷数据           │
         └─────────────────────────────┘
```

> **写路径**：`dbAddCore()` → Memory Dict + 异步/同步 → `StorageCache::insert()` → `RocksDB::Put()`
> **读路径**：Memory Dict hit → 返回; miss → `StorageCache::retrieve()` → `RocksDB::Get()`
> **淘汰**：仅 `dictDelete()` 内存，RocksDB 数据不受影响

---

## 4. 主从复制架构

### 4.1 复制流程

```
 Master (6379)                         Replica (6380/6381)
 ─────────────                         ───────────────────
                    PSYNC ? <replid> <offset>
     │◄─────────────────────────────────────────────│
     │                                              │
     ├── 检查 replid 和 offset                       │
     │                                              │
     ├── 可以部分同步？                               │
     │   YES → send backlog data ──────────────────►│
     │   NO  → 全量同步:                             │
     │                                               │
     │   ① fork() 子进程生成 RDB snapshot              │
     │   ② send RDB file ───────────────────────────►│ 加载 RDB
     │   ③ send replication stream ────────────────►│ 应用增量
     │                                              │
     │   REPLCONF ACK <offset> ◄────────────────────│ 确认
     │                                              │
     │   持续发送写命令 ─────────────────────────────►│ 实时同步
```

### 4.2 节点角色

| 配置项 | Master | Replica |
|--------|--------|---------|
| `replicaof` | 无 | `keydb-master 6379` |
| `replica-read-only` | no | yes |
| `active-replica` | - | yes (KeyDB 特性) |
| FLASH 数据 | 独立 | 独立 (各自 RocksDB) |

### 4.3 复制与 FLASH 的交互

```
写请求到达 Master
        │
        ▼
┌──────────────────────────┐
│ 1. 写入内存 Dict          │
│ 2. 写入本地 RocksDB (双写) │
└──────────┬───────────────┘
           │
           ▼
┌──────────────────────────┐
│ 3. 复制命令流 → Replica    │
└──────────┬───────────────┘
           │
           ▼
   ┌──────────────┐
   │ Replica 收到  │
   │ 复制命令       │
   └──────┬───────┘
          │
     ┌────┴──────────┐
     ▼               ▼
┌──────────┐  ┌──────────────┐
│写内存 Dict│  │ 写本地 RocksDB │
└──────────┘  │ (独立双写)    │
              └──────────────┘
```

> **关键设计点**：每个节点独立维护自己的 RocksDB 实例，各自执行双写。
> Master 和 Replica 的 FLASH 数据完全独立，通过 Redis 命令流实现最终一致。

---

## 5. FLASH 双写存储设计

### 5.1 核心机制：双写 + 内存淘汰

```
                          SET key value
                               │
                               ▼
                    ┌──────────────────────┐
                    │       KeyDB Server    │
                    └──────────┬───────────┘
                               │
               ┌───────────────┼───────────────┐
               │  同时写入 (双写)                 │
               ▼                               ▼
    ┌──────────────────┐            ┌──────────────────┐
    │   Memory Dict     │            │   RocksDB FLASH   │
    │   (热数据缓存)     │            │   (全量持久化)     │
    │                   │            │                   │
    │  key1, key2, key3 │            │  key1, key2, key3 │
    │                   │            │  key4, key5, ...  │  ← 冷数据,仅在磁盘
    └────────┬──────────┘            └───────────────────┘
             │
    ┌────────▼──────────┐
    │  内存淘汰 (evict)   │
    │  仅删除内存副本      │
    │  FLASH 数据保留     │
    └───────────────────┘

读路径:
  GET key
     │
     ▼
  ┌──────────┐   hit   ┌──────────┐
  │ 查内存Dict│────────►│ 直接返回  │
  └────┬─────┘         └──────────┘
       │ miss
       ▼
  ┌──────────┐
  │ 查RocksDB │────────► 加载回内存 + 返回
  └──────────┘

删除路径:
  DEL key
     │
     ├──► 删内存 Dict
     └──► 删 RocksDB (同步)
```

### 5.2 两种写入模式

| 模式 | 配置值 | 行为 |
|------|--------|------|
| **WriteBack** (默认) | `storage-memory-model writeback` | 写内存后，周期性批量刷入 RocksDB |
| **WriteThrough** | `storage-memory-model writethrough` | 写内存时同步写 RocksDB |

```cpp
// server.cpp — WriteBack 定期刷新
if (cserver.storage_memory_model == STORAGE_WRITEBACK && ...) {
    flushStorageWeak();   // 定期将内存变更刷入 RocksDB
}

// server.cpp — WriteThrough 同步写
if (cserver.storage_memory_model == STORAGE_WRITETHROUGH && ...) {
    processChanges(false);  // 同步将变更写入 RocksDB
}
```

### 5.3 重启恢复

```
  KeyDB 启动
      │
      ▼
  ┌─────────────────────────┐
  │ storage-provider flash   │
  │ 初始化 RocksDB           │
  └───────────┬─────────────┘
              │
              ▼
  ┌─────────────────────────┐
  │ RocksDB 全量扫描         │
  │ enumerate() 遍历所有 key │
  └───────────┬─────────────┘
              │
              ▼
  ┌─────────────────────────┐
  │ 逐 key 加载到 Memory Dict│
  │ (恢复热数据到内存)        │
  └─────────────────────────┘

  → 结果：内存恢复全量数据(RDB模式) 或按需加载(cache模式)
  → RocksDB 数据完整无损
```

> **关键日志**：
> `Initializing FLASH storage provider (this may take a long time)`
> `Not loading the RDB because a storage provider is set and the database is not empty`

### 5.4 RocksDB 文件结构

```
/data/flash/
├── 000004.log          # WAL (Write-Ahead Log)
├── CURRENT             # 当前 MANIFEST 指针
├── IDENTITY            # 数据库唯一标识
├── LOCK                # 进程锁
├── LOG                 # RocksDB 内部日志
├── MANIFEST-000005     # 版本/元数据清单
├── OPTIONS-000073      # 列族配置 (150KB+)
└── *.sst               # Sorted String Table 数据文件

---

## 6. Docker 部署架构

### 6.1 容器拓扑

```
                    ┌──────────────────────┐
                    │     Docker Host        │
                    │                       │
    Host:6379 ◄─────┤  ┌─────────────────┐  │
                    │  │  keydb-master    │  │
                    │  │  (keydb-flash)  │  │
                    │  └────────┬────────┘  │
                    │           │            │
    Host:6380 ◄─────┤  ┌────────▼────────┐  │
                    │  │ keydb-replica-1  │  │
                    │  │  (keydb-flash)  │  │
                    │  └────────┬────────┘  │
                    │           │            │
    Host:6381 ◄─────┤  ┌────────▼────────┐  │
                    │  │ keydb-replica-2  │  │
                    │  │  (keydb-flash)  │  │
                    │  └─────────────────┘  │
                    │                       │
                    │  Network: keydb-net   │
                    │  172.20.0.0/16        │
                    └──────────────────────┘

Volumes (Docker managed):
  keydb_master_data   → /data/flash  (RocksDB SST/WAL)
  keydb_replica1_data → /data/flash
  keydb_replica2_data → /data/flash
```

### 6.2 Dockerfile 层次

```
┌─────────────────────────────────────────┐
│           Dockerfile (2阶段)              │
├─────────────────────────────────────────┤
│                                         │
│  FROM ubuntu:resolute                    │
│    ├── apt install runtime deps          │
│    ├── COPY keydb-server → /usr/local/bin│
│    ├── COPY keydb-cli    → /usr/local/bin│
│    ├── COPY keydb-benchmark, sentinel... │
│    ├── RUN mkdir /data /etc/keydb       │
│    └── EXPOSE 6379                       │
│                                         │
│  ENTRYPOINT ["keydb-server"]             │
│  CMD ["/etc/keydb/keydb.conf"]           │
└─────────────────────────────────────────┘
```

### 6.3 健康检查流程

```
┌─────────────┐     every 5s     ┌──────────────┐
│  Docker      │────────────────►│  keydb-cli    │
│  HealthCheck │                 │  PING         │
└──────┬───────┘                 └──────┬────────┘
       │                                │
       │  ┌──────────┐                  │
       │  │ healthy   │◄───── PONG ─────┘
       │  └──────────┘
       │
       │  ┌──────────┐
       │  │ unhealthy │◄───── timeout/error
       │  └────┬─────┘
       │       │
       │       ▼
       │  ┌──────────┐
       └──│ restart   │
          └──────────┘
```

---

## 7. 编译构建流程

### 7.1 依赖关系

```
┌──────────────────┐
│   KeyDB 主程序    │
└────────┬─────────┘
         │
    ┌────┼────────────┬──────────────┐
    ▼    ▼            ▼              ▼
┌────────┐ ┌────────┐ ┌──────────┐ ┌──────────┐
│jemalloc│ │lua     │ │hiredis   │ │rocksdb   │
│5.2.1   │ │        │ │          │ │v7.10.2   │
│(静态库) │ │(静态库)│ │(静态库)   │ │(静态库)   │
└────────┘ └────────┘ └──────────┘ └────┬─────┘
                                        │
                                   ┌────┼────────────┐
                                   ▼    ▼            ▼
                              ┌──────┐┌──────┐┌──────────┐
                              │snappy││zstd  ││lz4/bz2   │
                              └──────┘└──────┘└──────────┘
```

### 7.2 编译命令

```bash
ENABLE_FLASH=yes make -j$(nproc) \
  KEYDB_CFLAGS="-I$HOME/.local/include" \
  KEYDB_LDFLAGS="-L$HOME/.local/lib -Wl,-rpath,$HOME/.local/lib" \
  CFLAGS="-I$HOME/.local/include" \
  LDFLAGS="-L$HOME/.local/lib"
```

**产物：**

| 文件 | 大小 | 说明 |
|------|------|------|
| `src/keydb-server` | ~11MB (stripped) | 主服务程序 |
| `src/keydb-cli` | ~1MB | 命令行客户端 |
| `src/keydb-benchmark` | ~4MB | 压测工具 |
| `src/keydb-sentinel` | ~11MB | 哨兵 |

---

## 8. 配置参数

### 8.1 FLASH 核心配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `storage-provider flash <path>` | 启用 FLASH，指定数据目录 | 无 (需显式启用) |
| (RocksDB 内部) | 通过 `keydb.conf` 或启动参数传递 | 默认 RocksDB 选项 |

### 8.2 复制配置

| 参数 | Master | Replica |
|------|--------|---------|
| `port` | 6379 | 6379 (容器内) |
| `replicaof <host> <port>` | - | `keydb-master 6379` |
| `replica-read-only` | no | yes |
| `active-replica` | - | yes |
| `repl-diskless-sync` | no | - |
| `repl-backlog-size` | 1mb | - |

### 8.3 持久化配置

| 参数 | 值 | 说明 |
|------|----|------|
| `save` | `""` | 关闭 RDB 自动快照 (FLASH 已持久化) |
| `appendonly` | no | 关闭 AOF (FLASH 已持久化) |

> **设计决策**：使用 RocksDB FLASH 作为唯一持久化方式，关闭 RDB 和 AOF 以避免双重写入开销。

---

## 9. Git 开发工作流

### 9.1 分支模型

```
origin/main (上游 fork)
     │
     ├── 不定期 pull 上游更新
     │
     ▼
  main (本地，跟踪上游 + 构建修复)
     │
     ├── merge 上游更新后同步
     │
     ▼
  stable (稳定开发分支，承载二次开发代码)
     │
     ├── feat/xxx (功能分支)
     ├── fix/xxx  (修复分支)
     └── ...
```

### 9.2 同步上游流程

```bash
# 1. 拉取上游
git checkout main
git fetch origin
git merge origin/main

# 2. 编译验证
ENABLE_FLASH=yes make -j$(nproc) ...

# 3. 同步到开发分支
git checkout stable
git merge main
```

---

## 10. 性能特征

| 指标 | 数值 |
|------|------|
| 内存访问延迟 | ~ns 级 |
| FLASH 读取延迟 (RocksDB) | ~μs-ms 级 (取决于 SSD) |
| FLASH 写入延迟 | ~μs 级 (WAL) + 后台 compaction |
| RocksDB SST 文件 | 默认 64MB 一个 |
| 单节点内存占用 (1025 keys) | ~9MB |
| Docker 镜像大小 | ~246MB |

---

## 11. 文件清单

```
KeyDB/                          # 项目根目录
├── src/
│   ├── IStorage.h              # 存储抽象接口
│   ├── StorageCache.cpp/.h     # FLASH 缓存层
│   ├── config.cpp              # 配置项注册 (FLASH 参数)
│   ├── server.cpp/.h           # 主服务器逻辑
│   ├── storage/
│   │   ├── rocksdb.h/.cpp      # RocksDB 存储提供者实现
│   │   ├── rocksdbfactory.h/.cpp  # RocksDB 工厂 (DB 生命周期)
│   │   ├── rocksdbfactor_internal.h
│   │   └── teststorageprovider.*   # 测试用存储提供者
│   └── ...
├── deps/
│   ├── Makefile                # ⚡ 修改: EXTRA_CXXFLAGS="-include cstdint"
│   └── rocksdb/                # ⚡ submodule: v7.10.2 + cstdint 修复
├── docker/
│   ├── DESIGN.md               # 本文档
│   ├── Dockerfile              # 镜像构建
│   ├── docker-compose.yml      # 1 Master + 2 Replicas
│   └── conf/
│       ├── keydb-master.conf   # Master 配置
│       └── keydb-replica.conf  # Replica 配置
├── keydb.conf                  # 默认配置参考
└── Makefile                    # 顶层 Makefile (委托 src/)
```
