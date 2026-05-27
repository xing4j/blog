# Redis 持久化：RDB 与 AOF 的原理、对比与生产选型

<div class="post-meta">📅 2025-02-23 &nbsp;·&nbsp; 🏷️ <span class="tag">数据库</span></div>

Redis 重启后数据全没了——这是只把 Redis 当纯缓存用时可以接受的，但用 Redis 做消息队列或存储关键业务数据时，持久化配置直接关系到数据安全。RDB 快、AOF 全、混合模式两全其美，但每种都有适合的场景和需要避开的坑。

---

## 一、背景：Redis 为什么需要持久化

Redis 是内存数据库，进程退出或宕机后内存数据消失。持久化将内存数据写入磁盘，重启后恢复，确保：
- **数据不丢失**（AOF）
- **快速重启**（RDB）

Redis 提供两种持久化机制，可以单独使用，也可以同时开启。

---

## 二、RDB（Redis Database）：快照持久化

### 工作原理

RDB 是将某一时刻的内存数据完整**快照**写入磁盘文件（.rdb）：

```
Redis 进程
    v fork() 子进程（写时复制 COW）
子进程：将内存数据序列化写入 temp.rdb
主进程：继续处理请求（不阻塞）
子进程完成：原子替换 dump.rdb
```
**写时复制（COW）**：fork 之后父子进程共享内存页，只有在父进程修改某页数据时，才复制该页给子进程，子进程始终写的是 fork 时的快照。

### 触发方式

`conf
# redis.conf 配置
# 900秒内至少1次写操作，触发 RDB
save 900 1
# 300秒内至少10次写操作
save 300 10
# 60秒内至少10000次写操作
save 60 10000

# 手动触发
BGSAVE   # 后台异步保存（推荐）
SAVE     # 同步保存（阻塞主线程！生产禁止）
```
### RDB 文件结构

```
REDIS  0011  FA ... FC ... FE db0 ... FF checksum
 标识  版本  辅助字段  过期时间  DB索引  KV数据  校验和
```
RDB 是二进制格式，文件小，加载速度快。

---

## 三、AOF（Append Only File）：追加日志

### 工作原理

AOF 将每条**写命令**追加到日志文件，重启时通过重放日志恢复数据：

```
客户端 SET key value
    ↓
命令写入 AOF 缓冲区（aof_buf）
    ↓ 根据 fsync 策略刷盘
appendonly.aof
    ↓ 重启时
顺序重放所有命令 → 恢复内存数据
```
### fsync 策略（数据安全 vs 性能的权衡）

`conf
# appendfsync 配置
appendfsync always       # 每条命令都 fsync（最安全，性能最差）
appendfsync everysec     # 每秒 fsync（推荐，最多丢 1 秒数据）
appendfsync no           # 由 OS 决定（最快，可能丢较多数据）
```
### AOF 重写（防止文件无限增长）

随着时间推移，AOF 文件越来越大（同一个 key 可能被修改了 1000 次）。AOF 重写通过遍历内存数据，生成最小的等效命令集：

```
原始 AOF（1000行）：
SET counter 1
INCR counter
INCR counter
... (997次 INCR)

重写后 AOF（1行）：
SET counter 1000
```
`conf
# 自动触发 AOF 重写的条件
auto-aof-rewrite-percentage 100   # AOF 文件大小比上次重写后增长了 100%
auto-aof-rewrite-min-size 64mb    # 且 AOF 文件至少 64MB

# 手动触发
BGREWRITEAOF
```
---

## 四、混合持久化（Redis 4.0+，推荐）

结合 RDB 和 AOF 的优点：AOF 重写时，将 RDB 快照内容写入 AOF 文件头，后续增量操作以 AOF 格式追加：

```
appendonly.aof 文件结构：
[RDB 格式快照数据][AOF 格式增量命令]
```
**优势**：
- 重启时先加载 RDB 快照（快），再重放后续 AOF 增量命令（少）
- 兼顾了 RDB 的快速加载和 AOF 的数据完整性

`conf
# 开启混合持久化（需要 AOF 同时开启）
aof-use-rdb-preamble yes
```
---

## 五、RDB vs AOF 对比

| 特性 | RDB | AOF | 混合（推荐）|
|------|-----|-----|------------|
| 数据安全性 | 低（快照间隔内数据丢失）| 高（最多丢 1s）| 高 |
| 重启恢复速度 | ⭐⭐⭐⭐⭐（加载快）| ⭐⭐（重放慢）| ⭐⭐⭐⭐（快）|
| 文件大小 | 小（二进制压缩）| 大（文本日志）| 中 |
| 写性能影响 | 低（fork 异步）| 中（每秒 fsync）| 中 |
| 适用场景 | 容忍数据丢失的缓存 | 关键数据存储 | 大多数生产场景 |

---

## 六、生产配置推荐

### 纯缓存场景（允许数据丢失）

`conf
save ""                     # 禁用 RDB 自动保存
appendonly no               # 禁用 AOF
# 重启后缓存冷启动，从 DB 重新加载
```
### 关键数据存储（不允许数据丢失）

`conf
save ""                     # 禁用定时 RDB（保留 BGSAVE 按需备份）
appendonly yes
appendfsync everysec        # 每秒 fsync，平衡性能和安全
aof-use-rdb-preamble yes    # 开启混合持久化
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
```
### 灾备场景（保留 RDB 备份）

`conf
save 3600 1                 # 每小时至少 1 次写，触发 RDB 备份
appendonly yes
aof-use-rdb-preamble yes
```
---

## 七、常见坑点与最佳实践

### 坑 1：SAVE 命令阻塞主线程

```bash
# ❌ SAVE 是同步操作，执行期间 Redis 不响应任何请求
redis-cli SAVE

# ✅ 使用 BGSAVE（后台异步）
redis-cli BGSAVE
```
### 坑 2：fork 时内存不足导致 BGSAVE 失败

`conf
# Linux 默认 overcommit_memory = 0，fork 时检查内存是否足够
# 当 Redis 内存 > 物理内存 / 2 时，BGSAVE 可能失败
# ✅ 修改系统参数
vm.overcommit_memory = 1  # /etc/sysctl.conf
```
### 坑 3：AOF 文件损坏导致 Redis 无法启动

```bash
# ✅ 使用修复工具（会截断到最后一个完整命令）
redis-check-aof --fix appendonly.aof
```
---

## 八、总结与延伸

**核心要点**：
- RDB：快照，文件小，重启快，但可能丢失快照间隔内的数据
- AOF：追加日志，数据更安全（最多丢 1 秒），但文件大，重启慢
- **混合持久化（aof-use-rdb-preamble yes）是生产首选**，兼顾两者优点
- BGSAVE 利用 fork + COW 异步保存，不阻塞主线程

**延伸阅读方向**：
- Redis Cluster 数据分片：持久化在集群模式下的配置差异
- Redis 主从复制：从节点恢复时用 RDB 全量同步 + AOF 增量同步
- Redis 内存优化：maxmemory-policy 淘汰策略与持久化的协同
- 阿里云 Redis 企业版：云上 Redis 持久化的最佳实践
