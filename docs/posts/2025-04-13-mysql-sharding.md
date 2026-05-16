# MySQL 分库分表方案选型与实践

<div class="post-meta">📅 2025-04-13 &nbsp;·&nbsp; 🏷️ <span class="tag">MySQL</span> <span class="tag">分布式</span></div>

## 一、何时需要分库分表？

| 指标 | 警戒线 | 说明 |
|------|-------|------|
| 单表行数 | > 1000 万 | 索引树层高增加，查询变慢 |
| 单表数据量 | > 10 GB | 备份/恢复耗时长 |
| 单库 QPS | > 5000 | 单实例 CPU/IO 成为瓶颈 |
| 单库连接数 | > 1000 | 连接池竞争激烈 |

**先考虑的优化手段（优先于分库分表）：**
1. 索引优化
2. 读写分离
3. 缓存（Redis）
4. 归档历史数据
5. 分区表（PARTITION）

## 二、垂直拆分 vs 水平拆分

### 2.1 垂直拆分

**垂直分库**：按业务模块将不同表拆分到不同数据库。

```
单体数据库:                    垂直分库后:
┌─────────────────┐           ┌──────────┐  ┌──────────┐  ┌──────────┐
│ users           │           │  用户库   │  │  订单库   │  │  商品库   │
│ orders          │   ──→     │  users   │  │  orders  │  │ products │
│ products        │           │  address │  │  items   │  │ category │
│ order_items     │           └──────────┘  └──────────┘  └──────────┘
│ addresses       │
└─────────────────┘
```

**垂直分表**：将宽表按列拆分（常用列 + 大字段/不常用列）。

```sql
-- 原表：user (id, name, email, avatar, bio, settings, created_at)
-- 拆分为：
-- user_base  (id, name, email, created_at)   -- 频繁查询
-- user_extra (id, avatar, bio, settings)     -- 偶尔访问
```

| 特性 | 垂直分库 | 垂直分表 |
|------|---------|---------|
| 拆分维度 | 按业务模块（表） | 按列（冷热数据） |
| 解决问题 | 跨业务耦合 | 单表列过多、大字段 |
| 跨库 JOIN | 需要 | 不需要 |

### 2.2 水平拆分

**水平分表**：同一张表数据按规则分散到多张结构相同的表。

```
orders 表数据量过大：
orders_0  → user_id % 4 = 0 的订单
orders_1  → user_id % 4 = 1 的订单
orders_2  → user_id % 4 = 2 的订单
orders_3  → user_id % 4 = 3 的订单
```

## 三、分片键选择原则

分片键（Sharding Key）是决定数据去哪个分片的关键字段。

### 3.1 选择原则

| 原则 | 说明 |
|------|------|
| 区分度高 | 数据均匀分布，避免热点 |
| 查询覆盖 | 大多数查询条件都包含分片键 |
| 值稳定 | 一旦确定后不应变更 |
| 不可为空 | 分片键不能是 NULL |

### 3.2 常见分片策略

```java
// 1. 取模分片（范围查询差）
int shardIndex = userId % shardCount;

// 2. 范围分片（容易热点）
// [1, 1000000)  → shard_0
// [1000000, 2000000) → shard_1

// 3. 哈希分片（均匀，范围查询差）
int shardIndex = Math.abs(userId.hashCode()) % shardCount;

// 4. 一致性哈希（扩容友好）
// 虚拟节点 + 哈希环
```

## 四、ShardingSphere 实战配置

### 4.1 Maven 依赖

```xml
<dependency>
    <groupId>org.apache.shardingsphere</groupId>
    <artifactId>shardingsphere-jdbc-core-spring-boot-starter</artifactId>
    <version>5.3.2</version>
</dependency>
```

### 4.2 application.yml 配置

```yaml
spring:
  shardingsphere:
    datasource:
      names: ds0, ds1
      ds0:
        type: com.zaxxer.hikari.HikariDataSource
        driver-class-name: com.mysql.cj.jdbc.Driver
        jdbc-url: jdbc:mysql://localhost:3306/order_db_0
        username: root
        password: secret
      ds1:
        type: com.zaxxer.hikari.HikariDataSource
        driver-class-name: com.mysql.cj.jdbc.Driver
        jdbc-url: jdbc:mysql://localhost:3306/order_db_1
        username: root
        password: secret
    rules:
      sharding:
        tables:
          orders:
            actual-data-nodes: ds${0..1}.orders_${0..3}
            # 分库策略：按 user_id 取模
            database-strategy:
              standard:
                sharding-column: user_id
                sharding-algorithm-name: db-inline
            # 分表策略：按 order_id 取模
            table-strategy:
              standard:
                sharding-column: order_id
                sharding-algorithm-name: table-inline
            # 分布式主键
            key-generate-strategy:
              column: order_id
              key-generator-name: snowflake
        sharding-algorithms:
          db-inline:
            type: INLINE
            props:
              algorithm-expression: ds${user_id % 2}
          table-inline:
            type: INLINE
            props:
              algorithm-expression: orders_${order_id % 4}
        key-generators:
          snowflake:
            type: SNOWFLAKE
    props:
      sql-show: true
```

