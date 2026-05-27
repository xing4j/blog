# Redis 数据结构深度解析：不只是 String 和 Hash

<div class="post-meta">📅 2025-06-07 &nbsp;·&nbsp; 🏷️ <span class="tag">数据库</span></div>

很多人用 Redis 只用 String 和 Hash，但 Redis 的威力来自于它丰富的数据结构：Set 做交集并集、ZSet 做排行榜、List 做消息队列、HyperLogLog 做大数据基数统计……用对数据结构，代码复杂度降低一个数量级。

---

## 一、背景：Redis 的数据结构与编码

Redis 对外暴露的数据类型（5 种基础 + 3 种特殊）：

```
基础类型：String / List / Hash / Set / ZSet（Sorted Set）
特殊类型：HyperLogLog / Geo / Stream（Redis 5.0+）
```
每种类型内部有多种**编码**（底层实现），根据数据大小自动切换：

| 类型 | 小数据编码 | 大数据编码 |
|------|---------|---------|
| String | int（整数）/ embstr（≤44字节）| raw（SDS）|
| List | listpack（≤128元素，≤64字节）| quicklist |
| Hash | listpack（≤128字段）| hashtable |
| Set | listpack / intset（全整数）| hashtable |
| ZSet | listpack（≤128成员）| skiplist + hashtable |

---

## 二、String：不只是字符串

### 核心命令与应用

```bash
# 基本操作
SET key value EX 3600      # 设置并过期
SETNX key value            # 不存在才设置（分布式锁基础）
GETSET key newval          # 原子获取旧值并设置新值
MGET key1 key2 key3        # 批量获取（减少网络往返）

# 整数操作（原子！）
INCR counter               # 原子自增 1（计数器）
INCRBY counter 100         # 原子增加 100
DECR stock                 # 原子自减（库存扣减）
```
**典型场景**：
- 分布式缓存（SET key value EX ttl）
- 计数器（页面访问量、点赞数）
- 分布式锁（SET key uuid NX EX 30）
- Session 存储

---

## 三、Hash：结构化存储的首选

```bash
HSET user:1 name "Alice" age 25 email "alice@example.com"
HGET user:1 name          # "Alice"
HMGET user:1 name age     # ["Alice", "25"]
HGETALL user:1            # 所有字段
HINCRBY user:1 age 1      # age 原子自增
HDEL user:1 email         # 删除字段
```
**vs String JSON**：

| | Hash 存储 | String JSON |
|--|-----------|------------|
| 部分字段更新 | HSET user:1 age 26（O(1)）| 先 GET 反序列化，改字段，再 SET（3步）|
| 部分字段读取 | HGET user:1 name（O(1)）| GET 全部，反序列化后取字段（浪费）|
| 网络传输 | 按需获取字段 | 每次传完整 JSON |
| 内存 | 小数据 listpack 紧凑 | 需要序列化开销 |

**典型场景**：用户信息、商品详情（频繁读取个别字段）、购物车

---

## 四、List：双向链表的多用途

```bash
LPUSH queue task1 task2 task3   # 左侧插入（栈）
RPUSH queue task4                # 右侧插入（队列）
LPOP queue                       # 左侧弹出
RPOP queue                       # 右侧弹出
BLPOP queue 30                   # 阻塞等待 30 秒（消息队列）
LRANGE queue 0 -1                # 获取全部
LLEN queue                       # 长度
```
**两种使用模式**：

```
消息队列模式（RPUSH + BLPOP）：
生产者：RPUSH tasks "job1"
消费者：BLPOP tasks 0  <- 阻塞等待，有消息立即返回

时间线/最新消息模式（LPUSH + LRANGE + LTRIM）：
每次发布新文章：LPUSH user:1:articles articleId
保留最新 100 篇：LTRIM user:1:articles 0 99
获取最新 10 篇：LRANGE user:1:articles 0 9
```
**限制**：List 作为消息队列不支持消费确认（ACK）和消费者组，生产消息队列推荐 Stream 或 Kafka。

---

## 五、Set：集合运算的利器

