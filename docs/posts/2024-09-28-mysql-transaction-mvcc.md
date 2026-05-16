# MySQL 事务隔离级别与 MVCC 原理

<div class="post-meta">📅 2024-09-28 &nbsp;·&nbsp; 🏷️ <span class="tag">MySQL</span> <span class="tag">事务</span></div>

## 一、事务的 ACID 特性

| 特性 | 说明 | InnoDB 实现机制 |
|------|------|----------------|
| 原子性（Atomicity） | 要么全部成功，要么全部回滚 | undo log |
| 一致性（Consistency） | 事务前后数据满足约束 | 原子+隔离+持久共同保证 |
| 隔离性（Isolation） | 并发事务互不干扰 | MVCC + 锁 |
| 持久性（Durability） | 提交后数据永久保存 | redo log |

## 二、并发问题：脏读、不可重复读、幻读

### 2.1 脏读（Dirty Read）

```
事务A                          事务B
BEGIN;                         BEGIN;
UPDATE t SET val=200           
WHERE id=1;  (val原=100)
                               SELECT val FROM t WHERE id=1;
                               -- 读到 200 ← 脏读！B 读到了 A 未提交的数据
ROLLBACK;   (A 回滚)
                               -- B 之前读到的 200 是无效数据
```

### 2.2 不可重复读（Non-Repeatable Read）

```
事务A                          事务B
BEGIN;
SELECT val FROM t WHERE id=1;
-- 读到 100
                               BEGIN;
                               UPDATE t SET val=200 WHERE id=1;
                               COMMIT;
SELECT val FROM t WHERE id=1;
-- 读到 200 ← 不可重复读！同一事务两次读结果不同
COMMIT;
```

### 2.3 幻读（Phantom Read）

```
事务A                          事务B
BEGIN;
SELECT COUNT(*) FROM t 
WHERE age > 18;
-- 返回 5
                               BEGIN;
                               INSERT INTO t (age) VALUES (20);
                               COMMIT;
SELECT COUNT(*) FROM t 
WHERE age > 18;
-- 返回 6 ← 幻读！出现了之前不存在的"幻影行"
COMMIT;
```

## 三、四种隔离级别

```sql
-- 查看当前隔离级别
SELECT @@transaction_isolation;
SHOW VARIABLES LIKE 'transaction_isolation';

-- 设置隔离级别
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET GLOBAL  TRANSACTION ISOLATION LEVEL REPEATABLE READ;
```

| 隔离级别 | 脏读 | 不可重复读 | 幻读 | 性能 |
|---------|------|-----------|------|------|
| READ UNCOMMITTED（读未提交） | ✅ 可能 | ✅ 可能 | ✅ 可能 | 最高 |
| READ COMMITTED（读已提交） | ❌ 避免 | ✅ 可能 | ✅ 可能 | 高 |
| REPEATABLE READ（可重复读）| ❌ 避免 | ❌ 避免 | ⚠️ 部分避免 | 中 |
| SERIALIZABLE（串行化） | ❌ 避免 | ❌ 避免 | ❌ 避免 | 最低 |

> **InnoDB 默认隔离级别：REPEATABLE READ**，通过 MVCC + 间隙锁解决了大部分幻读问题。

## 四、MVCC 核心原理

MVCC（Multi-Version Concurrency Control，多版本并发控制）通过保存数据的历史版本，让读操作不阻塞写操作。

### 4.1 隐藏列

InnoDB 每行数据有三个隐藏列：

```
+------+-------+-------------------+----------+
| id   | name  | DB_TRX_ID         | DB_ROLL_PTR        |
|      |       | (最近修改的事务ID)  | (undo log 回滚指针) |
+------+-------+-------------------+--------------------+
| 1    | Alice | 100               | → undo log 链头    |
+------+-------+-------------------+--------------------+
```

| 隐藏列 | 说明 |
|-------|------|
| DB_TRX_ID | 最近修改该行的事务 ID |
| DB_ROLL_PTR | 指向 undo log 版本链的指针 |
| DB_ROW_ID | 无主键时的隐式行ID（6字节） |

### 4.2 Undo Log 版本链

每次修改数据，旧版本会写入 undo log，形成版本链：

```
当前行（最新）:
  id=1, name="Carol", DB_TRX_ID=300, DB_ROLL_PTR → ↓

undo log 版本2:
  id=1, name="Bob",   DB_TRX_ID=200, DB_ROLL_PTR → ↓

undo log 版本1:
  id=1, name="Alice", DB_TRX_ID=100, DB_ROLL_PTR → NULL
```

### 4.3 ReadView（读视图）

ReadView 是事务在执行快照读时生成的"一致性视图"，决定哪个版本的数据对当前事务可见。

```
ReadView 包含 4 个关键属性：
- m_ids         : 生成 ReadView 时，当前活跃（未提交）的事务ID列表
- min_trx_id    : m_ids 中的最小值
- max_trx_id    : 生成 ReadView 时，下一个待分配的事务ID
- creator_trx_id: 创建该 ReadView 的事务ID
```

