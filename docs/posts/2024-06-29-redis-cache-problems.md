# Redis 缓存三大问题：穿透、击穿、雪崩的根因与解法

<div class="post-meta">📅 2024-06-29 &nbsp;·&nbsp; 🏷️ <span class="tag">数据库</span></div>

大促前一晚，缓存预热方案没到位，流量涌入时 Redis 挡不住，数据库瞬间被压垮——这三种场景各有名字：穿透、击穿、雪崩。它们听起来相似，根因和解法却截然不同，生产系统必须每一种都有对应预案。

---

## 一、背景：缓存的保护作用与失效场景

正常缓存流程：

```
请求 → Redis（命中）→ 直接返回
请求 → Redis（未命中）→ 查 DB → 写 Redis → 返回
```
当缓存保护失效，大量请求直接打到数据库，导致 DB 过载。三种失效场景：

| 问题 | 根因 | 影响 |
|------|------|------|
| **缓存穿透** | 查询不存在的数据，缓存和 DB 都没有 | 每次都穿透到 DB |
| **缓存击穿** | 热点 Key 过期瞬间，大量并发请求同时查 DB | 短时数据库压力激增 |
| **缓存雪崩** | 大量 Key 同时过期，或 Redis 宕机 | 大规模流量涌入 DB |

---

## 二、缓存穿透：查询不存在的数据

### 问题场景

攻击者或异常请求用大量不存在的 ID（如 -1、9999999）查询，缓存无法命中，每次都查 DB：

```
请求 id=-1 → Redis 未命中 → DB 查询（无结果）→ 不缓存 → 下次请求继续打 DB
```
### 解法 1：缓存空值（最简单）

```java
public Product getProduct(Long id) {
    String key = "product:" + id;
    String cached = redis.get(key);

    if (cached != null) {
        if ("NULL".equals(cached)) return null;  // 命中空值缓存
        return JSON.parseObject(cached, Product.class);
    }

    Product product = productDao.findById(id);
    if (product == null) {
        redis.setex(key, 300, "NULL");   // 缓存空值，TTL 短一些（5分钟）
    } else {
        redis.setex(key, 3600, JSON.toJSONString(product));
    }
    return product;
}
```
**缺点**：大量不同 ID 的无效请求会占用 Redis 内存。

### 解法 2：布隆过滤器（推荐）

布隆过滤器能快速判断一个元素**是否一定不存在**（有假阳性，无假阴性）：

```java
@Component
public class BloomFilterService {
    // 使用 Guava BloomFilter 或 Redisson RBloomFilter
    private final BloomFilter<Long> productFilter =
        BloomFilter.create(Funnels.longFunnel(), 1_000_000, 0.01);  // 100万个元素，1%误判率

    @PostConstruct
    public void init() {
        // 启动时将所有合法的 product ID 写入布隆过滤器
        productDao.findAllIds().forEach(productFilter::put);
    }

    public Product getProduct(Long id) {
        // 布隆过滤器判断：一定不存在则直接返回 null，不查缓存和 DB
        if (!productFilter.mightContain(id)) {
            return null;
        }
        // 通过布隆过滤器后，再走缓存逻辑
        return getFromCacheOrDB(id);
    }
}
```
---

## 三、缓存击穿：热点 Key 瞬间过期

### 问题场景

一个热点商品（如 iPhone 新品）缓存恰好过期，此时有 10000 个并发请求同时到来，全部穿透到 DB：

```
t=100s：热点 Key 过期
t=100s~100.1s：10000个请求 → 全部 Redis 未命中 → 全部去查 DB → DB 扛不住
```
### 解法 1：互斥锁（Mutex Lock）

只允许一个线程去重建缓存，其他线程等待或返回旧值：

