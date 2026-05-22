# MySQL 慢查询优化：从发现到解决的完整 SOP

<div class="post-meta">📅 2024-12-28 &nbsp;·&nbsp; 🏷️ <span class="tag">数据库</span></div>

接到告警：接口 P99 超过 3 秒。排查步骤是什么？慢查询日志、EXPLAIN、索引分析、SQL 改写——这套 SOP 在实际生产中反复验证有效。本文将整个流程串联起来，附典型案例和优化前后的对比数据。

---

## 一、背景：慢查询的常见根因

`
慢查询根因分类：
┌─────────────────────────────────────────┐
│ 索引问题（70%）                          │
│  - 无索引、索引选择性差、索引失效         │
├─────────────────────────────────────────┤
│ SQL 设计问题（20%）                      │
│  - N+1 查询、大 OFFSET 分页、SELECT *    │
├─────────────────────────────────────────┤
│ 数据量问题（10%）                        │
│  - 单表数据量超千万、冷热数据未分离       │
└─────────────────────────────────────────┘
`

---

## 二、Step 1：开启慢查询日志

`sql
-- 查看当前配置
SHOW VARIABLES LIKE 'slow_query_log%';
SHOW VARIABLES LIKE 'long_query_time';

-- 开启慢查询日志（生产建议持久化到配置文件）
SET GLOBAL slow_query_log = ON;
SET GLOBAL long_query_time = 1;           -- 超过 1s 记录（生产可设 0.5s）
SET GLOBAL slow_query_log_file = '/var/log/mysql/slow.log';
SET GLOBAL log_queries_not_using_indexes = ON;  -- 未使用索引的查询也记录
`

慢查询日志格式：

`
# Time: 2024-12-28T10:15:30.000000Z
# User@Host: app[app] @ localhost [127.0.0.1]
# Query_time: 3.512340  Lock_time: 0.000100  Rows_sent: 100  Rows_examined: 980000
SET timestamp=1703758530;
SELECT * FROM orders WHERE status = 'paid' ORDER BY create_time DESC LIMIT 100;
`

重点字段：Query_time（执行时间）、Rows_examined（扫描行数，越大越慢）、Rows_sent（返回行数）。

---

## 三、Step 2：分析慢查询日志

手动分析日志效率低，使用 pt-query-digest 聚合分析：

`ash
# 安装 Percona Toolkit
# 分析慢查询日志，输出 Top 10 高耗时 SQL
pt-query-digest /var/log/mysql/slow.log --limit 10

# 输出示例：
# Rank Query ID      Response time    Calls   R/Call   Item
# ==== ============= ================ ======= ======== ====
#    1 0xABC...      45.3212  38.5%    1234   0.0367   SELECT orders
#    2 0xDEF...      32.1840  27.4%     567   0.0567   SELECT users
`

或直接查 information_schema.PROCESSLIST 找当前运行的慢查询：

`sql
-- 查找执行时间超过 2 秒的查询
SELECT id, user, host, db, command, time, state, info
FROM information_schema.PROCESSLIST
WHERE time > 2 AND command != 'Sleep'
ORDER BY time DESC;
`

---

## 四、Step 3：EXPLAIN 分析执行计划

`sql
EXPLAIN SELECT * FROM orders
WHERE user_id = 1234 AND status = 'paid'
ORDER BY create_time DESC
LIMIT 10;
`

重点关注：
- 	ype：是否 ALL（全表扫描）
- key：使用了哪个索引，NULL 表示没有
- ows：预估扫描行数
- Extra：是否有 Using filesort、Using temporary

---

## 五、典型优化案例

### 案例 1：大 OFFSET 深分页

`sql
-- ❌ 深分页：OFFSET 100000，需要扫描并丢弃前 10 万行
SELECT * FROM orders ORDER BY id LIMIT 10 OFFSET 100000;
-- Rows_examined: 100010，耗时 2.3s

-- ✅ 游标分页（记住上次查询的最大 ID）
SELECT * FROM orders WHERE id > #{lastId} ORDER BY id LIMIT 10;
-- Rows_examined: 10，耗时 0.001s
`

