# MySQL 慢查询优化实战案例

<div class="post-meta">📅 2024-12-28 &nbsp;·&nbsp; 🏷️ <span class="tag">MySQL</span> <span class="tag">性能</span></div>

## 一、慢查询日志配置

### 1.1 开启慢查询日志

```sql
-- 查看当前状态
SHOW VARIABLES LIKE 'slow_query%';
SHOW VARIABLES LIKE 'long_query_time';

-- 动态开启（重启后失效）
SET GLOBAL slow_query_log = 'ON';
SET GLOBAL long_query_time = 1;          -- 超过 1 秒记录
SET GLOBAL slow_query_log_file = '/var/log/mysql/slow.log';
SET GLOBAL log_queries_not_using_indexes = 'ON';  -- 记录未走索引的查询

-- 永久配置（my.cnf）
[mysqld]
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 1
log_queries_not_using_indexes = 1
```

### 1.2 慢查询日志格式

```
# Time: 2024-05-16T10:23:45.123456Z
# User@Host: app[app] @ localhost []  Id:  1234
# Query_time: 3.456789  Lock_time: 0.000123 Rows_sent: 100  Rows_examined: 500000
SET timestamp=1715854425;
SELECT * FROM orders WHERE status = 1 ORDER BY create_time DESC LIMIT 100;
```

| 字段 | 说明 |
|------|------|
| Query_time | 查询总耗时（秒） |
| Lock_time | 等待锁时间 |
| Rows_sent | 实际返回行数 |
| Rows_examined | 扫描行数（越大越慢） |

## 二、pt-query-digest 分析工具

### 2.1 安装与使用

```bash
# 安装 Percona Toolkit
yum install percona-toolkit

# 分析慢查询日志
pt-query-digest /var/log/mysql/slow.log

# 输出到文件
pt-query-digest /var/log/mysql/slow.log > slow_report.txt

# 只分析最近 1 小时
pt-query-digest --since 3600 /var/log/mysql/slow.log

# 过滤特定数据库
pt-query-digest --filter '$event->{db} eq "your_db"' /var/log/mysql/slow.log
```

### 2.2 报告解读

```
# Profile
# Rank Query ID           Response time  Calls R/Call  V/M   Item
# ==== ================== =============  ===== =======  ===== =====
#    1 0xABCD1234...       45.2345 32.1%   1200 0.0377  0.01  SELECT orders
#    2 0xEFGH5678...       33.1234 23.5%    800 0.0414  0.02  SELECT users

关键指标：
- Response time：总响应时间及占比
- Calls：调用次数
- R/Call：平均响应时间
- 优化优先级 = Response time 占比最大的查询
```

## 三、案例一：N+1 查询问题优化

### 3.1 问题场景

```java
// ❌ N+1 问题：查1次订单列表 + N次查用户
List<Order> orders = orderMapper.findAll();  // 1次查询
for (Order order : orders) {
    User user = userMapper.findById(order.getUserId());  // N次查询
    order.setUser(user);
}
```

### 3.2 慢查询日志表现

```
-- 循环查询，每次约 2ms，100条订单 = 200ms+
SELECT * FROM orders;
SELECT * FROM users WHERE id = 1;
SELECT * FROM users WHERE id = 2;
... (100次)
```

### 3.3 优化方案

**方案一：JOIN 关联查询**

```sql
-- ✅ 一次查询获取所有数据
SELECT o.*, u.name, u.email
FROM orders o
LEFT JOIN users u ON o.user_id = u.id
WHERE o.status = 1
LIMIT 100;
```

**方案二：IN 批量查询（适合数据量大时）**

```java
// ✅ 先查订单，再批量查用户
List<Order> orders = orderMapper.findAll();
List<Long> userIds = orders.stream()
    .map(Order::getUserId)
    .distinct()
    .collect(Collectors.toList());

// 一次 IN 查询
List<User> users = userMapper.findByIds(userIds);
Map<Long, User> userMap = users.stream()
    .collect(Collectors.toMap(User::getId, u -> u));

for (Order order : orders) {
    order.setUser(userMap.get(order.getUserId()));
}
```

```xml
<!-- MyBatis IN 查询 -->
<select id="findByIds" resultType="User">
    SELECT * FROM users WHERE id IN
    <foreach collection="ids" item="id" open="(" separator="," close=")">
        #{id}
    </foreach>
</select>
```

**优化效果：**

| 方案 | 查询次数 | 耗时（100条） |
|------|---------|-------------|
| N+1 | 101次 | ~200ms |
| JOIN | 1次 | ~5ms |
| IN批量 | 2次 | ~8ms |

## 四、案例二：全表扫描优化

### 4.1 问题 SQL

```sql
-- ❌ 慢查询：扫描 500 万行，耗时 8 秒
SELECT * FROM order_items 
WHERE DATE_FORMAT(create_time, '%Y-%m') = '2024-05'
  AND amount > 100;
```

