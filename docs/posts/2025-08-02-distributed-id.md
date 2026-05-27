# 分布式 ID 的原理与选型：从雪花算法到美团 Leaf

<div class="post-meta">📅 2025-08-02 &nbsp;·&nbsp; 🏷️ <span class="tag">分布式</span> <span class="tag">架构设计</span></div>

微服务拆分后，数据库自增主键的方案彻底失效了。订单服务、库存服务各自有独立的 MySQL 实例，自增 ID 必然重复——如何生成全局唯一的业务 ID，是每个做微服务的团队必须解决的基础问题。

本文系统梳理六种主流方案，深度剖析雪花算法的 bit layout 和时钟回拨处理，以及美团 Leaf 双 buffer 号段模式的工程实现，并给出实用选型决策树。

---

## 一、分布式 ID 的设计要求

| 要求 | 说明 | 违反后果 |
|------|------|---------|
| **全局唯一** | 跨库、跨服务不重复 | 数据覆盖、主键冲突 |
| **趋势递增** | 大致有序（不要求严格顺序） | B+树频繁页分裂，写性能下降 |
| **高性能** | 单机 10 万+ QPS | ID 生成成为系统瓶颈 |
| **高可用** | 不依赖单点 | ID 故障导致全系统停写 |
| **长度合适** | 64 位 long，而非字符串 | 存储浪费，索引效率低 |

---

## 二、UUID：最简单但有陷阱

```java
// 标准 UUID v4（随机）
String id = UUID.randomUUID().toString(); // 550e8400-e29b-41d4-a716-446655440000（36字符）

// 去掉连字符的变种
String compact = UUID.randomUUID().toString().replace("-", ""); // 32字符
```

### 2.1 UUID 作为主键的 B+树性能问题

UUID 完全随机，作为 InnoDB 主键会导致**页分裂（Page Split）**：

```
自增 ID 总是插入最右侧叶子节点，无需移动已有数据：
  [1][2][3][4] --> 插入5 --> [1][2][3][4][5]  ✅ 追加

UUID 随机，可能插入叶子节点中间，页满时触发分裂：
  [a1][a5][b3][c2] --> 插入a3 --> 页满 --> 分裂  ⚠️
```

测试数据：500 万行表，UUID 主键的写入 TPS 约为自增 ID 的 **30-50%**，索引空间多占用 **1.5-2 倍**。

**UUID 正确使用场景**：
- 链路追踪 ID（traceId/spanId）
- 非主键的幂等 key、文件名、token
- 不做关联查询的文档标识（如 ElasticSearch ID）

---

## 三、雪花算法（Snowflake）

Twitter 2010 年开源的 64 位 ID 生成算法：

```
 bit 0    bit 1~41              bit 42~51       bit 52~63
+------+----------------------+---------------+------------+
|  0   |  41-bit Timestamp(ms)| 10-bit NodeID | 12-bit Seq |
|Sign  |Relative epoch, ~69yr | DC(5)+Work(5) | 4096 per ms|
+------+----------------------+---------------+------------+
```

### 3.1 完整实现

```java
public class Snowflake {
    private static final long EPOCH          = 1577836800000L; // 2020-01-01
    private static final long WORKER_BITS    = 5L;
    private static final long DC_BITS        = 5L;
    private static final long SEQUENCE_BITS  = 12L;

    private static final long MAX_WORKER_ID  = ~(-1L << WORKER_BITS);   // 31
    private static final long MAX_DC_ID      = ~(-1L << DC_BITS);        // 31
    private static final long SEQUENCE_MASK  = ~(-1L << SEQUENCE_BITS); // 4095

    private static final long WORKER_SHIFT   = SEQUENCE_BITS;            // 12
    private static final long DC_SHIFT       = SEQUENCE_BITS + WORKER_BITS; // 17
    private static final long TIMESTAMP_SHIFT = SEQUENCE_BITS + WORKER_BITS + DC_BITS; // 22

    private final long workerId;
    private final long datacenterId;
    private long sequence     = 0L;
    private long lastTimestamp = -1L;

    public Snowflake(long workerId, long datacenterId) {
        if (workerId > MAX_WORKER_ID || workerId < 0)
            throw new IllegalArgumentException("workerId 超出范围 [0, " + MAX_WORKER_ID + "]");
        this.workerId     = workerId;
        this.datacenterId = datacenterId;
    }

    public synchronized long nextId() {
        long ts = System.currentTimeMillis();
        if (ts < lastTimestamp) {
            long offset = lastTimestamp - ts;
            if (offset <= 5) {
                try {
                    Thread.sleep(offset * 2); // 容忍 5ms 内的时钟回拨
                    ts = System.currentTimeMillis();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new RuntimeException("时钟等待被中断", e);
                }
                if (ts < lastTimestamp)
                    throw new RuntimeException("时钟回拨超出容忍范围：" + offset + "ms");
            } else {
                throw new RuntimeException("时钟回拨过大：" + offset + "ms，拒绝生成 ID");
            }
        }
        if (ts == lastTimestamp) {
            sequence = (sequence + 1) & SEQUENCE_MASK;
            if (sequence == 0) {
                do { ts = System.currentTimeMillis(); } while (ts <= lastTimestamp);
            }
        } else {
            sequence = 0L;
        }
        lastTimestamp = ts;
        return ((ts - EPOCH) << TIMESTAMP_SHIFT)
             | (datacenterId << DC_SHIFT)
             | (workerId     << WORKER_SHIFT)
             | sequence;
    }
}
```

