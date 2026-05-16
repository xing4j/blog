# Redis 持久化：RDB vs AOF 选型指南

<div class="post-meta">📅 2025-02-23 &nbsp;·&nbsp; 🏷️ <span class="tag">Redis</span></div>

## 一、持久化概述

Redis 是内存数据库，持久化机制用于将数据保存到磁盘，防止重启后数据丢失。

| 持久化方式 | 全称 | 机制 | 文件 |
|-----------|------|------|------|
| RDB | Redis Database Backup | 快照（Snapshot） | dump.rdb |
| AOF | Append Only File | 记录每条写命令 | appendonly.aof |
| 混合持久化 | RDB + AOF | Redis 4.0+ | appendonly.aof |

## 二、RDB（快照持久化）

### 2.1 工作原理

```
bgsave 触发流程：
                                    
Redis 主进程                 子进程（fork）
    │                            │
    ├─── fork() ──────────────→  │
    │                            ├── 遍历内存中所有数据
    │  继续处理请求                ├── 将快照写入临时文件 temp.rdb
    │  （COW：写时复制）            ├── 完成后替换 dump.rdb
    │                            └── 子进程退出
    ↓
    
写时复制（Copy-On-Write）：
fork 后，父子进程共享内存页
当父进程修改某内存页时，OS 复制该页给父进程使用
子进程仍然访问原始页 → 保证快照一致性
```

### 2.2 触发方式

```bash
# 方式1：手动触发（阻塞）
SAVE          # 同步执行，阻塞 Redis，不推荐生产使用

# 方式2：手动触发（非阻塞，推荐）
BGSAVE        # 后台执行，不阻塞

# 方式3：配置自动触发（redis.conf）
save 900 1      # 900秒内有1次写操作 → 触发
save 300 10     # 300秒内有10次写操作 → 触发
save 60 10000   # 60秒内有10000次写操作 → 触发

# 关闭 RDB
save ""

# 方式4：SHUTDOWN 时自动触发
SHUTDOWN SAVE    # 关闭时保存

# 方式5：主从复制时，主节点自动触发 BGSAVE
```

### 2.3 RDB 配置详解

```bash
# redis.conf
dir /var/lib/redis          # RDB 文件存放目录
dbfilename dump.rdb         # 文件名

# RDB 压缩（压缩 string 对象，默认开启）
rdbcompression yes

# RDB 文件校验（增加约 10% 保存/加载时间）
rdbchecksum yes

# 上次 bgsave 失败时，拒绝写操作（防止数据不一致）
stop-writes-on-bgsave-error yes
```

### 2.4 RDB 优缺点

| 特性 | 说明 |
|------|------|
| ✅ 文件紧凑 | 二进制格式，体积小，传输快 |
| ✅ 恢复速度快 | 直接加载内存镜像，比 AOF 快 |
| ✅ 对性能影响小 | fork 后子进程负责，主进程不阻塞 |
| ❌ 数据丢失 | 两次快照之间的数据丢失 |
| ❌ fork 耗时 | 数据量大时 fork 本身可能耗秒级 |
| ❌ 不适合实时 | 无法做到实时/秒级持久化 |

## 三、AOF（追加日志持久化）

### 3.1 工作原理

```
AOF 写入流程：

Redis 执行写命令
      ↓
将命令追加到 AOF 缓冲区（aof_buf）
      ↓
根据 fsync 策略，将 aof_buf 刷入磁盘
      ↓
appendonly.aof 文件增长

AOF 文件内容（文本格式，Redis 序列化协议 RESP）：
*3          ← 命令有3个参数
$3          ← 参数1长度3
SET
$4          ← 参数2长度4
name
$5          ← 参数3长度5
Alice
```

### 3.2 三种 fsync 策略

```bash
# redis.conf
appendfsync always    # 每次写命令都 fsync → 最安全，最慢
appendfsync everysec  # 每秒 fsync 一次 → 推荐，最多丢失1秒数据
appendfsync no        # 由 OS 决定何时 fsync → 最快，但不可控
```

| 策略 | 数据丢失 | 写入性能 | 适用场景 |
|------|---------|---------|---------|
| always | 0（最安全） | 最低（每次 fsync） | 金融/支付场景 |
| everysec | 最多 1 秒 | 高（推荐） | 大多数业务场景 |
| no | 取决于 OS | 最高 | 性能优先场景 |

### 3.3 AOF 重写（Rewrite）

随着运行时间增长，AOF 文件会越来越大，重写可以压缩文件体积：

```
重写原理：
原始 AOF（记录所有命令）：
  SET counter 1
  INCR counter
  INCR counter
  INCR counter
  ...（100次）

重写后 AOF（只保留最终状态）：
  SET counter 100
  
重写比例：减少 90% 文件大小
```

```bash
# 手动触发重写
BGREWRITEAOF

# 自动触发配置
auto-aof-rewrite-percentage 100   # 当 AOF 比上次重写大 100% 时触发
auto-aof-rewrite-min-size 64mb    # 最小 64MB 才触发重写（防止小文件频繁重写）
```

