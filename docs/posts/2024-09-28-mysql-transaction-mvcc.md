# MySQL 事务与 MVCC：隔离级别背后的读视图机制

<div class="post-meta">📅 2024-09-28 &nbsp;·&nbsp; 🏷️ <span class="tag">数据库</span></div>

可重复读隔离级别下，同一个事务两次读取同一行，结果必须相同——即使另一个事务在中间修改并提交了。MySQL InnoDB 不是靠锁来实现这个保证的，而是靠 **MVCC（多版本并发控制）**。理解 MVCC 和读视图，才能真正搞清楚事务的隔离是如何工作的。

---

## 一、背景：四种隔离级别与并发问题

| 隔离级别 | 脏读 | 不可重复读 | 幻读 |
|---------|------|---------|------|
| READ UNCOMMITTED | ✅ 可能 | ✅ 可能 | ✅ 可能 |
| READ COMMITTED | ❌ 不会 | ✅ 可能 | ✅ 可能 |
| REPEATABLE READ（默认）| ❌ 不会 | ❌ 不会 | ⚠️ 快照读不会，当前读可能 |
| SERIALIZABLE | ❌ 不会 | ❌ 不会 | ❌ 不会 |

- **脏读**：读到其他事务未提交的数据
- **不可重复读**：同一事务两次读同一行，结果不同（另一事务修改并提交了）
- **幻读**：同一事务两次范围查询，结果集行数不同（另一事务插入了新行）

**MySQL InnoDB 默认隔离级别是 REPEATABLE READ**，且通过 MVCC + Gap Lock 解决了大部分幻读问题。

---

## 二、MVCC 的核心组件

### 2.1 隐藏列

InnoDB 为每行数据隐式添加两列：

```
┌──────┬─────────┬──────────┬────────────┐
│ id   │ name    │ DB_TRX_ID│ DB_ROLL_PTR│
├──────┼─────────┼──────────┼────────────┤
│  1   │ "Alice" │    101   │ → undo log  │
└──────┴─────────┴──────────┴────────────┘
DB_TRX_ID：最后修改该行的事务 ID（单调递增）
DB_ROLL_PTR：回滚指针，指向 undo log 中的旧版本
```
### 2.2 Undo Log（版本链）

每次修改行数据时，旧版本写入 undo log，通过回滚指针形成版本链：

```
当前版本（DB_TRX_ID=103）name="Charlie"
    ↓ DB_ROLL_PTR
  旧版本（DB_TRX_ID=101）name="Bob"
    ↓ DB_ROLL_PTR
  更旧版本（DB_TRX_ID=98）name="Alice"
    ↓ DB_ROLL_PTR
  NULL（最初版本）
```
### 2.3 Read View（读视图）

Read View 是事务开启快照时的"快照镜头"，记录：

```java
ReadView {
    m_ids: [101, 102, 103]  // 生成 ReadView 时，所有活跃（未提交）的事务 ID 列表
    min_trx_id: 101          // m_ids 中最小值
    max_trx_id: 104          // 下一个将分配的事务 ID（已分配最大 + 1）
    creator_trx_id: 102      // 创建该 ReadView 的事务 ID
}
```
**可见性判断规则**（对版本链中某个版本的 rrx_id 判断）：

```
1. trx_id == creator_trx_id → 可见（自己修改的，能看到）
2. trx_id < min_trx_id      → 可见（已提交的旧事务）
3. trx_id >= max_trx_id     → 不可见（生成 ReadView 之后开启的事务）
4. min_trx_id <= trx_id < max_trx_id：
   - trx_id 在 m_ids 中  → 不可见（活跃未提交事务）
   - trx_id 不在 m_ids 中 → 可见（已提交事务）
```
---

## 三、REPEATABLE READ vs READ COMMITTED 的区别

**关键区别只有一个**：Read View 何时生成。

- **READ COMMITTED**：每次 SELECT 都生成新的 Read View → 每次都能读到最新已提交数据（不可重复读）
- **REPEATABLE READ**：事务中第一次 SELECT 时生成 Read View，之后复用 → 整个事务看到的数据一致（可重复读）

