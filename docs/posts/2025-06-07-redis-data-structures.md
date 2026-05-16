# Redis 数据结构底层实现（ziplist/skiplist）

<div class="post-meta">📅 2025-06-07 &nbsp;·&nbsp; 🏷️ <span class="tag">Redis</span></div>

## 一、Redis 数据结构概览

Redis 对每种数据类型提供了多种底层编码实现，根据数据量大小和内容动态切换，以平衡内存使用和性能。

| 数据类型 | 小数据编码 | 大数据编码 |
|---------|-----------|-----------|
| String | int / embstr | raw（SDS） |
| Hash | listpack（ziplist） | hashtable |
| List | listpack（ziplist） | quicklist |
| Set | listpack / intset | hashtable |
| ZSet | listpack（ziplist） | skiplist + hashtable |

> Redis 7.0 开始将 ziplist 升级为 listpack，但原理类似。

## 二、String：SDS（简单动态字符串）

```c
struct sdshdr {
    int len;    // 已使用长度
    int free;   // 剩余空间
    char buf[]; // 实际字节数组（以 '\0' 结尾）
};
```

**三种编码方式：**

| 编码 | 条件 | 说明 |
|------|------|------|
| int | 存储整数且可用 long 表示 | 直接存整数值 |
| embstr | 字符串长度 ≤ 44 字节 | 一次内存分配，连续存储 |
| raw | 字符串长度 > 44 字节 | 两次内存分配，指针指向 SDS |

```bash
# 验证编码
SET name "Alice"
OBJECT ENCODING name       # embstr

SET count 100
OBJECT ENCODING count      # int

SET desc "这是一段超过44字节的很长很长很长很长的描述文字"
OBJECT ENCODING desc       # raw
```

**SDS 优势：**

| 特性 | C 字符串 | SDS |
|------|---------|-----|
| 获取长度 | O(n) 遍历 | O(1) 直接读 len |
| 内存安全 | 可能缓冲区溢出 | 自动扩容 |
| 二进制安全 | 遇 '\0' 截断 | 按 len 读取 |
| 内存预分配 | 无 | 有，减少重分配次数 |

## 三、Hash：ziplist → hashtable

### 3.1 ziplist（紧凑列表）

当 Hash 满足以下条件时，使用 ziplist 编码：
- 键值对数量 ≤ `hash-max-ziplist-entries`（默认128）
- 所有键和值的字节数 ≤ `hash-max-ziplist-value`（默认64字节）

```
ziplist 内存布局：
┌──────┬──────┬──────────┬─────────────────────────────┬──────┐
│zlbytes│zltail│  zllen   │  entry1 | entry2 | entry3  │ zlend│
│ 4字节 │ 4字节│  2字节   │  各个元素（连续内存）         │ 0xFF │
└──────┴──────┴──────────┴─────────────────────────────┴──────┘

每个 entry 结构：
┌──────────────────┬──────────────┬──────┐
│ prevrawlensize   │  encoding    │ data │
│ (前一个节点长度)  │ (编码类型)   │ (值) │
└──────────────────┴──────────────┴──────┘
```

**ziplist 优点：** 内存连续，节省空间，无指针开销  
**ziplist 缺点：** 更新可能引发连锁更新（cascade update），数据量大时性能下降

### 3.2 hashtable 编码

```
dictht（哈希表）:
┌──────────────────────────────────────┐
│ table:  [ 0 ][ 1 ][ 2 ]...[ size-1 ]│  ← dictEntry 指针数组
│ size:   2^n                          │
│ sizemask: size-1                     │
│ used:   已有元素数量                  │
└──────────────────────────────────────┘

冲突处理：链地址法（链表，新节点头插）
扩容条件：used / size > 1（负载因子 > 1）
渐进式 rehash：分多次迁移，避免阻塞
```

```bash
# 查看 Hash 编码
HSET user:1 name Alice age 25 email alice@example.com
OBJECT ENCODING user:1    # listpack（数据少）

# 触发编码转换
python3 -c "
import redis
r = redis.Redis()
for i in range(200):
    r.hset('user:1', f'field{i}', f'value{i}')
"
OBJECT ENCODING user:1    # hashtable
```

## 四、List：quicklist

Redis 3.2 后，List 使用 quicklist（由多个 ziplist 节点组成的双向链表）。

```
quicklist 结构：
head ←→ [ziplist节点] ←→ [ziplist节点] ←→ [ziplist节点] ←→ tail

每个 ziplist 节点包含多个元素（默认最多128个）

好处：
- ziplist 节省内存（连续存储）
- 双向链表支持头尾快速插入
- 兼顾内存和性能
```

