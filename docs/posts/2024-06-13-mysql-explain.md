# MySQL EXPLAIN 执行计划字段逐一解读

<div class="post-meta">📅 2024-06-13 &nbsp;·&nbsp; 🏷️ <span class="tag">MySQL</span></div>

## 一、快速入门

`EXPLAIN` 是 MySQL 提供的查询分析工具，能展示优化器如何执行一条 SQL。

```sql
EXPLAIN SELECT u.name, o.amount
FROM users u
JOIN orders o ON u.id = o.user_id
WHERE u.status = 1 AND o.amount > 100;
```

输出示例：

```
+----+-------------+-------+------------+------+---------------+---------+---------+--------------------+------+----------+-------------+
| id | select_type | table | partitions | type | possible_keys | key     | key_len | ref                | rows | filtered | Extra       |
+----+-------------+-------+------------+------+---------------+---------+---------+--------------------+------+----------+-------------+
|  1 | SIMPLE      | u     | NULL       | ref  | idx_status    | idx_status | 1    | const              |  200 |   100.00 | Using index |
|  1 | SIMPLE      | o     | NULL       | ref  | idx_user_id   | idx_user_id| 8    | mydb.u.id          | 5    |    33.33 | Using where |
+----+-------------+-------+------------+------+---------------+---------+---------+--------------------+------+----------+-------------+
```

---

## 二、id 字段

**含义**：查询序号，标识执行顺序。

| id 值 | 说明 |
|-------|------|
| id 相同 | 同一组，按从上到下顺序执行 |
| id 不同 | id 越大越先执行（子查询先于外查询） |
| id 为 NULL | 结果来自 UNION 临时表 |

```sql
-- 子查询示例：id=2 先于 id=1 执行
EXPLAIN SELECT * FROM users WHERE id IN (
    SELECT user_id FROM orders WHERE amount > 100  -- id=2
);
-- id=1 的 users 在 id=2 的 orders 子查询结果确定后才执行
```

---

## 三、select_type 字段

| select_type | 说明 | 示例 |
|------------|------|------|
| SIMPLE | 简单 SELECT，无子查询/UNION | `SELECT * FROM t WHERE id=1` |
| PRIMARY | 最外层查询 | 包含子查询时外层 |
| SUBQUERY | SELECT 子句中的子查询 | `SELECT (SELECT max(id) FROM t)` |
| DEPENDENT SUBQUERY | 依赖外部查询的子查询（相关子查询） | `WHERE id = (SELECT ...)` |
| UNION | UNION 中第二个及以后的 SELECT | `SELECT ... UNION SELECT ...` |
| UNION RESULT | UNION 临时表 | id 通常为 NULL |
| DERIVED | FROM 子句中的子查询（派生表） | `FROM (SELECT ...) t` |
| MATERIALIZED | 物化子查询（MySQL 5.6+ 优化） | 子查询结果缓存为临时表 |

---

## 四、type 字段（核心！）

type 表示访问类型，**从好到差排序**：

```
system > const > eq_ref > ref > fulltext > ref_or_null >
index_merge > unique_subquery > index_subquery >
range > index > ALL
```

生产中至少要达到 **range**，最好 **ref** 以上。

### 4.1 system

表中只有一行数据（系统表）。

```sql
-- MyISAM 或只有1行数据的表
EXPLAIN SELECT * FROM (SELECT 1) AS t;
-- type: system
```

### 4.2 const

通过主键或唯一索引**等值查询**，最多匹配一行。速度极快，结果被当作常量。

```sql
-- 主键等值
EXPLAIN SELECT * FROM users WHERE id = 1;
-- type: const

-- 唯一索引等值
EXPLAIN SELECT * FROM users WHERE email = 'alice@example.com';
-- type: const（email 为 UNIQUE）
```

### 4.3 eq_ref

JOIN 时，右表通过**主键或唯一非空索引**匹配，每行左表数据对应右表最多一行。

```sql
EXPLAIN SELECT u.name, p.bio
FROM users u
JOIN profiles p ON u.id = p.user_id;  -- p.user_id 为主键
-- p 表 type: eq_ref
```

### 4.4 ref

通过**普通索引等值查询**，可能匹配多行。