### 示例：理解可重复读

```
时间线：
T1 开启事务，Read View: m_ids=[T1], min=T1, max=T2
T2 开启事务，修改 id=1 的 name 为 "Bob"，提交（T2 的 trx_id 已不在 m_ids 中）
T1 读取 id=1
  → 当前版本 trx_id=T2，在 [min, max) 且不在 m_ids → 可见？
  → 但 T2 在 T1 的 ReadView 生成时是活跃的（T2 > T1，max = T2+1）
  → 实际上 T2 > T1_ReadView 的 max_trx_id-1，属于第 3 条规则：不可见
  → 沿版本链找到 T2 之前的版本（name="Alice"）→ 返回 "Alice"
```
→ 即使 T2 已提交，T1 仍读到 "Alice"，实现了可重复读。

---

## 四、当前读 vs 快照读

| | 快照读（普通 SELECT）| 当前读（加锁操作）|
|--|-------------------|-----------------|
| 读取的数据 | undo log 中的历史快照 | 最新已提交版本 |
| 锁 | 不加锁 | 加共享锁/排他锁 |
| 示例 | SELECT * FROM t WHERE id=1 | SELECT ... FOR UPDATE、INSERT、UPDATE、DELETE |

**幻读问题**：在 REPEATABLE READ 下，快照读不会幻读（因为读的是历史快照），但**当前读可能幻读**：

```sql
-- 事务 A
BEGIN;
SELECT * FROM orders WHERE amount > 100;   -- 快照读：返回 5 条
-- 事务 B 插入一条 amount=200 的记录并提交
SELECT * FROM orders WHERE amount > 100 FOR UPDATE;  -- 当前读：返回 6 条（幻读！）
```
InnoDB 通过 **Gap Lock（间隙锁）** 解决当前读的幻读：对范围内的间隙加锁，阻止其他事务插入。

---

## 五、对比：锁机制 vs MVCC

| | 锁机制 | MVCC |
|--|--------|------|
| 原理 | 读写互斥，写时阻塞读 | 读写不阻塞，保存多版本 |
| 并发度 | 低 | 高 |
| 适用场景 | 当前读（FOR UPDATE）| 快照读（普通 SELECT）|
| 空间开销 | 锁内存 | undo log 存储 |

---

## 六、常见坑点与最佳实践

### 坑 1：长事务让 undo log 膨胀

```sql
-- ❌ 事务持续很久，期间产生的 undo log 无法被清理
-- 因为有活跃事务的 ReadView 还在引用旧版本
BEGIN;
SELECT * FROM big_table;  -- 产生 ReadView
-- ... 几小时后 ...
COMMIT;

-- 查看长事务
SELECT * FROM information_schema.INNODB_TRX WHERE TIME_TO_SEC(TIMEDIFF(NOW(), trx_started)) > 60;
```
### 坑 2：误解 REPEATABLE READ 能防所有幻读

```sql
-- ❌ 当前读（FOR UPDATE）依然会发生幻读
SELECT COUNT(*) FROM orders WHERE user_id = 1;  -- 返回 5
-- 另一个事务插入了一条 user_id=1 的记录并提交
SELECT COUNT(*) FROM orders WHERE user_id = 1 FOR UPDATE;  -- 返回 6 ← 幻读
```
---

## 七、总结与延伸

**核心要点**：
- MVCC 通过隐藏列（DB_TRX_ID）、undo log 版本链、Read View 实现无锁多版本读
- **READ COMMITTED**：每次 SELECT 生成新 Read View；**REPEATABLE READ**：事务首次 SELECT 生成 Read View 并复用
- 快照读用 MVCC，当前读（FOR UPDATE、DML）用锁
- Gap Lock 解决当前读的幻读问题

**延伸阅读方向**：
- InnoDB 锁类型全解：行锁/间隙锁/临键锁/意向锁的加锁规则
- 死锁检测与预防：MySQL 死锁日志分析，innodb_deadlock_detect 参数
- 分布式事务与隔离级别：跨库事务中隔离级别的取舍
- undo log purge 机制：InnoDB 后台线程如何清理不再需要的历史版本
