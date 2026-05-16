# Redis 分布式锁：Redisson 实现原理与坑

<div class="post-meta">📅 2024-11-09 &nbsp;·&nbsp; 🏷️ <span class="tag">Redis</span> <span class="tag">分布式</span></div>

## 一、为什么需要分布式锁？

```
单机环境：synchronized / ReentrantLock 即可解决并发问题

分布式环境：
  服务A（节点1）  ←─── 同一资源 ───→  服务A（节点2）
  synchronized 只在各自 JVM 内生效，无法跨进程加锁

需要分布式锁！
```

**分布式锁的要求：**

| 要求 | 说明 |
|------|------|
| 互斥性 | 同一时刻只有一个客户端持有锁 |
| 不死锁 | 客户端崩溃后锁能自动释放 |
| 可重入 | 同一客户端可以多次加锁 |
| 高可用 | Redis 宕机不影响业务 |
| 安全释放 | 只能由加锁的客户端释放锁 |

## 二、SETNX 原生实现及问题

### 2.1 基础实现

```java
// ❌ 早期实现（问题多）
public boolean lock(String key) {
    return redis.setnx(key, "1");  // 1: 加锁成功，0: 已被占用
}

public void unlock(String key) {
    redis.del(key);
}
```

**问题一：忘记设置过期时间 → 死锁**

```java
// ❌ 如果在 setnx 和 expire 之间崩溃 → 死锁
redis.setnx(key, "1");
// 程序崩溃！
redis.expire(key, 30);

// ✅ 原子操作
redis.set(key, "1", "NX", "EX", 30);  // NX + EX 原子设置
```

### 2.2 完整的 SETNX 实现

```java
@Component
public class RedisLock {

    @Autowired
    private StringRedisTemplate redisTemplate;

    private static final String UNLOCK_SCRIPT =
        "if redis.call('get', KEYS[1]) == ARGV[1] then " +
        "    return redis.call('del', KEYS[1]) " +
        "else " +
        "    return 0 " +
        "end";

    /**
     * 加锁
     * @param key      锁 key
     * @param value    唯一标识（UUID），防止误删他人的锁
     * @param timeout  超时秒数
     */
    public boolean lock(String key, String value, long timeout) {
        Boolean result = redisTemplate.opsForValue()
            .setIfAbsent(key, value, timeout, TimeUnit.SECONDS);
        return Boolean.TRUE.equals(result);
    }

    /**
     * 解锁（Lua 脚本保证原子性）
     */
    public boolean unlock(String key, String value) {
        DefaultRedisScript<Long> script = new DefaultRedisScript<>(UNLOCK_SCRIPT, Long.class);
        Long result = redisTemplate.execute(script,
            Collections.singletonList(key), value);
        return Long.valueOf(1L).equals(result);
    }
}

// 使用示例
public void placeOrder(Long userId) {
    String lockKey = "lock:order:" + userId;
    String lockValue = UUID.randomUUID().toString();

    boolean locked = redisLock.lock(lockKey, lockValue, 30);
    if (!locked) {
        throw new BizException("操作频繁，请稍后再试");
    }
    try {
        // 核心业务逻辑
        doPlaceOrder(userId);
    } finally {
        redisLock.unlock(lockKey, lockValue);
    }
}
```

### 2.3 SETNX 的剩余问题

| 问题 | 说明 |
|------|------|
| 锁续期 | 业务超时后锁自动释放，但业务还在执行 → 并发问题 |
| 不可重入 | 同一线程再次加锁会失败 |
| 主从切换 | 主库写入后未同步从库，主库宕机，从库晋升后锁丢失 |

## 三、Redisson 分布式锁

### 3.1 引入依赖

```xml
<dependency>
    <groupId>org.redisson</groupId>
    <artifactId>redisson-spring-boot-starter</artifactId>
    <version>3.23.5</version>
</dependency>
```

### 3.2 配置

