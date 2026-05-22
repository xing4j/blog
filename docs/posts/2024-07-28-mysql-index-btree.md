# MySQL B+树索引：从磁盘 IO 到索引设计原则

<div class="post-meta">📅 2024-07-28 &nbsp;·&nbsp; 🏷️ <span class="tag">数据库</span></div>

为什么查询要建索引？为什么主键推荐自增整数？为什么复合索引要遵循最左前缀？这些问题的答案都藏在 B+树的数据结构和磁盘 IO 机制里。理解底层，索引设计就有了清晰的判断依据。

---

## 一、背景：为什么需要索引

没有索引时，MySQL 查找一条记录需要**全表扫描**：逐页读取数据，与查询条件逐行比对。一张百万行的表，每次查询都是几十万次 IO 操作。

索引是用**额外的存储空间**换取**查询速度**的数据结构，本质是一棵经过优化的、适合磁盘存储的树。

---

## 二、B+树结构解析

MySQL InnoDB 的索引用 B+树实现：

`
                    [30 | 60]                ← 根节点（非叶节点，只存键值，不存数据）
                   /    |    \
           [10|20]  [40|50]   [70|80]       ← 中间节点
          /  |  \
    [5|8] [12|15] [22|28]                   ← 叶节点（存储完整行数据或主键）
      ↔      ↔       ↔                      ← 叶节点双向链表（支持范围查询）
`

**关键设计**：
1. **非叶节点只存键**，叶节点存完整数据（聚簇索引）或主键（二级索引）
2. **叶节点用双向链表串联**，支持高效范围查询（ORDER BY/BETWEEN）
3. **树高通常只有 3-4 层**：每页 16KB，一棵高度为 3 的 B+树可存约 2000 万行

### 为什么不用红黑树、哈希表？

| 结构 | 范围查询 | 磁盘友好 | 高度 |
|------|---------|---------|------|
| 红黑树 | ❌ 中序遍历慢 | ❌ 节点分散 | O(logN) 但每层一次IO |
| 哈希表 | ❌ 不支持 | ❌ | O(1) 等值快 |
| B+树 | ✅ 链表顺序扫描 | ✅ 节点=页，减少IO | 通常 3-4 层 |

---

## 三、聚簇索引 vs 二级索引

### 聚簇索引（主键索引）

InnoDB 数据文件本身就是按主键组织的 B+树，叶节点存放完整行数据：

`
聚簇索引叶节点：
┌──────────────────────────────────┐
│ id=1 | name="Alice" | age=25 | … │  ← 完整行数据
└──────────────────────────────────┘
`

**影响**：主键的选择直接影响数据物理存储顺序。**推荐使用自增整数主键**的原因：
- 自增整数：每次插入追加到末尾，B+树不需要频繁分裂（页分裂）
- UUID 主键：随机插入，导致大量页分裂，写性能下降 30~50%

### 二级索引（非主键索引）

叶节点存储的是**主键值**，而不是完整行数据：

`
二级索引（name 字段）叶节点：
┌─────────────────┐
│ name="Alice" → id=1 │  ← 只存主键，不存完整行
└─────────────────┘
`

**回表查询**：通过二级索引找到主键后，再去聚簇索引查完整数据，需要两次 B+树查找：

`
SELECT * FROM users WHERE name = 'Alice'
→ 二级索引 idx_name 找到 id=1
→ 回到聚簇索引用 id=1 查完整行数据（回表）
`

**覆盖索引**：如果查询的字段都在索引中，不需要回表：

`sql
-- 只查 id 和 name，而索引 idx_name 的叶节点已经包含 id（主键）
SELECT id, name FROM users WHERE name = 'Alice';  -- 无需回表
`

---

## 四、复合索引与最左前缀原则

复合索引 (a, b, c) 在 B+树中先按 a 排序，a 相同再按 b 排序，b 相同再按 c 排序：

`
(a=1,b=2,c=3) → (a=1,b=2,c=5) → (a=1,b=3,c=1) → (a=2,b=1,c=2) → …
`

因此：

`sql
-- 索引：(user_id, status, create_time)

WHERE user_id = 1                          -- ✅ 用 user_id（最左前缀）
WHERE user_id = 1 AND status = 'paid'      -- ✅ 用 (user_id, status)
WHERE user_id = 1 AND status = 'paid' AND create_time > '2024-01-01'  -- ✅ 全用
WHERE status = 'paid'                      -- ❌ 跳过最左列，不走索引
WHERE user_id = 1 AND create_time > '2024-01-01'  -- ⚠️ 只用 user_id，create_time 不走索引（中间跳过了 status）
`

**范围查询截断**：范围查询（>、<、BETWEEN、LIKE 右模糊）后面的列不走索引：

`sql
-- 索引：(age, name)
WHERE age > 20 AND name = 'Alice'
-- age 走范围查询后，name 无法用索引过滤
-- ✅ 改为：WHERE age = 20 AND name = 'Alice'（等值在前，范围在后）
`

---

## 五、索引设计实战原则

`sql
-- 原则 1：区分度高的列放左边
-- 性别（0/1）区分度极低，放左边几乎无效
-- ❌
CREATE INDEX idx ON users(gender, user_id);
-- ✅
CREATE INDEX idx ON users(user_id, gender);

-- 原则 2：ORDER BY 列加入索引，避免 filesort
-- 查询：WHERE user_id = 1 ORDER BY create_time DESC
-- ✅ 联合索引覆盖 WHERE + ORDER BY
CREATE INDEX idx_user_create ON orders(user_id, create_time);

-- 原则 3：覆盖索引避免回表
-- 查询：SELECT id, name, email FROM users WHERE name = 'Alice'
-- ✅ 索引包含查询的所有字段，无需回表
CREATE INDEX idx_cover ON users(name, id, email);

-- 原则 4：控制索引数量（每个表建议不超过 5 个索引）
-- 索引占存储，且写操作需要维护所有索引，过多索引拖慢写性能
`

---

## 六、常见坑点与最佳实践

### 坑 1：在低区分度列建索引

`sql
-- ❌ status 只有 3 个值（pending/paid/cancelled），区分度极低
-- 走索引反而比全表扫描慢（索引回表成本高）
CREATE INDEX idx_status ON orders(status);

-- ✅ 与高区分度列组合
CREATE INDEX idx_user_status ON orders(user_id, status);
`

### 坑 2：对索引列做运算/函数

`sql
-- ❌ 索引失效
WHERE DATE(create_time) = '2024-01-01'
WHERE LOWER(name) = 'alice'
WHERE id + 1 = 100

-- ✅ 将运算移到等号右侧
WHERE create_time >= '2024-01-01 00:00:00' AND create_time < '2024-01-02 00:00:00'
WHERE name = 'alice'  -- 使用 utf8mb4_ci 排序规则
WHERE id = 99
`

---

## 七、总结与延伸

**核心要点**：
- B+树非叶节点只存键，叶节点存数据，双向链表支持范围查询，树高通常 3-4 层
- 聚簇索引 = 数据本身，主键推荐自增整数；二级索引叶节点存主键，查询完整数据需要回表
- 复合索引遵循**最左前缀原则**，范围查询后的列不走索引
- 覆盖索引避免回表，是查询优化的利器

**延伸阅读方向**：
- InnoDB 页结构：16KB 的数据页内部如何组织行数据
- 索引合并（Index Merge）：OR 条件时 MySQL 如何合并多个索引的结果
- 自适应哈希索引：InnoDB 在热点等值查询时自动建立的内存哈希索引
- 全文索引（FULLTEXT）：倒排索引实现，适合文本搜索（大文本推荐 Elasticsearch）