### 4.3 代码示例

```java
@Service
public class OrderService {

    @Autowired
    private OrderMapper orderMapper;

    public void createOrder(Order order) {
        // ShardingSphere 自动路由到正确的库和表
        // 无需修改业务代码
        orderMapper.insert(order);
    }

    public Order getOrder(Long orderId, Long userId) {
        // 包含分片键，精准路由
        return orderMapper.findByOrderIdAndUserId(orderId, userId);
    }
}
```

## 五、跨库分页与排序问题

### 5.1 问题描述

```sql
-- 分 4 张表后，这条 SQL 无法直接执行
SELECT * FROM orders ORDER BY create_time DESC LIMIT 10 OFFSET 100;
-- ShardingSphere 实际执行：在每个分表执行 LIMIT 110，然后归并
-- 数据量越大，性能越差
```

### 5.2 解决方案

**方案一：禁止深度分页 + 游标分页**

```java
// 前端传入上次最大的 create_time 和 order_id
public List<Order> getOrders(Long userId, LocalDateTime lastTime, Long lastId, int size) {
    return orderMapper.selectByUserIdWithCursor(userId, lastTime, lastId, size);
}
```

```xml
<select id="selectByUserIdWithCursor" resultType="Order">
    SELECT * FROM orders
    WHERE user_id = #{userId}
      AND (create_time, order_id) &lt; (#{lastTime}, #{lastId})
    ORDER BY create_time DESC, order_id DESC
    LIMIT #{size}
</select>
```

**方案二：ES + MySQL 双写**

```
写入：同时写 MySQL 分库分表 + ElasticSearch
查询分页：ES 负责分页、排序、全文搜索
数据获取：ES 返回 id 列表，MySQL 按 id 批量查询完整数据
```

| 方案 | 适用场景 | 缺点 |
|------|---------|------|
| 游标分页 | 无需跳页的瀑布流 | 不支持跳页 |
| ES 分页 | 复杂查询、全文搜索 | 维护双写一致性 |
| 内存归并 | 数据量小 | 性能差 |

## 六、跨库 JOIN 方案

```sql
-- ❌ 跨库 JOIN 不可用
SELECT u.name, o.total
FROM user_db.users u
JOIN order_db.orders o ON u.id = o.user_id;
```

### 解决方案

**方案一：字段冗余**

```sql
-- 在 orders 表冗余 user_name 字段，避免 JOIN
CREATE TABLE orders (
    order_id   BIGINT PRIMARY KEY,
    user_id    BIGINT,
    user_name  VARCHAR(50),  -- 冗余字段
    total      DECIMAL(10,2),
    ...
);
```

**方案二：全局表（广播表）**

```yaml
# ShardingSphere 广播表配置（在所有分库都保存完整数据）
broadcast-tables:
  - t_dict_item    # 数据字典，数据量小且频繁 JOIN
  - t_province     # 省市区表
```

**方案三：应用层 JOIN**

```java
// 先查 A 库数据，拿到 id 列表，再查 B 库
List<Order> orders = orderMapper.findByUserId(userId);
List<Long> productIds = orders.stream()
    .map(Order::getProductId).collect(Collectors.toList());
List<Product> products = productMapper.findByIds(productIds);
// 应用层拼装
```

## 七、扩容迁移方案

### 7.1 不停机迁移流程（双写方案）

```
阶段1：双写新旧两套分表
  写操作 → 同时写旧表（4张）和新表（8张）
  读操作 → 读旧表

阶段2：数据迁移
  将旧表存量数据迁移到新表
  迁移工具：Canal + 自定义消费者

阶段3：数据校验
  对比新旧表数据一致性
  diff 工具检查

阶段4：读切换
  读操作切换到新表
  观察 1~2 天

阶段5：写切换
  停止双写，只写新表

阶段6：旧表下线
  备份后删除旧表
```

### 7.2 扩容规划建议

| 初始分片数 | 建议 |
|-----------|------|
| 分片数用 2^n | 便于后续翻倍扩容 |
| 预留 2 倍空间 | 初期 4 片，后续扩到 8、16 |
| 优先垂直扩容 | 升级机器配置比分库分表简单 |

## 八、分库分表常见问题

| 问题 | 解决方案 |
|------|---------|
| 分布式主键 | Snowflake / Leaf / 号段模式 |
| 全局唯一序列 | 独立序列服务 |
| 跨库事务 | Seata AT/TCC 模式 |
| 数据倾斜（热点） | 加随机后缀打散 |
| 扩容迁移 | 双写 + 数据迁移 + 切流 |
| 跨库分页排序 | 游标分页 / ES |
| 跨库聚合统计 | 大数据（Flink/Spark）离线计算 |
