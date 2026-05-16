# 分布式 ID 方案对比：雪花算法 / 号段模式 / UUID

<div class="post-meta">📅 2025-08-02 &nbsp;·&nbsp; 🏷️ <span class="tag">分布式</span> <span class="tag">架构</span></div>

分布式系统中，全局唯一 ID 的生成是基础能力。本文对比主流方案的原理、优缺点和适用场景。

---

## 一、UUID

```java
String id = UUID.randomUUID().toString(); // 550e8400-e29b-41d4-a716-446655440000
```

| 优点 | 缺点 |
|------|------|
| 无需中心节点，本地生成 | 36 字符，存储占用大 |
| 全球唯一 | 无序，作为主键导致 B+树频繁分裂（索引性能差）|
| 实现简单 | 无业务含义 |

**适用**：非数据库主键场景，如请求追踪 ID（traceId）。

---

## 二、雪花算法（Snowflake）

Twitter 开源的 64 位 ID 生成算法：

```
┌─────┬───────────────────────────────┬──────────┬────────────┐
│  0  │      41 位时间戳（毫秒）        │  10位机器  │  12位序列号 │
│符号位│  (69年时间范围)               │ 5+5位     │ (4096/ms)  │
└─────┴───────────────────────────────┴──────────┴────────────┘
```

```java
// Hutool 雪花算法实现
Snowflake snowflake = IdUtil.getSnowflake(workerId, datacenterId);
long id = snowflake.nextId(); // 如：1620000000000000001

// 解析 ID 中的信息（可反推生成时间）
long timestamp = snowflake.getGenerateDateTime(id);
```

| 优点 | 缺点 |
|------|------|
| 趋势递增，索引友好 | 依赖机器时钟，时钟回拨导致 ID 重复 |
| 高性能（每秒 400 万+）| 需要分配机器ID，部署复杂 |
| 包含时间戳，有业务含义 | 分布式场景需协调机器ID |

### 时钟回拨解决方案

```java
// 方案1：检测到回拨时抛异常，等待时钟追上
if (timestamp < lastTimestamp) {
    long offset = lastTimestamp - timestamp;
    if (offset <= 5) {
        Thread.sleep(offset * 2); // 等待追上
    } else {
        throw new RuntimeException("时钟回拨超过5ms，拒绝生成ID");
    }
}

// 方案2：使用 workerBits 的高位作为时钟回拨标记位（百度 UidGenerator 方案）
```

---

## 三、号段模式（Leaf-segment）

美团 Leaf 号段模式：从数据库批量取一段 ID 缓存在内存中。

```sql
CREATE TABLE `id_generator` (
    `biz_tag`     VARCHAR(128) NOT NULL,   -- 业务标识
    `max_id`      BIGINT       NOT NULL DEFAULT 1,  -- 当前最大ID
    `step`        INT          NOT NULL DEFAULT 1000, -- 每次取的号段长度
    `version`     BIGINT       NOT NULL DEFAULT 0,  -- 乐观锁
    PRIMARY KEY (`biz_tag`)
);
```

```java
// 取号段：UPDATE + 乐观锁
UPDATE id_generator 
SET max_id = max_id + step, version = version + 1
WHERE biz_tag = 'order' AND version = #{version};

// 内存中使用 [max_id - step, max_id) 范围内的 ID
// 当使用量达到 90% 时，异步预取下一个号段（双 buffer 机制）
```

```
Buffer A: [1000, 2000)  ──使用中──→ 90%时触发
Buffer B: [2000, 3000)  ──预取中──
```

| 优点 | 缺点 |
|------|------|
| 强依赖 DB 但有缓冲，性能好 | 服务重启丢失号段（浪费）|
| 趋势递增 | 号段用完时短暂阻塞（单buffer）|
| 业务含义清晰 | ID 不够随机，可猜测数量 |

---

## 四、Redis 自增

```java
// 利用 Redis INCR 的原子性
Long id = redisTemplate.opsForValue().increment("id:order");

// 带日期前缀（适合订单号）
String date = LocalDate.now().format(DateTimeFormatter.BASIC_ISO_DATE);
Long seq = redisTemplate.opsForValue().increment("id:order:" + date);
String orderId = date + String.format("%06d", seq); // 20260516000001
```

| 优点 | 缺点 |
|------|------|
| 实现简单 | Redis 宕机风险（持久化策略影响）|
| 可带业务前缀 | 单点或集群需要额外处理 |
| 趋势递增 | 不适合极高并发（Redis 性能瓶颈）|

---

## 五、主流方案横向对比

| 方案 | 性能 | 有序性 | 可用性 | 依赖 | 复杂度 |
|------|------|--------|--------|------|--------|
| UUID | ⭐⭐⭐⭐⭐ | ❌ 无序 | ⭐⭐⭐⭐⭐ | 无 | 低 |
| 雪花算法 | ⭐⭐⭐⭐⭐ | ✅ 趋势 | ⭐⭐⭐⭐ | 机器ID协调 | 中 |
| 号段模式 | ⭐⭐⭐⭐ | ✅ 趋势 | ⭐⭐⭐ | DB | 中 |
| Redis 自增 | ⭐⭐⭐⭐ | ✅ 趋势 | ⭐⭐⭐ | Redis | 低 |
| 美团 Leaf | ⭐⭐⭐⭐⭐ | ✅ 趋势 | ⭐⭐⭐⭐ | DB/ZK | 高 |

---

## 六、生产选型建议

```
追求简单 + 不做主键 → UUID
需要趋势递增 + 无中心依赖 → 雪花算法（Hutool/百度UidGenerator）
需要业务前缀 + 可读性好 → 号段模式（美团Leaf）
中小项目 + 快速实现 → Redis INCR
```

**Spring Boot 集成推荐**：使用 `uid-generator`（百度）或 `leaf`（美团），生产检验充分。

---

## 总结

- 雪花算法适合大多数场景，注意时钟回拨处理
- 号段模式 DB 依赖但双 buffer 性能不弱，适合需要可读 ID 的场景
- UUID 只适合非主键场景（traceId、幂等 key）
- 核心原则：**趋势递增** > 随机 ID（B+树索引性能）