```java
public Product getProduct(Long id) {
    String key = "product:" + id;
    String cached = redis.get(key);
    if (cached != null) return JSON.parseObject(cached, Product.class);

    // 未命中，尝试获取分布式锁
    String lockKey = "lock:product:" + id;
    boolean locked = redis.setIfAbsent(lockKey, "1", 10, TimeUnit.SECONDS);  // SET NX EX 10

    if (locked) {
        try {
            // 双重检查：获取锁后再查一次缓存（可能已被其他线程写入）
            cached = redis.get(key);
            if (cached != null) return JSON.parseObject(cached, Product.class);

            Product product = productDao.findById(id);
            redis.setex(key, 3600, JSON.toJSONString(product));
            return product;
        } finally {
            redis.delete(lockKey);
        }
    } else {
        // 未获得锁，短暂等待后重试（或返回降级数据）
        Thread.sleep(50);
        return getProduct(id);  // 递归重试
    }
}
```
### 解法 2：逻辑过期（不设 TTL，异步更新）

```java
public class CacheData {
    private Object data;
    private long expireTime;  // 逻辑过期时间（非 Redis TTL）
}

public Product getProduct(Long id) {
    String key = "product:" + id;
    CacheData cached = redis.get(key);  // 永不过期，始终有值

    if (cached.getExpireTime() > System.currentTimeMillis()) {
        return (Product) cached.getData();  // 未逻辑过期，直接返回
    }

    // 逻辑过期，异步重建缓存（当前请求仍返回旧数据）
    String lockKey = "lock:product:" + id;
    if (redis.setIfAbsent(lockKey, "1", 10, TimeUnit.SECONDS)) {
        asyncRebuildExecutor.submit(() -> {
            try {
                Product product = productDao.findById(id);
                redis.set(key, new CacheData(product, System.currentTimeMillis() + 3600_000));
            } finally {
                redis.delete(lockKey);
            }
        });
    }

    return (Product) cached.getData();  // 返回稍旧的数据（可接受）
}
```
---

## 四、缓存雪崩：大量 Key 同时失效

### 问题场景

- 场景 A：系统启动时所有缓存设置相同 TTL，导致同时过期
- 场景 B：Redis 宕机或重启，所有缓存消失

### 解法：TTL 随机抖动 + 高可用 + 限流降级

```java
// ✅ 解法 1：TTL 加随机抖动，错开过期时间
int baseTtl = 3600;
int jitter = ThreadLocalRandom.current().nextInt(300);  // 0~300秒随机偏移
redis.setex(key, baseTtl + jitter, value);

// ✅ 解法 2：Redis 高可用（主从+哨兵 或 Cluster）
// 哨兵模式：自动故障转移，单节点故障不影响整体

// ✅ 解法 3：多级缓存（本地 Caffeine + Redis）
// Redis 宕机时，本地缓存仍能抵挡部分流量

// ✅ 解法 4：限流降级（Sentinel/Hystrix）
// 即使缓存全失效，通过限流保护 DB，超出限制的请求返回降级响应
```
---

## 五、三种问题对比速查

| | 缓存穿透 | 缓存击穿 | 缓存雪崩 |
|--|---------|---------|---------|
| **根因** | 查不存在的数据 | 热点 Key 过期 | 大量 Key 同时过期/Redis 宕机 |
| **影响范围** | 特定不存在的 Key | 单个热点 Key | 全部缓存 |
| **解法** | 布隆过滤器 / 缓存空值 | 互斥锁 / 逻辑过期 | TTL 抖动 / 高可用 / 限流 |
| **生产首选** | 布隆过滤器 | 逻辑过期（高可用优先）| TTL 抖动 + 哨兵/Cluster |

---

## 六、总结与延伸

**三句话记住三个问题**：
- **穿透**：请求的数据根本不存在，用**布隆过滤器**在入口拦截
- **击穿**：热点数据恰好过期，用**互斥锁**或**逻辑过期**控制重建并发
- **雪崩**：大批数据同时过期，用 **TTL 抖动** + Redis **高可用** + **限流降级** 兜底

**延伸阅读方向**：
- Redisson RBloomFilter：基于 Redis 的分布式布隆过滤器，支持多节点
- 本地缓存 Caffeine：与 Redis 构建两级缓存，增强抗雪崩能力
- Sentinel 热点参数限流：针对热点 Key 的细粒度限流规则
- 缓存预热策略：系统启动时主动加载热点数据，避免冷启动穿透