### 案例 2：N+1 查询

`java
// ❌ 先查 N 个订单，再逐一查用户，共 N+1 次 SQL
List<Order> orders = orderDao.findAll();
for (Order order : orders) {
    User user = userDao.findById(order.getUserId());  // N 次查询
    order.setUser(user);
}

// ✅ 用 IN 查询一次性获取所有用户
List<Order> orders = orderDao.findAll();
List<Long> userIds = orders.stream().map(Order::getUserId).collect(Collectors.toList());
Map<Long, User> userMap = userDao.findByIds(userIds).stream()
    .collect(Collectors.toMap(User::getId, u -> u));
orders.forEach(o -> o.setUser(userMap.get(o.getUserId())));
`

### 案例 3：SELECT * 导致覆盖索引失效

`sql
-- ❌ SELECT * 需要回表，无法使用覆盖索引
SELECT * FROM users WHERE name = 'Alice';

-- ✅ 按需查询，利用覆盖索引
SELECT id, name, email FROM users WHERE name = 'Alice';
-- 若索引包含 (name, id, email)，无需回表
`

### 案例 4：排序字段未加索引

`sql
-- ❌ create_time 无索引，需 filesort
SELECT * FROM orders WHERE user_id = 1 ORDER BY create_time DESC LIMIT 10;
-- Extra: Using index condition; Using filesort

-- ✅ 建联合索引，ORDER BY 也走索引
ALTER TABLE orders ADD INDEX idx_user_create(user_id, create_time);
-- Extra: Using index condition（无 filesort）
`

### 案例 5：统计大表 COUNT(*)

`sql
-- ❌ COUNT(*) 全表扫描（没有 WHERE 条件时）
SELECT COUNT(*) FROM orders;  -- 百万级耗时 0.5s+

-- ✅ 方案 A：使用 COUNT(索引列)，走二级索引（比主键更小）
SELECT COUNT(status) FROM orders;

-- ✅ 方案 B：异步统计 + 缓存（Redis 维护计数器）
-- ✅ 方案 C：近似值 EXPLAIN 中的 rows 字段
`

---

## 六、优化效果对比

| 优化类型 | 优化前 | 优化后 | 提升 |
|---------|--------|--------|------|
| 添加复合索引 | 3.5s（全表扫描）| 0.02s | 175x |
| 大 OFFSET 改游标 | 2.3s | 0.001s | 2300x |
| N+1 改 IN 查询 | 500ms（50次查询）| 5ms | 100x |
| SELECT * 改按需查询 | 0.3s（回表）| 0.01s（覆盖索引）| 30x |

---

## 七、常见坑点与最佳实践

### 坑 1：FORCE INDEX 误用掩盖真正问题

`sql
-- ❌ 强制走索引只是绕过了优化器，没解决根本问题
SELECT * FROM orders FORCE INDEX(idx_create_time) WHERE status = 'paid';

-- ✅ 应该分析为什么优化器没选这个索引（统计信息过期？区分度不足？）
ANALYZE TABLE orders;  -- 更新统计信息
`

### 坑 2：过度依赖索引，忽略 SQL 改写

索引只能优化数据访问路径，SQL 逻辑问题（N+1、大 OFFSET）必须从 SQL 本身解决。

---

## 八、总结与延伸

**慢查询优化 SOP**：
1. 开启慢查询日志（long_query_time = 1）
2. pt-query-digest 聚合分析，找 Top SQL
3. EXPLAIN 分析执行计划（关注 type/key/rows/Extra）
4. 按优先级优化：**索引** → **SQL 改写** → **架构调整**（分库分表/读写分离）

**延伸阅读方向**：
- EXPLAIN ANALYZE（MySQL 8.0+）：获取实际执行耗时而非估算
- optimizer_trace：查看 MySQL 优化器的完整决策过程
- ProxySQL：数据库代理，内置查询规则和慢查询统计
- 读写分离架构：主库写、从库读，减轻主库查询压力
