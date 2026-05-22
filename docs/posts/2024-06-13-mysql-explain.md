# MySQL EXPLAIN 全解：读懂执行计划，找出慢查询根因

<div class="post-meta">📅 2024-06-13 &nbsp;·&nbsp; 🏷️ <span class="tag">数据库</span></div>

SQL 跑了 3 秒，加索引之后还是 2 秒——问题出在哪？EXPLAIN 是 MySQL 查询优化的第一步，读懂每一列的含义，才能精准判断索引是否生效、是否发生了全表扫描、Join 的驱动顺序是否合理。

---

## 一、背景：查询优化器与执行计划

MySQL 收到一条 SQL 后，**查询优化器**会根据统计信息生成多个执行计划候选，选择估算代价最低的一个执行。EXPLAIN 让我们看到优化器的选择结果：

```sql
EXPLAIN SELECT u.name, o.amount
FROM orders o
JOIN users u ON o.user_id = u.id
WHERE o.status = 'paid' AND o.amount > 100;
```
---

## 二、EXPLAIN 输出字段详解

### 关键字段一览

| 字段 | 含义 | 重点关注 |
|------|------|---------|
| id | 查询序号，相同 id 从上到下执行，不同 id 大的先执行 | 子查询顺序 |
| select_type | 查询类型（SIMPLE/PRIMARY/SUBQUERY/DERIVED...）| DERIVED 代表派生表 |
| table | 当前行对应的表名 | |
| type | **访问类型**，性能核心指标 | 重点！|
| possible_keys | 可能用到的索引 | |
| key | 实际使用的索引 | NULL=未用索引 |
| key_len | 使用索引的字节长度 | 复合索引用了几列 |
| ref | 与索引比较的列/常量 | |
| rows | 预估扫描行数 | 越小越好 |
| filtered | 经过条件过滤后的行数百分比 | 越高越好 |
| Extra | 附加信息 | Using index/filesort/temporary |

### type 字段（最重要）

性能从好到差：

```
system > const > eq_ref > ref > range > index > ALL
```
| type | 含义 | 触发条件 |
|------|------|---------|
| system | 表只有一行 | 系统表 |
| const | 最多一行（主键/唯一索引等值查询）| WHERE id = 1 |
| eq_ref | 每行关联最多一行（Join 用主键/唯一索引）| JOIN ON a.id = b.id |
| ref | 非唯一索引等值查询，可能多行 | WHERE status = 'active' |
| range | 索引范围查询 | WHERE id BETWEEN 1 AND 100 |
| index | 全索引扫描（遍历索引树）| SELECT id FROM orders（覆盖索引）|
| ALL | **全表扫描** ← 需要优化 | 无合适索引 |

**生产规范**：type 至少要达到 range，核心表的关键查询应达到 ref 或更好。

### Extra 字段（第二重要）

| Extra 值 | 含义 | 是否需要优化 |
|---------|------|------------|
| Using index | **覆盖索引**，不需要回表 | ✅ 最优 |
| Using where | 在索引上进行了额外过滤 | 正常 |
| Using index condition | **索引下推（ICP）**，在索引层过滤，减少回表 | ✅ 好 |
| Using filesort | 需要额外排序（内存/磁盘）| ⚠️ 需优化 |
| Using temporary | 使用了临时表（GROUP BY/DISTINCT）| ⚠️ 需优化 |
| Using join buffer | Join 时用了 Block Nested Loop，无索引 | ❌ 需优化 |
| NULL | 通过索引找到数据后直接返回 | 正常 |

---

## 三、实战分析案例

### 案例 1：发现全表扫描

```sql
EXPLAIN SELECT * FROM orders WHERE create_time > '2024-01-01';
```
```
id | type | key  | rows   | Extra
 1 | ALL  | NULL | 980000 | Using where
```
**诊断**：type=ALL，key=NULL，扫描 98 万行。create_time 没有索引。

**修复**：
```sql
ALTER TABLE orders ADD INDEX idx_create_time(create_time);
-- 优化后：type=range，rows=5000
```
### 案例 2：索引存在但未使用（索引失效）

```sql
EXPLAIN SELECT * FROM users WHERE YEAR(birthday) = 1990;
```
```
id | type | key  | rows  | Extra
 1 | ALL  | NULL | 50000 | Using where
```
**诊断**：对索引列使用了函数，导致索引失效。

**修复**：
```sql
-- 改用范围查询，不对索引列套函数
SELECT * FROM users WHERE birthday BETWEEN '1990-01-01' AND '1990-12-31';
-- 优化后：type=range，key=idx_birthday
```
### 案例 3：Using filesort 问题