**可见性判断规则：**

```
对版本链中某行的 DB_TRX_ID（记为 trx_id）：

if trx_id < min_trx_id:
    可见（该版本在 ReadView 生成前已提交）

elif trx_id >= max_trx_id:
    不可见（该版本在 ReadView 生成后才开始）

elif trx_id in m_ids:
    不可见（该版本所属事务还未提交）

else:
    可见（该版本在 ReadView 生成前已提交，不在活跃列表中）

如果当前版本不可见 → 沿 DB_ROLL_PTR 找上一个版本，继续判断
```

## 五、RC 与 RR 下 ReadView 创建时机差异

这是 RC 和 RR 最核心的区别：

| 隔离级别 | ReadView 创建时机 | 效果 |
|---------|-----------------|------|
| READ COMMITTED | **每次 SELECT 都创建新的 ReadView** | 能读到已提交的最新数据 |
| REPEATABLE READ | **事务第一次 SELECT 时创建，后续复用** | 整个事务看到的是同一快照 |

### 5.1 RC 示例

```
事务A (RC)                      事务B
BEGIN;
SELECT name FROM t WHERE id=1;
-- ReadView1 生成，读到 "Alice"
                                BEGIN;
                                UPDATE t SET name="Bob" WHERE id=1;
                                COMMIT;
SELECT name FROM t WHERE id=1;
-- ReadView2 重新生成，读到 "Bob"  ← 不可重复读
COMMIT;
```

### 5.2 RR 示例

```
事务A (RR)                      事务B
BEGIN;
SELECT name FROM t WHERE id=1;
-- ReadView 生成，m_ids=[trxA]，读到 "Alice"
                                BEGIN;
                                UPDATE t SET name="Bob" WHERE id=1;
                                COMMIT;
SELECT name FROM t WHERE id=1;
-- 复用同一 ReadView，trxB 已提交但 trxB > ReadView 时的活跃状态
-- 仍然读到 "Alice"  ← 可重复读
COMMIT;
```

## 六、当前读 vs 快照读

| 读类型 | 说明 | 示例 |
|-------|------|------|
| 快照读 | 读 MVCC 生成的历史版本，不加锁 | 普通 SELECT |
| 当前读 | 读最新提交版本，加锁 | SELECT ... FOR UPDATE、INSERT/UPDATE/DELETE |

```sql
-- 快照读（走 MVCC，不加锁）
SELECT * FROM t WHERE id = 1;

-- 当前读（读最新版本，加共享锁）
SELECT * FROM t WHERE id = 1 LOCK IN SHARE MODE;

-- 当前读（读最新版本，加排他锁）
SELECT * FROM t WHERE id = 1 FOR UPDATE;

-- 当前读（DML 操作）
UPDATE t SET name = 'xxx' WHERE id = 1;
DELETE FROM t WHERE id = 1;
```

## 七、间隙锁解决幻读

RR 级别下，InnoDB 使用**间隙锁（Gap Lock）**防止幻读：

```sql
-- 事务A
BEGIN;
SELECT * FROM t WHERE age BETWEEN 18 AND 25 FOR UPDATE;
-- 对 (18, 25] 范围加间隙锁

-- 事务B（被阻塞）
INSERT INTO t (age) VALUES (20);  -- ❌ 等待事务A提交
```

### 锁类型对比

| 锁类型 | 说明 | 范围 |
|-------|------|------|
| Record Lock | 锁住单行记录 | 精确匹配 |
| Gap Lock | 锁住索引间隙，防止插入 | 开区间 |
| Next-Key Lock | Record Lock + Gap Lock | 左开右闭区间 |

```
索引值: 10, 20, 30

Next-Key Lock 范围：
(-∞, 10]
(10, 20]
(20, 30]
(30, +∞)
```

## 八、事务实践建议

```sql
-- 1. 显式事务控制
BEGIN;
-- 业务操作
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
COMMIT;

-- 2. 保存点（Savepoint）
BEGIN;
SAVEPOINT sp1;
UPDATE t SET val = 1 WHERE id = 1;
SAVEPOINT sp2;
UPDATE t SET val = 2 WHERE id = 2;
ROLLBACK TO sp1;  -- 只回滚到 sp1，id=1 的修改也被回滚
COMMIT;

-- 3. 查看事务状态
SELECT * FROM information_schema.INNODB_TRX;
SELECT * FROM information_schema.INNODB_LOCKS;       -- MySQL 5.7
SELECT * FROM performance_schema.data_locks;          -- MySQL 8.0
```

### 事务优化建议

| 建议 | 说明 |
|------|------|
| 事务尽量短 | 长事务持有锁时间长，影响并发 |
| 避免在事务中做 RPC | 网络延迟会延长事务持续时间 |
| 及时提交或回滚 | 防止长事务积压 undo log |
| 选合适的隔离级别 | 业务允许则用 RC，减少锁冲突 |
| 注意死锁 | 保持一致的加锁顺序，及时处理死锁告警 |