```yaml
spring:
  redis:
    host: localhost
    port: 6379
    password: ""

# 或使用 redisson 独立配置
redisson:
  config: |
    singleServerConfig:
      address: "redis://localhost:6379"
      password: ""
      connectionPoolSize: 64
      connectionMinimumIdleSize: 24
```

### 3.3 基础使用

```java
@Autowired
private RedissonClient redisson;

public void placeOrder(Long userId) {
    RLock lock = redisson.getLock("lock:order:" + userId);
    
    // 方式一：默认加锁（30s 自动续期）
    lock.lock();
    try {
        doPlaceOrder(userId);
    } finally {
        lock.unlock();
    }
}

public void placeOrderWithTimeout(Long userId) {
    RLock lock = redisson.getLock("lock:order:" + userId);
    
    // 方式二：指定等待时间和加锁时间（不自动续期）
    boolean locked = false;
    try {
        locked = lock.tryLock(5, 30, TimeUnit.SECONDS);
        // waitTime=5s（等待5秒还没获取则放弃），leaseTime=30s（30秒后自动释放）
        if (locked) {
            doPlaceOrder(userId);
        } else {
            throw new BizException("系统繁忙，请稍后重试");
        }
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
    } finally {
        if (locked) {
            lock.unlock();
        }
    }
}
```

## 四、WatchDog 自动续期原理

```
WatchDog 机制（仅在不指定 leaseTime 时生效）：

客户端加锁（默认 leaseTime = 30s）
        ↓
启动后台线程（每 10s 检查一次 = leaseTime / 3）
        ↓
如果持锁线程还在运行 → 将 TTL 重置为 30s（续期）
        ↓
如果持锁线程终止（宕机/异常）→ WatchDog 也停止 → TTL 自然过期 → 锁释放
```

```java
// Redisson 源码（简化）
private void scheduleExpirationRenewal(long threadId) {
    ExpirationEntry entry = new ExpirationEntry();
    
    Timeout task = commandExecutor.getConnectionManager().newTimeout(
        new TimerTask() {
            @Override
            public void run(Timeout timeout) {
                // 每 internalLockLeaseTime / 3 执行一次
                renewExpirationAsync(threadId);  // 续期
            }
        }, 
        internalLockLeaseTime / 3,   // 延迟时间（10s）
        TimeUnit.MILLISECONDS
    );
}

// 续期 Lua 脚本
private static final String RENEW_EXPIRATION_SCRIPT =
    "if (redis.call('hexists', KEYS[1], ARGV[2]) == 1) then " +
    "    redis.call('pexpire', KEYS[1], ARGV[1]); " +
    "    return 1; " +
    "end; " +
    "return 0;";
```

## 五、可重入锁原理（Hash 结构）

Redisson 使用 **Hash** 结构存储锁，支持可重入：

```
Redis Hash 结构：
key:   "lock:order:123"
field: "uuid:thread_id"（客户端唯一标识 + 线程ID）
value: 重入次数

加锁一次后：
HSET "lock:order:123" "uuid-xxx:thread-1" 1   TTL=30s

同一线程再次加锁（可重入）：
HINCRBY "lock:order:123" "uuid-xxx:thread-1" 1 → value=2

解锁一次：
HINCRBY "lock:order:123" "uuid-xxx:thread-1" -1 → value=1

再次解锁：
HINCRBY "lock:order:123" "uuid-xxx:thread-1" -1 → value=0
DEL "lock:order:123"  ← 彻底释放
```

```java
// 加锁 Lua 脚本（简化）
private static final String LOCK_SCRIPT =
    // 锁不存在
    "if (redis.call('exists', KEYS[1]) == 0) then " +
    "    redis.call('hincrby', KEYS[1], ARGV[2], 1); " +
    "    redis.call('pexpire', KEYS[1], ARGV[1]); " +
    "    return nil; " +
    "end; " +
    // 是自己的锁（可重入）
    "if (redis.call('hexists', KEYS[1], ARGV[2]) == 1) then " +
    "    redis.call('hincrby', KEYS[1], ARGV[2], 1); " +
    "    redis.call('pexpire', KEYS[1], ARGV[1]); " +
    "    return nil; " +
    "end; " +
    // 被其他客户端持有
    "return redis.call('pttl', KEYS[1]);";
```