### 3.2 时钟回拨问题

触发场景：NTP 同步调整时间、K8s Pod 迁移到时钟不一致的节点、VM Checkpoint 恢复。

```
T=1000ms 生成 ID: [1000ms][worker1][seq=5]
NTP 调整 --> 当前时间变为 T=997ms
T=997ms  生成 ID: [997ms][worker1][seq=0]  <- 与之前 [997ms] 的 ID 可能重复！
```

**生产级解决方案（百度 UidGenerator）**：将时间戳改为 28 位秒级，workerId 由 DB 自动分配（22 位，支持 400 万节点），每次 JVM 启动重新申请 workerId，从根本上消除重复风险。

### 3.3 K8s 下 workerId 分配

```java
// 方案1：StatefulSet + Hostname（推荐，Pod 名如 app-0, app-1）
String hostname = System.getenv("HOSTNAME");
long workerId = Long.parseLong(hostname.substring(hostname.lastIndexOf("-") + 1));

// 方案2：DB 分配（用 IP+Port 作唯一 key，向 worker_node 表申请）
// 优点：无状态 Pod 也能用；缺点：需要 DB 可用

// 方案3：Zookeeper 临时节点（抢占 /snowflake/workers/N）
```

---

## 四、号段模式（美团 Leaf-Segment）

### 4.1 核心原理

不再每次都访问 DB，而是**批量取一段 ID 缓存在内存**：

```sql
CREATE TABLE `id_alloc` (
    `biz_tag`     VARCHAR(128) NOT NULL COMMENT '业务标识（order/user/...）',
    `max_id`      BIGINT       NOT NULL DEFAULT 1    COMMENT '当前已分配的最大 ID',
    `step`        INT          NOT NULL DEFAULT 1000 COMMENT '每次取号段长度',
    `update_time` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`biz_tag`)
) ENGINE = InnoDB;
```

```java
// 取号段（乐观锁防并发）
UPDATE id_alloc SET max_id = max_id + step WHERE biz_tag = 'order';
SELECT * FROM id_alloc WHERE biz_tag = 'order';
// 返回 max_id=2000, step=1000 -> 当前号段 [1001, 2000]，内存从 1001 顺序递增
```

### 4.2 双 Buffer 机制

单 buffer 问题：号段用完时需同步访问 DB，这瞬间所有请求等待，P99 抖动。

```
Buffer A: [1001, 2000) -- 当前使用 --> 使用到 90% 时触发
                                     v 异步预取
Buffer B: [2001, 3000) -- 后台预取 --> A 耗尽后无缝切换
```

```java
// 双 buffer 核心逻辑
public class SegmentBuffer {
    private final Segment[] segments = new Segment[2];
    private volatile int     currentPos  = 0;
    private volatile boolean nextReady   = false;

    public long nextId() {
        Segment current = segments[currentPos];
        // 使用量超过 10%（剩余不足 90%）时，触发异步预加载
        if (!nextReady && current.getIdle() < current.getStep() * 0.9) {
            loadNextAsync();
        }
        long id = current.incrementAndGet();
        if (id <= current.getMax()) {
            return id;
        }
        // 当前 buffer 耗尽，等待切换
        synchronized (this) {
            if (nextReady) {
                currentPos = (currentPos + 1) % 2;
                nextReady  = false;
                return segments[currentPos].incrementAndGet();
            }
            // 极少数情况：双 buffer 同时耗尽，同步加载
            loadSync();
            return segments[currentPos].incrementAndGet();
        }
    }
}
```
---

## 五、Redis INCR

```java
// 基础实现
Long id = redisTemplate.opsForValue().increment("id:order");

// 带日期前缀（适合订单号、流水号）
String date = LocalDate.now().format(DateTimeFormatter.ofPattern("yyyyMMdd"));
Long seq = redisTemplate.opsForValue().increment("id:order:" + date);
redisTemplate.expire("id:order:" + date, 2, TimeUnit.DAYS); // 设置过期，自动清理

String orderId = "ORD" + date + String.format("%08d", seq);
// 结果示例：ORD2026052200000001
```