```sql
EXPLAIN SELECT * FROM orders WHERE user_id = 100;
-- user_id 上有普通索引 idx_user_id
-- type: ref
```

### 4.5 range

索引**范围扫描**，常见于 `>`、`<`、`BETWEEN`、`IN`、`LIKE 'xxx%'`。

```sql
EXPLAIN SELECT * FROM orders
WHERE create_time BETWEEN '2024-01-01' AND '2024-12-31';
-- type: range

EXPLAIN SELECT * FROM users WHERE id IN (1, 2, 3);
-- type: range
```

### 4.6 index

**全索引扫描**，遍历整棵索引树（不读数据行），通常出现在覆盖索引场景。比 ALL 好（索引比数据行小），但仍是全扫描。

```sql
-- 统计索引列行数（覆盖索引）
EXPLAIN SELECT count(*) FROM users;
-- type: index

EXPLAIN SELECT id FROM users ORDER BY id;
-- type: index（遍历主键索引）
```

### 4.7 ALL

**全表扫描**，读取每一行数据。必须优化！

```sql
-- 无索引条件，扫描全表
EXPLAIN SELECT * FROM users WHERE age > 20;
-- age 列无索引 → type: ALL  ❌
```

### type 对比速查表

```
性能：system → const → eq_ref → ref → range → index → ALL
              ↑极快↑              ↑良↑    ↑可接受↑        ↑必须优化↑
```

---

## 五、possible_keys 字段

优化器**认为可能用到**的索引列表（候选索引）。

- 不为 NULL 但 key 为 NULL：优化器认为全表扫描代价更低
- 为 NULL：没有可用索引，考虑建索引

---

## 六、key 字段

优化器**实际选择**的索引。

```sql
-- 强制使用指定索引（调试用）
EXPLAIN SELECT * FROM orders FORCE INDEX (idx_user_id) WHERE user_id = 100;

-- 忽略某个索引
EXPLAIN SELECT * FROM orders IGNORE INDEX (idx_status) WHERE status = 1;
```

---

## 七、key_len 字段

使用索引的**字节长度**，可判断联合索引用了几列。

字节数计算规则：

| 类型 | 长度 | 备注 |
|------|------|------|
| TINYINT | 1 | |
| INT | 4 | |
| BIGINT | 8 | |
| CHAR(n) | n × charset_len | utf8mb4: ×4 |
| VARCHAR(n) | n × charset_len + 2 | +2 存储长度 |
| 允许 NULL | +1 | 额外 NULL 标志位 |

```sql
-- 联合索引 idx(a INT NOT NULL, b VARCHAR(10) NOT NULL) utf8mb4
-- key_len = 4 + (10*4+2) = 4 + 42 = 46
-- 若 key_len=4，说明只用了 a 列
-- 若 key_len=46，说明 a、b 两列都用了
```

---

## 八、ref 字段

显示与索引列**进行等值比较的内容**。

| ref 值 | 说明 |
|--------|------|
| const | 与常量比较（WHERE id = 1） |
| `db.table.column` | 与某表某列比较（JOIN 条件） |
| func | 与函数结果比较 |
| NULL | range 或 index 扫描 |

---

## 九、rows 字段

优化器**预估需要扫描的行数**，越小越好。基于统计信息，不一定准确。

```sql
-- rows 很大说明需要扫描大量数据，考虑优化索引
EXPLAIN SELECT * FROM orders WHERE remark LIKE '%退款%';
-- rows: 1000000  ❌ 全表扫描
```

---

## 十、filtered 字段

**通过索引过滤后，还需要在 Server 层继续过滤的行百分比**。

- `filtered = 100%`：索引精确定位，无需额外过滤
- `filtered = 10%`：索引返回 rows 行，其中 10% 满足 WHERE 条件

实际扫描行数 = `rows × filtered / 100`

---

## 十一、Extra 字段（重要！）

Extra 字段提供额外的执行计划信息，以下是最重要的几个值：

### 11.1 Using index（好）

覆盖索引，无需回表。

```sql
EXPLAIN SELECT id, status FROM orders WHERE user_id = 100;
-- idx(user_id, status) 覆盖了所有查询列
-- Extra: Using index  ✅
```