## 六、RedLock 算法

解决**主从切换**导致的锁丢失问题：

```
RedLock 原理（需要 N 个独立的 Redis 主节点，通常 N=5）：

① 记录开始时间 startTime
② 向 5 个 Redis 节点依次尝试加锁（每个节点超时时间短：约 50ms）
③ 如果超过半数节点（≥ 3个）加锁成功，且耗时 < TTL：
   → 加锁成功！有效锁时长 = TTL - 耗时
④ 否则：向所有节点发送解锁命令，加锁失败

容忍故障：5 个节点最多可以有 2 个宕机，仍能正常工作
```

```java
// Redisson RedLock 使用
RLock lock1 = redisson1.getLock("distributed-lock");
RLock lock2 = redisson2.getLock("distributed-lock");
RLock lock3 = redisson3.getLock("distributed-lock");

RedissonRedLock redLock = new RedissonRedLock(lock1, lock2, lock3);

boolean locked = redLock.tryLock(100, 10000, TimeUnit.MILLISECONDS);
if (locked) {
    try {
        // 业务逻辑
    } finally {
        redLock.unlock();
    }
}
```

## 七、常见坑

### 7.1 主从切换锁丢失

```
问题：
  主库加锁成功（写入 key）
  主库宕机，尚未同步到从库
  从库晋升为主库
  另一个客户端成功加锁（锁已不存在）
  ← 两个客户端同时持有锁！

解决：
  方案1：使用 RedLock（多节点）
  方案2：业务层面做幂等性保障
  方案3：Zookeeper 分布式锁（CP 系统，一致性更强）
```

### 7.2 锁超时业务未完成

```java
// ❌ 指定了 leaseTime=5s，但业务可能超过 5s
lock.tryLock(1, 5, TimeUnit.SECONDS);

// ✅ 不指定 leaseTime，启用 WatchDog 自动续期
lock.lock();  // 默认 30s + 自动续期

// ✅ 或者估算业务时间后留足余量
lock.tryLock(1, 60, TimeUnit.SECONDS);  // 给足 60s
```

### 7.3 忘记释放锁

```java
// ❌ 异常时未释放锁
lock.lock();
doSomething();   // 如果这里抛出异常，锁永远不会释放（直到 TTL）
lock.unlock();

// ✅ 使用 try-finally
lock.lock();
try {
    doSomething();
} finally {
    lock.unlock();  // 保证释放
}
```

### 常见坑汇总

| 坑 | 原因 | 解决方案 |
|----|------|---------|
| 死锁 | 未设置 TTL / 未释放锁 | try-finally + TTL |
| 锁超时 | 业务时间 > 锁 TTL | WatchDog 续期 |
| 误删他人锁 | 未携带唯一标识 | UUID 标识 + Lua 原子删除 |
| 主从锁丢失 | 主从异步复制 | RedLock / Zookeeper |
| 非公平竞争 | 大量线程抢锁 | 公平锁 `getFairLock()` |

## 八、Redisson 其他锁类型

```java
// 公平锁（FIFO 顺序）
RLock fairLock = redisson.getFairLock("fairLock");

// 读写锁
RReadWriteLock rwLock = redisson.getReadWriteLock("rwLock");
rwLock.readLock().lock();   // 读锁（允许多个）
rwLock.writeLock().lock();  // 写锁（互斥）

// 信号量
RSemaphore semaphore = redisson.getSemaphore("semaphore");
semaphore.trySetPermits(10);  // 允许 10 个并发
semaphore.acquire();
semaphore.release();

// 倒计时锁
RCountDownLatch latch = redisson.getCountDownLatch("latch");
latch.trySetCount(3);
latch.await();      // 等待计数到 0
latch.countDown();  // 计数减1
```
