# MySQL 索引原理：B+ 树结构与覆盖索引

<div class="post-meta">📅 2024-07-28 &nbsp;·&nbsp; 🏷️ <span class="tag">MySQL</span></div>

## 一、为什么选 B+ 树

MySQL InnoDB 存储引擎使用 **B+ 树**作为索引结构，而非二叉树、哈希表或 B 树，原因如下：

| 结构 | 查找复杂度 | 范围查询 | 磁盘 IO | 适合场景 |
|------|-----------|---------|---------|---------|
| 二叉树（AVL/红黑树） | O(log n) | 差 | 多（树高大） | 内存索引 |
| B 树 | O(log n) | 一般 | 中 | 文件系统 |
| **B+ 树** | **O(log n)** | **优秀** | **少（矮胖）** | **数据库索引** |
| 哈希表 | O(1) | 不支持 | 少 | 等值查询 |

B+ 树优势：
- 非叶节点只存键值，每页可存更多 key，**树高更低**（通常 3～4 层）
- 叶节点形成**有序双向链表**，范围查询只需一次 IO 定位 + 顺序扫描
- 数据全在叶节点，**查询路径固定**，性能稳定

---

## 二、B+ 树结构图

```
                    [30 | 60]                     ← 根节点（非叶）
                   /    |    \
          [10|20] [40|50] [70|80]                 ← 内部节点（非叶）
         /  |  \   /  |  \   /  |  \
       [5][15][25][35][45][55][65][75][85]        ← 叶节点（存数据行 / 主键）
        ↔   ↔   ↔   ↔   ↔   ↔   ↔   ↔   ↔       ← 叶节点双向链表
```

**InnoDB 页大小默认 16KB**，假设主键 8B、指针 6B，一个非叶节点可存约 `16384/(8+6) ≈ 1170` 个键，3 层 B+ 树可支撑 `1170 × 1170 × 16 ≈ 2190 万`条记录，只需 **3 次磁盘 IO**。

---

## 三、聚簇索引 vs 非聚簇索引

### 3.1 聚簇索引（Clustered Index）

InnoDB 中**主键索引就是聚簇索引**，叶节点直接存储整行数据。

```
主键索引（聚簇）
叶节点: [id=1 | name=Alice | age=25 | ...]
        [id=2 | name=Bob   | age=30 | ...]
```

- 数据与索引存储在一起，**无需回表**
- 每张表只能有一个聚簇索引
- 若无主键，InnoDB 自动选 NOT NULL 唯一索引；若无则生成隐式 RowID

### 3.2 非聚簇索引（Secondary Index）

二级索引的叶节点**只存主键值**，查询数据需要**回表**。

```
name 字段二级索引
叶节点: [Alice | id=1]
        [Bob   | id=2]
        ↓ 回表（再次走主键索引取完整行）
主键索引叶节点: [id=1 | name=Alice | age=25 | ...]
```

**回表代价**：二级索引命中后需再走一次聚簇索引，两次 B+ 树查找。

---

## 四、覆盖索引（Covering Index）

当查询列**全部包含在索引中**时，无需回表，称为覆盖索引。

```sql
-- 表结构
CREATE TABLE orders (
    id     BIGINT PRIMARY KEY,
    user_id BIGINT,
    amount DECIMAL(10,2),
    status TINYINT,
    INDEX idx_user_status (user_id, status)
);

-- 覆盖索引（只查 user_id 和 status，均在联合索引中）
SELECT user_id, status FROM orders WHERE user_id = 100;
-- EXPLAIN Extra: Using index  ✅ 无回表

-- 非覆盖索引（还需要 amount，索引中没有）
SELECT user_id, status, amount FROM orders WHERE user_id = 100;
-- EXPLAIN Extra: NULL（需回表）  ❌
```

**优化技巧**：将高频查询字段加入索引（冗余），用覆盖索引消除回表。

---

## 五、最左前缀原则

联合索引 `(a, b, c)` 的使用规则：

```
idx(a, b, c)

可以用到索引：
  WHERE a = 1                    → 用 a
  WHERE a = 1 AND b = 2          → 用 a, b
  WHERE a = 1 AND b = 2 AND c=3  → 用 a, b, c
  WHERE a = 1 AND c = 3          → 只用 a（c 跳过了 b，b 断档）
  WHERE a > 1 AND b = 2          → 只用 a（范围查询后不能继续用后续列）

用不到索引：
  WHERE b = 2                    → 缺少最左列 a
  WHERE b = 2 AND c = 3          → 缺少最左列 a
```

**记忆口诀**：最左开始，遇到范围（>、<、between、like 前缀除外）即截断。

---

## 六、索引失效场景

### 6.1 LIKE 以通配符开头

