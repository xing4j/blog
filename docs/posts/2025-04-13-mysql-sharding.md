# MySQL 分库分表：什么时候做，怎么做，坑在哪

<div class="post-meta">📅 2025-04-13 &nbsp;·&nbsp; 🏷️ <span class="tag">数据库</span></div>

单表数据量过亿，查询越来越慢，DBA 说要"分库分表"。但这不是一个轻易的决策——分库分表带来的复杂性，往往远超预期：跨库事务、分页查询、全局 ID、数据迁移……每一个都是工程难题。本文帮你梳理清楚：什么时候分、怎么分、踩什么坑。

---

## 一、背景：什么时候才真的需要分库分表

**先做这些，再考虑分库分表**（按顺序）：

```
1. 索引优化（EXPLAIN 分析，补索引）← 大多数场景够用
2. SQL 优化（N+1、深分页、SELECT *）
3. 读写分离（主库写，从库读）← 读多写少场景
4. 冷热数据分离（历史数据归档）← 减少活跃表数据量
5. 垂直分表（大字段拆分）← 减小行宽，提升缓存效率
6. ↓ 以上都不够时，才考虑水平分库分表
```
**分库分表的触发条件**（供参考，不是硬性标准）：
- 单表数据量 > 5000 万行，且 SQL 优化已穷尽
- 写 QPS > 单库瓶颈（通常 MySQL 写 QPS 上限约 1 万~3 万 TPS）
- 数据增长速度快（如每月增长 1 亿行）

---

## 二、垂直拆分：按业务拆库

将不同业务的表拆分到不同的数据库（微服务拆分的自然结果）：

```
拆分前（单库）：            拆分后（按业务）：
┌─────────────────┐        ┌──────────┐  ┌──────────┐  ┌──────────┐
│ users           │        │  User DB  │  │ Order DB  │  │ Items DB  │
│ orders          │  →     │  users   │  │  orders  │  │  products│
│ products        │        └──────────┘  └──────────┘  └──────────┘
│ inventory       │                                    ┌──────────┐
│ payments        │                                    │  Pay DB   │
└─────────────────┘                                    │  payments│
                                                       └──────────┘
```
**优点**：业务隔离，单库压力降低
**代价**：跨库 JOIN 消失，需要业务层聚合

---

## 三、水平分表：按数据量拆分

### 3.1 分片键选择（最关键的决策）

```
分片键选择原则：
1. 高区分度：尽量均匀分布，避免数据倾斜（热点分片）
2. 查询友好：尽量让大多数查询带上分片键，避免跨分片扫描
3. 不可变：分片键一旦确定，不要修改（修改=数据迁移）
```
常见分片键：
- 用户相关业务：user_id（用户查自己的数据，不跨片）
- 订单：order_id 或 user_id（根据查询场景决定）
- 时间序列：create_time（归档友好，但时间范围查询可能跨片）

### 3.2 分片算法

```java
// 算法 1：哈希取模（分布均匀，但扩容难）
int tableIndex = userId % 16;  // 16张表
// 扩容 16→32 时，几乎所有数据都要迁移

// 算法 2：一致性哈希（扩容影响范围小）
// 将哈希空间构成环，新增节点只影响相邻节点的数据

// 算法 3：范围分片（归档友好，但容易热点）
// user_id 1~1000000 → shard_0
// user_id 1000001~2000000 → shard_1

// 算法 4：路由表（最灵活，但多一次查询）
// 维护 user_id → shard_id 的映射表（适合非均匀分布场景）
```
### 3.3 ShardingSphere 实战配置

```yaml
# application.yml（ShardingSphere-JDBC）
spring:
  shardingsphere:
    datasource:
      names: ds0, ds1
      ds0:
        url: jdbc:mysql://db0:3306/orders
      ds1:
        url: jdbc:mysql://db1:3306/orders
    rules:
      sharding:
        tables:
          orders:
            actual-data-nodes: ds.orders_  # 2库 × 8表 = 16分片
            database-strategy:
              standard:
                sharding-column: user_id
                sharding-algorithm-name: db-inline
            table-strategy:
              standard:
                sharding-column: order_id
                sharding-algorithm-name: table-inline
        sharding-algorithms:
          db-inline:
            type: INLINE
            props:
              algorithm-expression: ds
          table-inline:
            type: INLINE
            props:
              algorithm-expression: orders_
```
---

## 四、分库分表的五大难题

### 难题 1：跨库 JOIN

```sql
-- ❌ 跨库 JOIN 无法直接执行
SELECT u.name, o.amount
FROM db0.users u
JOIN db1.orders o ON u.id = o.user_id
WHERE o.status = 'paid';

-- ✅ 解法：冗余数据
-- 在 orders 表冗余 user_name 字段，避免跨库 JOIN
```
### 难题 2：分布式 ID

分库分表后，数据库自增 ID 不再唯一（各库各自自增）。需要全局唯一 ID 方案：
- **雪花算法（Snowflake）**：时间戳(41) + 机器ID(10) + 序号(12) → 64位整数
- **号段模式**：从 DB 批量申请号段（如每次申请 1000 个），本地分配

### 难题 3：分页与排序

```sql
-- ❌ 跨分片的分页无法简单下推
SELECT * FROM orders ORDER BY create_time DESC LIMIT 10 OFFSET 100;
-- 每个分片都要查 LIMIT 110，在内存中合并后再取 10 条，性能差

-- ✅ 方案 A：禁止大 OFFSET 分页，改用游标分页
-- ✅ 方案 B：ElasticSearch 存储全量索引，DB 存数据，ES 做排序分页
```
### 难题 4：跨分片事务

```java
// ❌ 跨分片的事务无法用本地事务保证
// ✅ 方案 A：Seata AT 模式（分布式事务框架）
// ✅ 方案 B：最终一致性（MQ + 本地事务消息）
// ✅ 方案 C：业务上避免跨片写（通过设计让数据在同一分片）
```
### 难题 5：数据迁移

分库分表通常在系统已有大量存量数据时进行，迁移方案：

```
双写方案（零停机迁移）：
1. 新库就绪，开启双写（同时写旧库和新库）
2. 将旧库存量数据迁移到新库
3. 核对数据一致性
4. 切流量到新库（读切换）
5. 停止旧库写入，只保留新库
```
---

## 五、总结与延伸

**核心要点**：
- 分库分表是最后手段，先穷尽索引优化、读写分离、冷热分离
- 分片键选择是核心决策，影响查询模式、数据分布和扩容难度
- 分库分表带来的复杂性：跨库 JOIN 消失、分布式 ID、跨片分页、分布式事务、数据迁移
- 生产推荐 **ShardingSphere-JDBC**（客户端分片）或 **Mycat**（代理模式）

**延伸阅读方向**：
- 雪花算法原理：时间戳 + 机器 ID + 序号的 64 位 ID 生成方案
- Seata 分布式事务：AT 模式无侵入处理跨库事务
- TiDB：NewSQL 数据库，自动分片，兼容 MySQL 协议，是分库分表的替代方案
- binlog-based 数据迁移：Canal + MQ 实现存量数据迁移与增量同步