```sql
EXPLAIN SELECT * FROM orders WHERE user_id = 100 ORDER BY create_time DESC LIMIT 10;
```
```
id | type | key         | Extra
 1 | ref  | idx_user_id | Using index condition; Using filesort
```
**诊断**：虽然用了 idx_user_id 索引，但 ORDER BY create_time 需要额外排序。

**修复**：建联合索引 (user_id, create_time)，排序方向与 ORDER BY 一致：

```sql
ALTER TABLE orders ADD INDEX idx_user_create(user_id, create_time);
-- 优化后：Extra = Using index condition（无 filesort）
```
### 案例 4：key_len 判断复合索引使用情况

```sql
-- 假设复合索引：(a INT, b VARCHAR(50), c INT)
-- INT=4字节，VARCHAR(50)=50*3+2=152字节（utf8mb4），允许NULL+1字节

EXPLAIN SELECT * FROM t WHERE a = 1;
-- key_len = 5（INT 4 + NULL标识 1）← 只用了第一列

EXPLAIN SELECT * FROM t WHERE a = 1 AND b = 'x';
-- key_len = 158（5 + 153）← 用了前两列

EXPLAIN SELECT * FROM t WHERE a = 1 AND b = 'x' AND c = 2;
-- key_len = 163 ← 用了全部三列
```
通过 key_len 可以精确判断复合索引用了几个列。

---

## 四、EXPLAIN ANALYZE（MySQL 8.0+）

EXPLAIN ANALYZE 不只是估算，而是**真正执行 SQL** 并返回实际耗时：

```sql
EXPLAIN ANALYZE
SELECT u.name, COUNT(o.id)
FROM orders o JOIN users u ON o.user_id = u.id
GROUP BY u.id;
```
```
-> Table scan on <temporary>  (actual time=15.2..15.8 rows=500 loops=1)
    -> Aggregate using temporary table  (actual time=14.9..14.9 rows=500 loops=1)
        -> Nested loop inner join  (cost=12543 rows=9800) (actual time=0.5..12.1 rows=9800 loops=1)
            -> Full table scan on u  (cost=512 rows=500) (actual time=0.3..1.2 rows=500 loops=1)
            -> Index lookup on o using idx_user_id (actual time=0.02..0.02 rows=19.6 loops=500)
```
能看到每个节点的实际执行时间和行数，比 EXPLAIN 更精准。

---

## 五、常见坑点与最佳实践

### 坑 1：隐式类型转换导致索引失效

```sql
-- 假设 user_id 列是 VARCHAR 类型
-- ❌ 传入数字，发生隐式类型转换，索引失效
SELECT * FROM users WHERE user_id = 123;

-- ✅ 类型匹配
SELECT * FROM users WHERE user_id = '123';
```
### 坑 2：OR 条件导致索引失效

```sql
-- ❌ OR 两边的列都有索引，但 MySQL 可能选择全表扫描
SELECT * FROM orders WHERE user_id = 1 OR status = 'paid';

-- ✅ 改用 UNION ALL 让每个条件单独走索引
SELECT * FROM orders WHERE user_id = 1
UNION ALL
SELECT * FROM orders WHERE status = 'paid' AND user_id != 1;
```
### 坑 3：LIKE 左模糊查询失效

```sql
-- ❌ 左模糊，索引失效
SELECT * FROM users WHERE name LIKE '%Alice%';

-- ✅ 只有右模糊才能用索引
SELECT * FROM users WHERE name LIKE 'Alice%';

-- ✅ 全文搜索需求用 Elasticsearch
```
---

## 六、总结与延伸

**EXPLAIN 优化核查清单**：
- type 是否达到 ref 或以上？ALL 需要立即加索引
- key 是否是预期索引？NULL 说明索引失效
- Extra 是否有 Using filesort/Using temporary？考虑联合索引覆盖 ORDER BY
- rows 预估行数是否合理？巨大行数说明索引选择性差
- key_len 是否用到了复合索引的所有列？

**延伸阅读方向**：
- MySQL 索引选择原理：为什么优化器有时不选更好的索引（FORCE INDEX 的使用场景）
- 索引下推（ICP）：MySQL 5.6+ 的重要优化，减少回表次数
- optimizer_trace：比 EXPLAIN 更底层的优化器执行轨迹分析工具
- pt-query-digest：Percona 工具，分析慢查询日志，找出高频/高耗时 SQL