```bash
# List 时间复杂度
LPUSH / RPUSH   O(1)   # 头/尾插入
LPOP / RPOP     O(1)   # 头/尾弹出
LINDEX          O(n)   # 按下标访问
LRANGE          O(S+N) # 范围查询
LINSERT         O(n)   # 中间插入
```

## 五、Set：intset / hashtable

### 5.1 intset（整数集合）

当 Set 全部是整数且数量 ≤ `set-max-intset-entries`（默认512）时：

```
intset 结构：
┌──────────┬────────┬──────────────────────┐
│ encoding │ length │ contents[]（有序整数）│
│  int16/32│        │  [1, 2, 5, 10, 100] │
└──────────┴────────┴──────────────────────┘

查找：二分查找 O(log n)
升级：当插入更大整数时，自动升级 encoding
```

### 5.2 Set 使用场景

```bash
# 标签系统（用户标签）
SADD user:1:tags "java" "mysql" "redis"
SADD user:2:tags "java" "python" "mysql"

# 交集：共同标签
SINTER user:1:tags user:2:tags    # java, mysql

# 并集：所有标签
SUNION user:1:tags user:2:tags

# 差集：user1 有但 user2 没有
SDIFF user:1:tags user:2:tags     # redis

# 随机弹出（抽奖）
SPOP prize:pool 1
```

## 六、ZSet：skiplist + hashtable

### 6.1 跳跃表结构

跳跃表（skiplist）是链表的变体，通过多层索引加速查找：

```
跳跃表示意图（分值从小到大）：

Level 4:  [header] ─────────────────────────────────→ [NULL]
Level 3:  [header] ──────────── [20] ────────────────→ [NULL]
Level 2:  [header] ──── [10] ── [20] ──── [40] ───────→ [NULL]
Level 1:  [header] ─[5]─[10]─[15]─[20]─[30]─[40]─[50]→ [NULL]

查找 30：
① L4: header → NULL（跳过）
② L3: header → 20 → NULL（20 < 30，继续）
③ L2: 20 → 40（40 > 30，降层）
④ L1: 20 → 30 ✓ 找到！

查找复杂度：O(log n)
插入/删除：O(log n)
```

**为什么用跳跃表而不是红黑树？**

| 特性 | 跳跃表 | 红黑树 |
|------|-------|-------|
| 实现复杂度 | 简单 | 复杂（旋转操作） |
| 范围查询 | 高效（链表遍历） | 较复杂 |
| 内存占用 | 略多（多层指针） | 固定 |
| 并发性 | 锁粒度更细 | 需要复杂并发控制 |

### 6.2 ZSet 双结构设计

```
ZSet 同时维护两种结构：
- skiplist：按分值排序，支持范围查询（ZRANGE/ZREVRANGE）
- hashtable：O(1) 根据成员名查分值（ZSCORE）

skiplist:  score → member（有序）
hashtable: member → score（哈希映射）

内存换性能：多占一份内存，但两种操作都是最优复杂度
```

```bash
# ZSet 常用命令
ZADD leaderboard 100 "Alice" 200 "Bob" 150 "Carol"

# 按分值倒序取前3名
ZREVRANGE leaderboard 0 2 WITHSCORES
# Bob(200) Carol(150) Alice(100)

# 取分值区间
ZRANGEBYSCORE leaderboard 100 200 WITHSCORES

# 获取排名（从0开始）
ZREVRANK leaderboard "Alice"   # 2（第3名）

# 增加分值
ZINCRBY leaderboard 50 "Alice"  # Alice: 150
```

## 七、各数据结构时间复杂度汇总

| 数据类型 | 操作 | 复杂度 |
|---------|------|-------|
| String | GET/SET | O(1) |
| Hash | HGET/HSET | O(1) |
| Hash | HGETALL | O(n) |
| List | LPUSH/RPOP | O(1) |
| List | LRANGE | O(n) |
| Set | SADD/SMEMBERS | O(1)/O(n) |
| Set | SINTER | O(n×m) |
| ZSet | ZADD/ZSCORE | O(log n) |
| ZSet | ZRANGE | O(log n + k) |

## 八、使用场景速查

| 数据类型 | 典型使用场景 |
|---------|------------|
| String | 缓存、计数器、分布式锁（SETNX）、Session |
| Hash | 用户信息、购物车、对象缓存 |
| List | 消息队列、最新N条记录、任务队列 |
| Set | 标签系统、好友关系、去重、抽奖 |
| ZSet | 排行榜、延迟队列（score=执行时间）、热搜 |
