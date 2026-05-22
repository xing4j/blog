# Redis 分布式锁：从 SETNX 到 Redisson 的演进

<div class="post-meta">📅 2024-11-09 &nbsp;·&nbsp; 🏷️ <span class="tag">数据库</span></div>

秒杀场景下，库存扣减必须保证原子性。单机用 synchronized，分布式用什么？Redis 分布式锁是最常见的方案，但从简单的 SETNX 到生产可用，中间有很多坑要踩过——锁释放时机、锁续期、Redlock 的争议，每一个都是面试高频题。

---

## 一、背景：为什么需要分布式锁

多实例部署下，JVM 内的 synchronized/ReentrantLock 只能保证单进程互斥，跨进程的共享资源竞争需要外部协调：

```
实例 A（JVM 1）   实例 B（JVM 2）
     ↓                  ↓
  synchronized     synchronized
  (各自独立，无法互斥)
         ↓↓↓↓↓↓↓
       MySQL / Redis（共享资源）← 竞争！
```
**分布式锁的三个基本要求**：
1. **互斥性**：同一时刻只有一个进程持有锁
2. **安全释放**：只有锁的持有者能释放锁（防止误删他人锁）
3. **防死锁**：持有锁的进程宕机后，锁能自动释放（超时机制）

---

## 二、演进路径：从 SETNX 到 Redisson

### 版本 1：SETNX（有死锁风险）

```java
// ❌ 问题：SETNX 和 EXPIRE 是两个命令，非原子操作
// 若 SETNX 成功后进程崩溃，锁永不释放
redis.setnx("lock:stock", "1");
redis.expire("lock:stock", 30);
```
### 版本 2：SET NX EX（原子性，但有误删风险）

```java
// ✅ 原子性：SET key value NX EX timeout（Redis 2.6.12+）
boolean locked = redis.set("lock:stock", "1", SetParams.setParams().nx().ex(30));

if (locked) {
    try {
        // 业务逻辑
        deductStock();
    } finally {
        redis.del("lock:stock");  // ❌ 问题：可能删除别人的锁！
        // 场景：业务超时 > 锁过期 → 锁被其他进程获取 → 本进程删了别人的锁
    }
}
```
### 版本 3：SET NX EX + 唯一 Value（安全释放）

```java
String lockValue = UUID.randomUUID().toString();  // 唯一标识

boolean locked = redis.set("lock:stock", lockValue, SetParams.setParams().nx().ex(30));

if (locked) {
    try {
        deductStock();
    } finally {
        // ❌ 版本 3 的问题：GET 和 DEL 仍是两步，非原子
        if (lockValue.equals(redis.get("lock:stock"))) {
            redis.del("lock:stock");  // 可能在 GET 和 DEL 之间锁过期又被别人获取
        }
    }
}
```
### 版本 4：Lua 脚本保证释放的原子性（生产可用）

```java
String lockValue = UUID.randomUUID().toString();

boolean locked = redis.set("lock:stock", lockValue, SetParams.setParams().nx().ex(30));

if (locked) {
    try {
        deductStock();
    } finally {
        // ✅ Lua 脚本：GET + DEL 原子执行
        String script = "if redis.call('get', KEYS[1]) == ARGV[1] then " +
                        "    return redis.call('del', KEYS[1]) " +
                        "else return 0 end";
        redis.eval(script, Collections.singletonList("lock:stock"),
                           Collections.singletonList(lockValue));
    }
}
```
### 版本 5：Redisson（生产首选）

Redisson 封装了所有细节，还额外解决了**锁续期（看门狗）**问题：

```java
@Autowired
private RedissonClient redissonClient;

public void deductStock(Long itemId) {
    RLock lock = redissonClient.getLock("lock:stock:" + itemId);

    // 尝试获取锁：最多等待 5s，持有锁最长 30s
    boolean locked = lock.tryLock(5, 30, TimeUnit.SECONDS);
    if (!locked) {
        throw new BusinessException("系统繁忙，请稍后重试");
    }

    try {
        // 业务逻辑
        int stock = stockDao.getStock(itemId);
        if (stock <= 0) throw new BusinessException("库存不足");
        stockDao.deduct(itemId, 1);
    } finally {
        if (lock.isHeldByCurrentThread()) {
            lock.unlock();  // 安全释放（只释放自己的锁）
        }
    }
}
```
**Redisson 看门狗机制**：若未指定 leaseTime，Redisson 默认 30s，并启动后台线程每 10s 续期一次，直到业务方法完成：