**重写流程：**

```
主进程 fork 子进程
        ↓
子进程将当前内存快照写入新 AOF 文件
        ↓
主进程将重写期间新增命令写入 aof_rewrite_buf
        ↓
子进程完成 → 将 aof_rewrite_buf 追加到新文件
        ↓
原子替换旧 AOF 文件
```

### 3.4 AOF 优缺点

| 特性 | 说明 |
|------|------|
| ✅ 数据安全 | everysec 最多丢失 1 秒数据 |
| ✅ 可读性强 | 文本格式，方便人工排查和回放 |
| ✅ 支持修改 | 手动删除 AOF 中误操作命令后恢复 |
| ❌ 文件较大 | 记录每条命令，体积比 RDB 大 |
| ❌ 恢复慢 | 需要重放所有命令，比 RDB 慢 |
| ❌ 历史版本兼容 | 不同 Redis 版本 AOF 格式可能不同 |

## 四、混合持久化（Redis 4.0+）

```bash
# 开启混合持久化（需同时开启 AOF）
aof-use-rdb-preamble yes    # redis.conf
appendonly yes
```

**混合持久化文件结构：**

```
appendonly.aof 文件内容：

┌────────────────────────────┐
│   RDB 格式快照部分          │  ← BGREWRITEAOF 时生成
│  （包含重写时的全量数据）    │     二进制，紧凑
├────────────────────────────┤
│   AOF 格式增量日志          │  ← 重写完成后新增的写命令
│  （重写后的增量命令）        │     文本格式
└────────────────────────────┘
```

**优势：**

| 特性 | 纯 RDB | 纯 AOF | 混合持久化 |
|------|-------|-------|-----------|
| 恢复速度 | 最快 | 慢 | 快（接近 RDB） |
| 数据丢失 | 多（两次快照间） | 少（≤1s） | 少（≤1s） |
| 文件大小 | 小 | 大 | 中 |

## 五、数据恢复优先级

```
Redis 启动时恢复顺序：

1. 如果只有 RDB 文件 → 加载 dump.rdb
2. 如果只有 AOF 文件 → 加载 appendonly.aof
3. 如果两者都有 → 优先加载 AOF（数据更完整）
4. 混合持久化 → 加载 appendonly.aof（前半部分 RDB + 后半部分 AOF）
```

```bash
# 手动恢复步骤

# 1. 检查 AOF 文件完整性（如发生异常关闭）
redis-check-aof --fix appendonly.aof

# 2. 检查 RDB 文件完整性
redis-check-rdb dump.rdb

# 3. 复制文件到 Redis data 目录
cp dump.rdb /var/lib/redis/
cp appendonly.aof /var/lib/redis/

# 4. 启动 Redis
redis-server /etc/redis/redis.conf
```

## 六、性能影响分析

### 6.1 RDB 对性能的影响

```bash
# 监控 fork 耗时
INFO stats | grep latest_fork_usec
# latest_fork_usec:1500  ← 1.5ms，可接受

# 大内存实例 fork 耗时可能达到 1~2s
# 建议：单实例内存不超过 10GB
# 或使用 Linux 大页面关闭：echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

### 6.2 AOF 对性能的影响

```bash
# 查看 AOF 状态
INFO persistence
# aof_enabled:1
# aof_rewrite_in_progress:0
# aof_current_size:1048576     ← 当前文件大小
# aof_base_size:524288          ← 上次重写后大小

# 监控 AOF 延迟
redis-cli --latency -h 127.0.0.1 -p 6379
```

## 七、选型建议

| 场景 | 推荐方案 | 配置 |
|------|---------|------|
| 缓存，允许丢失 | 不开持久化 | `save ""; appendonly no` |
| 数据重要，可接受少量丢失 | RDB + AOF（混合） | 混合持久化 |
| 数据极其重要 | AOF always | `appendfsync always` |
| 内存大、快速恢复优先 | RDB | 配合从节点做 AOF |
| 生产环境通用 | **混合持久化** | `aof-use-rdb-preamble yes` |

```bash
# 生产推荐配置（redis.conf）

# 开启 AOF
appendonly yes
appendfilename "appendonly.aof"

# everysec 策略（性能与安全均衡）
appendfsync everysec

# 开启混合持久化
aof-use-rdb-preamble yes

# AOF 重写触发条件
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# RDB 配置（保留作为额外备份）
save 3600 1
save 300 100
save 60 10000
dbfilename dump.rdb
dir /var/lib/redis

# 避免 AOF 重写时影响性能
no-appendfsync-on-rewrite yes
```

## 八、备份策略建议

```bash
# 定时备份 RDB 脚本
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=/backup/redis

redis-cli BGSAVE
sleep 5
cp /var/lib/redis/dump.rdb $BACKUP_DIR/dump_$DATE.rdb

# 保留最近 7 天
find $BACKUP_DIR -name "dump_*.rdb" -mtime +7 -delete
```