### 11.2 Using where（中性）

在 Server 层对存储引擎返回的数据进行额外过滤。

```sql
EXPLAIN SELECT * FROM orders WHERE user_id = 100 AND remark = '测试';
-- user_id 走了索引，remark 无索引，Server 层再过滤 remark
-- Extra: Using where
```

### 11.3 Using index condition（ICP，好）

索引下推（Index Condition Pushdown，MySQL 5.6+）。将 WHERE 过滤下推到存储引擎层，减少回表次数。

```sql
-- idx(last_name, first_name)
EXPLAIN SELECT * FROM users
WHERE last_name = 'Smith' AND first_name LIKE 'J%';
-- Extra: Using index condition
-- 存储引擎在索引层面就过滤了 first_name LIKE 'J%'，减少回表
```

### 11.4 Using filesort（坏）

无法利用索引完成排序，需要额外排序操作（内存或磁盘）。

```sql
EXPLAIN SELECT * FROM orders WHERE user_id = 100 ORDER BY amount;
-- idx_user_id 只有 user_id，amount 排序需要额外 filesort
-- Extra: Using filesort  ❌

-- 优化：建联合索引 idx(user_id, amount)
ALTER TABLE orders ADD INDEX idx_user_amount (user_id, amount);
```

### 11.5 Using temporary（坏）

使用临时表处理查询结果（常见于 GROUP BY、DISTINCT、UNION 等）。

```sql
EXPLAIN SELECT status, count(*) FROM orders
WHERE user_id = 100
GROUP BY status;
-- 如果 status 不在索引中，需要临时表
-- Extra: Using temporary  ❌

-- 优化：建联合索引 idx(user_id, status)
```

### 11.6 Using join buffer（注意）

JOIN 操作无法使用索引，使用 Join Buffer 缓存。说明被驱动表关联字段缺少索引。

```sql
EXPLAIN SELECT u.name, o.amount
FROM orders o
JOIN users u ON o.user_name = u.name;
-- u.name 无索引
-- Extra: Using join buffer (Block Nested Loop)  ❌
```

### Extra 值汇总

| Extra 值 | 好/坏 | 含义 |
|----------|-------|------|
| Using index | ✅ 好 | 覆盖索引，无回表 |
| Using where | 中性 | Server 层过滤 |
| Using index condition | ✅ 好 | 索引下推（ICP） |
| Using filesort | ❌ 坏 | 额外排序，需优化 |
| Using temporary | ❌ 坏 | 临时表，需优化 |
| Using join buffer | ⚠️ 注意 | JOIN 无索引 |
| Select tables optimized away | ✅ 好 | MIN/MAX 直接走索引 |
| Impossible WHERE | 中性 | WHERE 条件永假 |

---

## 十二、EXPLAIN ANALYZE（MySQL 8.0+）

MySQL 8.0 提供 `EXPLAIN ANALYZE`，实际执行查询并返回**真实的行数和耗时**（而非估算值）。

```sql
EXPLAIN ANALYZE
SELECT u.name, COUNT(o.id)
FROM users u
LEFT JOIN orders o ON u.id = o.user_id
WHERE u.status = 1
GROUP BY u.id;

-- 输出示例（树形格式）
-> Group aggregate: count(o.id)  (actual time=2.3..15.6 rows=200 loops=1)
    -> Nested loop left join  (actual time=0.1..12.4 rows=1000 loops=1)
        -> Index scan on u using idx_status  (actual time=0.05..1.2 rows=200 loops=1)
        -> Index lookup on o using idx_user_id (user_id=u.id)  (actual time=0.04..0.05 rows=5 loops=200)
```

---

## 十三、小结：EXPLAIN 使用流程

```
1. EXPLAIN SQL语句
2. 检查 type：ALL/index → 需要优化
3. 检查 Extra：
   - Using filesort → 调整索引顺序或添加排序字段到索引
   - Using temporary → GROUP BY/DISTINCT 字段加索引
4. 检查 rows：过大 → 索引区分度低或缺少索引
5. 检查 key_len：联合索引是否充分使用
6. 优化后再次 EXPLAIN 验证
```