```sql
-- 索引失效：前缀不确定，无法在 B+ 树上定位
SELECT * FROM users WHERE name LIKE '%Alice%';
SELECT * FROM users WHERE name LIKE '%Alice';

-- 索引有效：前缀确定
SELECT * FROM users WHERE name LIKE 'Alice%';
```

### 6.2 对索引列使用函数

```sql
-- 索引失效：函数改变了索引列的值，无法直接查 B+ 树
SELECT * FROM orders WHERE YEAR(create_time) = 2024;
SELECT * FROM users WHERE LEFT(name, 3) = 'Ali';

-- 改写为范围查询（索引有效）
SELECT * FROM orders
WHERE create_time >= '2024-01-01' AND create_time < '2025-01-01';
```

### 6.3 隐式类型转换

```sql
-- phone 字段类型为 VARCHAR，传入整数，MySQL 隐式转换导致索引失效
SELECT * FROM users WHERE phone = 13800138000;   -- ❌ 全表扫描

-- 正确写法
SELECT * FROM users WHERE phone = '13800138000'; -- ✅ 走索引
```

### 6.4 OR 条件中有非索引列

```sql
-- age 没有索引，OR 导致 name 的索引也失效
SELECT * FROM users WHERE name = 'Alice' OR age = 25;

-- 改写为 UNION（各自走各自的索引）
SELECT * FROM users WHERE name = 'Alice'
UNION
SELECT * FROM users WHERE age = 25;
```

### 6.5 不等于 / NOT IN / IS NOT NULL

```sql
-- 通常导致全表扫描（少量数据时优化器可能仍走索引）
SELECT * FROM users WHERE status != 1;
SELECT * FROM users WHERE status NOT IN (1, 2);
SELECT * FROM users WHERE name IS NOT NULL;
```

### 6.6 全表扫描比索引更优

当查询结果集占比较大（通常超过 30%）时，优化器会放弃索引选择全表扫描，因为随机 IO 代价高于顺序扫描。

---

## 七、联合索引设计原则

### 7.1 区分度高的列放左边

```sql
-- 性别区分度低（只有2个值），放左边浪费
-- ❌
INDEX idx_gender_name (gender, name)

-- ✅ 区分度高的 name 放左
INDEX idx_name_gender (name, gender)
```

### 7.2 频繁作为查询条件的列优先

```sql
-- 高频查询：WHERE user_id = ? AND status = ? ORDER BY create_time DESC
-- 合理设计联合索引：(user_id, status, create_time)
ALTER TABLE orders ADD INDEX idx_user_status_time (user_id, status, create_time);
```

### 7.3 利用覆盖索引减少回表

```sql
-- 高频查询字段 amount 也加入索引，避免回表
ALTER TABLE orders ADD INDEX idx_user_cover (user_id, status, amount);
SELECT user_id, status, amount FROM orders WHERE user_id = 100 AND status = 1;
-- Extra: Using index
```

### 7.4 避免冗余索引

```sql
-- idx(a) 和 idx(a,b) 中，idx(a) 完全可被 idx(a,b) 替代（最左前缀）
-- 删除冗余索引以减少写入开销
```

### 7.5 索引设计总结

```
设计步骤：
1. 分析高频 SQL 的 WHERE 条件
2. 等值条件列 → 放联合索引左侧
3. 范围条件列 → 放联合索引右侧
4. SELECT 字段 → 考虑是否加入索引实现覆盖
5. ORDER BY 字段 → 与 WHERE 条件一起构成联合索引避免 filesort
6. 用 EXPLAIN 验证，关注 type/key/Extra
```

---

## 八、常用索引诊断 SQL

```sql
-- 查看表的索引信息
SHOW INDEX FROM orders;

-- 查看索引使用情况（需开启 performance_schema）
SELECT object_schema, object_name, index_name, count_star,
       count_read, count_write
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE object_schema = 'your_db' AND object_name = 'orders'
ORDER BY count_star DESC;

-- 查找未被使用的索引
SELECT * FROM sys.schema_unused_indexes
WHERE object_schema = 'your_db';

-- 查找重复/冗余索引
SELECT * FROM sys.schema_redundant_indexes
WHERE table_schema = 'your_db';
```

---

## 九、小结

| 知识点 | 核心要点 |
|--------|---------|
| B+ 树 | 叶节点双向链表，3～4 层支持千万级数据 |
| 聚簇索引 | 主键即数据，叶节点存整行 |
| 二级索引 | 叶节点存主键，查询需回表 |
| 覆盖索引 | 查询列全在索引中，无需回表，Extra: Using index |
| 最左前缀 | 联合索引从左开始匹配，遇范围截断 |
| 索引失效 | LIKE%开头、函数、隐式转换、OR非索引列 |
| 设计原则 | 区分度高在左，等值在左范围在右，考虑覆盖 |