**主要风险**：
- AOF `appendfsync everysec` 每秒刷盘，宕机最多丢失 1s 的计数，重启后可能生成重复 ID
- 解决：重启后在现有计数基础上加固定偏移量（如 +100000），接受 ID 不连续

---

## 六、主流方案横向对比

| 方案 | 性能 | 单调递增 | 高可用 | 外部依赖 | 复杂度 |
|------|------|---------|--------|---------|--------|
| UUID | 极高 | ❌ 随机 | ⭐⭐⭐⭐⭐ | 无 | 极低 |
| 雪花算法 | 极高 | ✅ 趋势 | ⭐⭐⭐⭐ | 机器ID协调 | 中 |
| 号段模式 | 高 | ✅ 趋势 | ⭐⭐⭐ | MySQL | 高 |
| Redis INCR | 高 | ✅ 趋势 | ⭐⭐⭐ | Redis | 低 |
| 美团 Leaf | 极高 | ✅ 趋势 | ⭐⭐⭐⭐⭐ | MySQL + 可选ZK | 高（开源组件）|
| 百度 UidGenerator | 极高 | ✅ 趋势 | ⭐⭐⭐⭐ | MySQL | 中（开源组件）|

### 选型决策树

```
需要数据库主键？
+-- 否（traceId/幂等key/token）-> UUID ✅
+-- 是
    +-- 中小项目，快速实现，可接受 Redis 风险？-> Redis INCR
    +-- 需要业务前缀（ORD20260522...）？       -> 号段模式（美团 Leaf）
    +-- 高并发 + K8s StatefulSet？              -> 雪花算法（取 Pod 序号为 workerId）
    +-- 高并发 + 无状态 Pod，不想维护 workerId？-> 百度 UidGenerator（DB 自动分配）
```

---

## 七、生产实践：百度 UidGenerator 集成

百度 UidGenerator 通过 DB 自动分配 workerId，每次 JVM 启动分配新 ID，彻底解决 K8s 下的 workerId 协调问题：

```sql
-- 每次 JVM 启动，自动向此表插入一条记录，返回的自增 ID 即为 workerId
CREATE TABLE `WORKER_NODE` (
    `ID`          BIGINT       NOT NULL AUTO_INCREMENT COMMENT 'auto increment id',
    `HOST_NAME`   VARCHAR(64)  NOT NULL COMMENT 'host name',
    `PORT`        VARCHAR(64)  NOT NULL COMMENT 'port',
    `TYPE`        INT(11)      NOT NULL COMMENT '0:CONTAINER 1:ACTUAL 2:FAKE',
    `LAUNCH_DATE` DATE         NOT NULL COMMENT 'launch date',
    `MODIFIED`    TIMESTAMP    NOT NULL,
    `CREATED`     TIMESTAMP    NOT NULL,
    PRIMARY KEY(`ID`)
) CHARSET=utf8mb4 COMMENT='DB WorkerID Assigner';
```

```java
@Autowired
private UidGenerator uidGenerator; // DefaultUidGenerator 或 CachedUidGenerator

public long generateId() {
    return uidGenerator.getUID();
}
// CachedUidGenerator 预生成一批 UID 放入 RingBuffer，消费速度可达 600 万/s
```

**workerId 利用率说明**：UidGenerator 将 Snowflake 的 10bit workerId 扩展到 22bit（支持 400 万节点），时间戳从 41bit 毫秒级改为 28bit 秒级（可用 8.7 年，可配置），序列号保持 13bit（每秒 8192 个）。

---

## 八、总结与延伸

**核心要点**：
1. **趋势递增优于随机**：UUID 作为 InnoDB 主键的 B+树页分裂会导致写入 TPS 下降 30-50%
2. **雪花算法**是大多数场景的最优解，关键是解决 K8s 下 workerId 分配和时钟回拨问题
3. **号段模式 + 双 buffer** 通过内存预取消除 DB 访问的 RT 抖动，适合需要业务前缀的可读 ID
4. **Redis INCR** 简单易用，但需要处理宕机后计数丢失导致重复 ID 的风险

**延伸阅读**：
- [美团 Leaf 开源](https://github.com/Meituan-Dianping/Leaf) — 号段模式 + 雪花模式双支持，生产可用
- [百度 UidGenerator](https://github.com/baidu/uid-generator) — 解决 workerId 分配问题的雪花变种
- MySQL InnoDB 技术内幕 — B+树页分裂机制（理解 UUID 主键的性能代价）
- [Seata 分布式事务](./2025-01-11-seata-distributed-transaction.md) — 分布式环境下 ID 生成与事务的配合