```
业务方法执行中
    ↓ 每 10s
Watchdog 线程：SET PX 30000 → 续期
    ↓ 业务完成
unlock()：释放锁，Watchdog 停止
```
---

## 三、Redlock：多节点 Redis 的分布式锁

单节点 Redis 的问题：主节点宕机后，从节点可能尚未同步锁数据，导致锁丢失。

Redlock 使用 **N 个独立 Redis 节点**（推荐 5 个），向多数节点（N/2+1）申请锁：

```java
// Redisson 实现 Redlock
RLock lock1 = redisson1.getLock("lock:stock");
RLock lock2 = redisson2.getLock("lock:stock");
RLock lock3 = redisson3.getLock("lock:stock");

RedissonRedLock redLock = new RedissonRedLock(lock1, lock2, lock3);
redLock.lock();
try {
    // 业务逻辑
} finally {
    redLock.unlock();
}
```
**Redlock 争议**：Redis 作者 Antirez 和 Martin Kleppmann 有著名争论——Redlock 在时钟漂移场景下不是绝对安全的。生产中，若对分布式锁有极高安全要求，考虑 **ZooKeeper** 或 **etcd** 锁（基于强一致性协议 Paxos/Raft）。

---

## 四、分布式锁方案对比

| 方案 | 性能 | 可靠性 | 复杂度 | 适用场景 |
|------|------|--------|--------|---------|
| Redis SETNX + Lua | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | 低 | 大多数业务场景 |
| Redisson | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | 低（封装好）| 生产首选 |
| Redlock | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | 高 | 高可用要求 |
| ZooKeeper | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | 高 | 强一致性要求 |
| 数据库悲观锁 | ⭐⭐ | ⭐⭐⭐⭐⭐ | 低 | 低并发 + 事务场景 |

---

## 五、常见坑点与最佳实践

### 坑 1：锁粒度太粗，退化为单线程

```java
// ❌ 用同一把锁锁住所有商品，并发度降为 1
RLock lock = redissonClient.getLock("lock:stock");

// ✅ 按商品 ID 加锁，不同商品并发不阻塞
RLock lock = redissonClient.getLock("lock:stock:" + itemId);
```
### 坑 2：锁内发送 HTTP 请求，业务超时导致锁过期

```java
// ❌ 锁内调用第三方接口，若超时 > 锁 TTL，锁提前释放
RLock lock = redissonClient.getLock("lock:order");
lock.lock(5, TimeUnit.SECONDS);
try {
    thirdPartyService.call();   // 可能超时
    orderDao.update();           // 此时锁已释放！
} finally {
    lock.unlock();
}

// ✅ 锁内不做 IO，或使用 Redisson 看门狗（不指定 leaseTime）
lock.lock();  // 不指定时间，启用看门狗自动续期
```
### 坑 3：非持有者调用 unlock() 抛异常

```java
// ✅ 释放前检查是否仍持有锁
if (lock.isHeldByCurrentThread()) {
    lock.unlock();
}
```
---

## 六、总结与延伸

**核心要点**：
- 分布式锁三要素：互斥、安全释放（Lua 保原子）、防死锁（TTL）
- 生产使用 **Redisson**：封装了 SET NX EX + Lua 释放 + 看门狗续期，开箱即用
- 锁粒度要细，不要用一把大锁串行所有请求
- Redlock 在多节点 Redis 场景使用，但争议较大，极高一致性要求考虑 ZooKeeper

**延伸阅读方向**：
- Redisson 公平锁、联锁、信号量：更丰富的分布式同步原语
- ZooKeeper 临时节点锁：利用临时节点特性，进程宕机自动释放锁
- 数据库乐观锁（CAS）：UPDATE ... WHERE version = ?，适合低并发写场景
- 幂等设计：分布式锁保证互斥，幂等保证重试安全，两者配合才能真正防重