### 4.2 EXPLAIN 分析（优化前）

```sql
EXPLAIN SELECT * FROM order_items 
WHERE DATE_FORMAT(create_time, '%Y-%m') = '2024-05'
  AND amount > 100\G

-- 输出关键信息
type: ALL              ← 全表扫描
rows: 5000000          ← 扫描 500 万行
Extra: Using where     ← 无法使用索引
```

### 4.3 优化方案

```sql
-- ✅ 改写：使用范围查询，可以走 create_time 索引
SELECT * FROM order_items 
WHERE create_time >= '2024-05-01' 
  AND create_time < '2024-06-01'
  AND amount > 100;

-- 添加联合索引
ALTER TABLE order_items 
ADD INDEX idx_time_amount (create_time, amount);
```

### 4.4 EXPLAIN 分析（优化后）

```sql
EXPLAIN SELECT * FROM order_items 
WHERE create_time >= '2024-05-01' 
  AND create_time < '2024-06-01'
  AND amount > 100\G

-- 输出关键信息
type: range            ← 范围扫描
key: idx_time_amount   ← 命中索引
rows: 12000            ← 只扫描 1.2 万行
Extra: Using index condition
```

| 指标 | 优化前 | 优化后 |
|------|-------|-------|
| type | ALL | range |
| rows | 5,000,000 | 12,000 |
| 耗时 | 8s | 0.05s |

## 五、案例三：ORDER BY 优化

### 5.1 问题 SQL

```sql
-- ❌ 产生 filesort，耗时 3 秒
SELECT id, title, create_time, view_count
FROM articles
WHERE category_id = 10
ORDER BY view_count DESC
LIMIT 20;
```

### 5.2 EXPLAIN 分析

```sql
EXPLAIN SELECT id, title, create_time, view_count
FROM articles WHERE category_id = 10
ORDER BY view_count DESC LIMIT 20\G

type: ref
key: idx_category         ← 用了 category_id 索引
Extra: Using filesort     ← ❌ 额外排序，耗时
```

### 5.3 优化：建联合索引

```sql
-- ✅ 联合索引同时覆盖 WHERE 和 ORDER BY
ALTER TABLE articles 
ADD INDEX idx_category_view (category_id, view_count DESC);

-- 进一步：加上查询列，变为覆盖索引
ALTER TABLE articles 
ADD INDEX idx_category_view_cover (category_id, view_count DESC, id, title, create_time);
```

### 5.4 EXPLAIN 对比

```sql
-- 优化后
type: ref
key: idx_category_view_cover
Extra: Using index    ← ✅ 覆盖索引，无 filesort
rows: 20              ← 精准返回 20 行
```

## 六、案例四：深度分页优化

### 6.1 问题

```sql
-- ❌ 深度分页：OFFSET 很大时极慢
SELECT * FROM articles ORDER BY id LIMIT 10 OFFSET 1000000;
-- 实际扫描 1,000,010 行，只返回 10 行
```

### 6.2 优化：游标分页

```sql
-- ✅ 记录上次最大 id，用 WHERE 代替 OFFSET
SELECT * FROM articles 
WHERE id > #{lastId}
ORDER BY id 
LIMIT 10;
```

### 6.3 优化：延迟关联

```sql
-- ✅ 先用覆盖索引定位 id，再 JOIN 获取完整数据
SELECT a.* 
FROM articles a
INNER JOIN (
    SELECT id FROM articles 
    ORDER BY id 
    LIMIT 10 OFFSET 1000000
) t ON a.id = t.id;
```

| 方案 | 扫描行数 | 耗时 |
|------|---------|------|
| OFFSET 分页 | 1,000,010 | ~2s |
| 游标分页 | 10 | <1ms |
| 延迟关联 | 1,000,010（仅索引） | ~200ms |

## 七、慢查询优化总结流程

```
慢查询优化六步法：
1. 开启慢查询日志，设置 long_query_time = 1
2. 使用 pt-query-digest 找出 TOP 慢查询
3. EXPLAIN 分析执行计划（重点看 type、rows、Extra）
4. 针对性优化：
   - type=ALL → 加索引
   - Using filesort → 加联合索引覆盖 ORDER BY
   - N+1 → 改 JOIN 或批量 IN
   - 深度分页 → 游标分页或延迟关联
5. 验证优化效果（EXPLAIN + 实际耗时）
6. 上线监控，设置告警阈值
```

| 优化手段 | 适用场景 | 效果 |
|---------|---------|------|
| 添加索引 | 全表扫描 | 显著 |
| 覆盖索引 | 频繁回表 | 中等 |
| 联合索引 | ORDER BY/GROUP BY | 中等 |
| 改写 SQL | N+1/全函数/前缀LIKE | 显著 |
| 分页优化 | 深度分页 | 显著 |
| 读写分离 | 读多写少 | 中等 |
| 分表 | 单表数据量超千万 | 显著 |