```bash
SADD user:1:follow 101 102 103   # 用户 1 关注了 101 102 103
SADD user:2:follow 102 103 104   # 用户 2 关注了 102 103 104

# 集合运算（社交关系常用）
SINTER user:1:follow user:2:follow   # 共同关注：[102, 103]
SUNION user:1:follow user:2:follow   # 合并关注：[101, 102, 103, 104]
SDIFF user:1:follow user:2:follow    # 1 独有的关注：[101]

SISMEMBER user:1:follow 102         # 判断是否关注
SMEMBERS user:1:follow              # 所有关注
SRANDMEMBER lucky:pool 3            # 随机取 3 个（抽奖）
SPOP lucky:pool                     # 随机弹出（不重复抽奖）
```
**典型场景**：关注关系、共同好友、标签系统、抽奖池

---

## 六、ZSet：排行榜的完美工具

ZSet 是带权重（score）的有序集合，每个成员对应一个 double 类型的 score：

```bash
ZADD leaderboard 9800 "Alice"   # 添加分数
ZADD leaderboard 9500 "Bob"
ZADD leaderboard 9900 "Charlie"
ZINCRBY leaderboard 200 "Alice"  # Alice 加 200 分 -> 10000

ZREVRANGE leaderboard 0 9 WITHSCORES    # 排名前10（高分在前）
ZREVRANK leaderboard "Alice"             # Alice 的排名（从0开始）
ZSCORE leaderboard "Alice"               # Alice 的分数
ZRANGEBYSCORE leaderboard 9000 10000    # 9000~10000 分的玩家
```
**内部编码**：小数据用 listpack，大数据用 **跳表（skiplist）**。跳表支持 O(logN) 的插入/删除/查找，且比红黑树更适合按范围查询：

```
跳表结构（简化）：
Level 3: 1 ---------> 9
Level 2: 1 ----> 4 ---> 9
Level 1: 1 -> 2 -> 4 -> 5 -> 9
```
**典型场景**：游戏排行榜、热搜词排序、带权重的任务调度

---

## 七、HyperLogLog：大数据基数统计

```bash
# 统计 UV（每日独立访客），不需要精确值
PFADD uv:2024-01-01 "user1" "user2" "user3"
PFADD uv:2024-01-01 "user1"  # 重复，不会增加

PFCOUNT uv:2024-01-01        # 估算基数（误差 ≤ 0.81%）
PFMERGE uv:week uv:2024-01-01 uv:2024-01-02  # 合并多天 UV
```
**内存极省**：无论集合有多大，每个 HyperLogLog 结构固定占用 12KB。适合不需要精确值的海量基数统计。

---

## 八、对比速查：选哪种数据结构

| 场景 | 推荐类型 | 原因 |
|------|---------|------|
| 缓存 KV，全量读写 | String | 简单快速 |
| 对象字段频繁部分更新 | Hash | 字段级操作 |
| 消息队列（简单）| List（RPUSH+BLPOP）| 有序，支持阻塞 |
| 去重（用户是否点过赞）| Set（SISMEMBER）| O(1) 判断成员 |
| 交集（共同好友）| Set（SINTER）| 原生集合运算 |
| 排行榜 | ZSet | 天然有序，范围查询 |
| 延迟队列 | ZSet（score=执行时间）| 按时间排序，定时取出 |
| UV/DAU 统计 | HyperLogLog | 极省内存，允许误差 |
| 地理位置 | Geo | 支持附近的人、距离计算 |

---

## 九、总结与延伸

**核心要点**：
- 选对数据结构比优化 SQL 更有效，了解每种类型的命令复杂度
- ZSet 的跳表实现支持 O(logN) 操作，是排行榜的完美选择
- HyperLogLog 用 12KB 内存估算亿级基数，误差 ≤ 0.81%
- List 适合简单消息队列，需要 ACK/消费者组时用 Redis Stream

**延伸阅读方向**：
- Redis Stream：Redis 5.0 正式消息队列，支持消费者组和 ACK
- Redis Geo：geohash 编码，实现附近的人/地点搜索
- Redis 内存优化：各数据结构编码阈值调优（hash-max-listpack-entries 等）
- Redis 6.0 多线程：IO 多线程处理，命令执行仍单线程，如何配置
