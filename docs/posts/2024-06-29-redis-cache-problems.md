# Redis 缓存击穿、穿透、雪崩的解决方案

<div class="post-meta">📅 2024-06-29 &nbsp;·&nbsp; 🏷️ <span class="tag">Redis</span> <span class="tag">缓存</span></div>

## 一、三种问题对比

| 问题 | 定义 | 触发条件 | 危害 |
|------|------|---------|------|
| **缓存穿透** | 查询不存在的数据，缓存和DB都没有 | 恶意请求/误操作 | DB 被大量无效请求打垮 |
| **缓存击穿** | 热点 key 过期，大量请求同时打到 DB | 热点 key 到期 | DB 短时间内突发高负载 |
| **缓存雪崩** | 大量 key 同时过期或 Redis 宕机 | 批量过期/Redis故障 | DB 全量压力，系统崩溃 |

```
三种问题示意：

穿透：  用户请求 → [Redis: 没有] → [DB: 也没有] → 每次都打穿到 DB

击穿：  大量用户 → [热点 key 突然过期] → 所有请求同时涌向 DB

雪崩：  大量 key → [同时批量过期] → DB 接受全量请求 → 系统崩溃
```

## 二、缓存穿透

### 2.1 问题原因

```java
public Product getProduct(Long id) {
    // ❌ 如果 id 不存在，每次都会查 DB
    Product product = redis.get("product:" + id);
    if (product == null) {
        product = db.findById(id);  // DB 查询，结果为 null
        // 没有缓存 null，下次还是打到 DB
    }
    return product;
}
```

### 2.2 解决方案一：缓存空值

```java
public Product getProduct(Long id) {
    String key = "product:" + id;
    String cached = redis.get(key);
    
    if (cached != null) {
        if ("NULL".equals(cached)) {
            return null;  // 命中空值缓存
        }
        return JSON.parseObject(cached, Product.class);
    }
    
    Product product = db.findById(id);
    if (product == null) {
        // ✅ 缓存空值，TTL 设短一些（避免误缓存）
        redis.setex(key, 300, "NULL");  // 5分钟
    } else {
        redis.setex(key, 3600, JSON.toJSONString(product));
    }
    return product;
}
```

**优缺点：**

| 优点 | 缺点 |
|------|------|
| 实现简单 | 浪费缓存空间 |
| 无额外依赖 | 数据不一致窗口（TTL内） |

### 2.3 解决方案二：布隆过滤器

```
布隆过滤器原理：
① 初始化：将所有合法 id 经过 k 个哈希函数映射到位图中

  bit 数组: [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
  写入 id=100：hash1(100)=3, hash2(100)=7, hash3(100)=11
  bit 数组: [0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,0]

② 查询 id=999 时：hash1(999)=1, hash2(999)=5, hash3(999)=11
  检查 bit[1]=0 → 一定不存在 → 直接返回，不查 DB ✓
```

```java
// Guava 布隆过滤器
@Component
public class ProductBloomFilter {

    private static final int EXPECTED_SIZE = 1_000_000;
    private static final double FPP = 0.001;  // 0.1% 误判率

    private BloomFilter<Long> filter = BloomFilter.create(
        Funnels.longFunnel(), EXPECTED_SIZE, FPP
    );

    @PostConstruct
    public void init() {
        // 应用启动时从 DB 加载所有 id
        List<Long> ids = productMapper.findAllIds();
        ids.forEach(filter::put);
    }

    public boolean mightContain(Long id) {
        return filter.mightContain(id);
    }
}

// 在查询前拦截
public Product getProduct(Long id) {
    // ✅ 布隆过滤器拦截不存在的 id
    if (!bloomFilter.mightContain(id)) {
        return null;
    }
    // 继续走缓存 → DB 逻辑
    ...
}
```

**布隆过滤器的特性：**

| 特性 | 说明 |
|------|------|
| 空间效率 | 极高，10亿元素约 1.2GB |
| 查询效率 | O(k)，k 为哈希函数个数 |
| 误判率 | 可能有假阳性（说有实际没有），无假阴性 |
| 局限 | 不支持删除（使用 Counting Bloom Filter 可删除） |

### 2.4 Redis 布隆过滤器（Redisson）

```java
@Autowired
private RedissonClient redisson;

public void initBloomFilter() {
    RBloomFilter<Long> bloomFilter = redisson.getBloomFilter("product:ids");
    bloomFilter.tryInit(1_000_000L, 0.001);
    
    List<Long> ids = productMapper.findAllIds();
    ids.forEach(bloomFilter::add);
}

public Product getProduct(Long id) {
    RBloomFilter<Long> bloomFilter = redisson.getBloomFilter("product:ids");
    if (!bloomFilter.contains(id)) {
        return null;  // 直接拦截
    }
    // 继续查缓存和 DB
}
```

## 三、缓存击穿

### 3.1 解决方案一：互斥锁

```java
public Product getProduct(Long id) {
    String key = "product:" + id;
    Product product = redis.get(key);
    
    if (product != null) {
        return product;
    }
    
    // ✅ 缓存未命中，用互斥锁防止并发打 DB
    String lockKey = "lock:product:" + id;
    boolean locked = redis.setnx(lockKey, "1", 30);  // 30秒超时
    
    if (locked) {
        try {
            // 再次检查（double check）
            product = redis.get(key);
            if (product == null) {
                product = db.findById(id);
                redis.setex(key, 3600, JSON.toJSONString(product));
            }
        } finally {
            redis.del(lockKey);  // 释放锁
        }
    } else {
        // 未获取到锁，稍等后重试
        Thread.sleep(50);
        return getProduct(id);
    }
    return product;
}
```

### 3.2 解决方案二：逻辑过期

```java
// 数据包装类，包含过期时间
@Data
public class CacheWrapper<T> {
    private T data;
    private LocalDateTime expireTime;
}

public Product getProductLogicExpire(Long id) {
    String key = "product:" + id;
    CacheWrapper<Product> wrapper = redis.get(key);  // 不设 TTL，永不过期
    
    if (wrapper == null) {
        return null;  // 未预热的数据直接返回 null
    }
    
    // 检查逻辑过期时间
    if (LocalDateTime.now().isBefore(wrapper.getExpireTime())) {
        return wrapper.getData();  // ✅ 未过期，直接返回
    }
    
    // 逻辑过期，尝试获取锁进行缓存更新
    String lockKey = "lock:product:" + id;
    boolean locked = redis.setnx(lockKey, "1", 30);
    
    if (locked) {
        // 异步更新缓存，当前请求返回旧数据
        executor.submit(() -> {
            try {
                Product newProduct = db.findById(id);
                CacheWrapper<Product> newWrapper = new CacheWrapper<>();
                newWrapper.setData(newProduct);
                newWrapper.setExpireTime(LocalDateTime.now().plusHours(1));
                redis.set(key, JSON.toJSONString(newWrapper));  // 不设 TTL
            } finally {
                redis.del(lockKey);
            }
        });
    }
    
    // 返回旧数据（允许短暂不一致）
    return wrapper.getData();
}
```

**两种方案对比：**

| 方案 | 一致性 | 性能 | 复杂度 |
|------|-------|------|-------|
| 互斥锁 | 强一致 | 等待锁，有延迟 | 简单 |
| 逻辑过期 | 短暂不一致 | 始终返回数据 | 较复杂 |

## 四、缓存雪崩

### 4.1 解决方案一：随机 TTL

```java
public void setProductCache(Long id, Product product) {
    String key = "product:" + id;
    // ✅ 基础 TTL + 随机偏移，避免集中过期
    int baseTTL = 3600;
    int randomOffset = new Random().nextInt(600);  // 0~600 秒随机
    redis.setex(key, baseTTL + randomOffset, JSON.toJSONString(product));
}

// 批量缓存时特别重要
public void batchSetCache(List<Product> products) {
    for (Product product : products) {
        int ttl = 3600 + new Random().nextInt(1800);  // 1小时 ± 30分钟
        redis.setex("product:" + product.getId(), ttl, 
                    JSON.toJSONString(product));
    }
}
```

### 4.2 解决方案二：多级缓存

```
请求路径：用户 → Nginx本地缓存(L1) → JVM本地缓存(L2) → Redis(L3) → DB

L1 Nginx缓存：热点数据，TTL 1分钟
L2 JVM缓存 ：Caffeine，TTL 5分钟
L3 Redis缓存：TTL 1小时
DB：持久层
```

```java
// Caffeine 本地缓存配置
@Bean
public Cache<Long, Product> productLocalCache() {
    return Caffeine.newBuilder()
        .maximumSize(10_000)
        .expireAfterWrite(5, TimeUnit.MINUTES)
        .build();
}

public Product getProduct(Long id) {
    // L2: 本地缓存
    Product product = localCache.getIfPresent(id);
    if (product != null) return product;
    
    // L3: Redis
    String cached = redis.get("product:" + id);
    if (cached != null) {
        product = JSON.parseObject(cached, Product.class);
        localCache.put(id, product);  // 回填 L2
        return product;
    }
    
    // DB
    product = db.findById(id);
    if (product != null) {
        redis.setex("product:" + id, 3600, JSON.toJSONString(product));
        localCache.put(id, product);
    }
    return product;
}
```

### 4.3 解决方案三：熔断降级

```java
// 使用 Resilience4j 熔断
@CircuitBreaker(name = "productService", fallbackMethod = "fallback")
public Product getProduct(Long id) {
    String cached = redis.get("product:" + id);
    if (cached != null) return JSON.parseObject(cached, Product.class);
    return db.findById(id);
}

// 降级方法
public Product fallback(Long id, Exception e) {
    log.warn("Redis/DB 异常，返回降级数据 id={}", id);
    return Product.DEFAULT;  // 返回默认数据或空对象
}
```

```yaml
# Resilience4j 配置
resilience4j:
  circuitbreaker:
    instances:
      productService:
        slidingWindowSize: 10
        failureRateThreshold: 50    # 50% 失败率触发熔断
        waitDurationInOpenState: 10s
        permittedNumberOfCallsInHalfOpenState: 3
```

## 五、完整解决方案汇总

| 问题 | 推荐方案 | 备选方案 |
|------|---------|---------|
| 缓存穿透 | 布隆过滤器 | 缓存空值 |
| 缓存击穿 | 逻辑过期（高可用）| 互斥锁（强一致） |
| 缓存雪崩 | 随机TTL + 多级缓存 | 熔断降级 + Redis集群 |

```java
// 生产级缓存工具类（综合防护）
@Component
public class CacheService {
    
    // 防穿透：缓存空值
    public <T> T get(String key, Long id, Class<T> type,
                      Function<Long, T> dbQuery, long ttl) {
        // 1. 布隆过滤器检查
        if (!bloomFilter.mightContain(id)) {
            return null;
        }
        // 2. 查缓存
        String cached = redis.get(key);
        if (cached != null) {
            return "NULL".equals(cached) ? null : JSON.parseObject(cached, type);
        }
        // 3. 互斥锁防击穿
        String lockKey = "lock:" + key;
        if (redis.setnx(lockKey, "1", 30)) {
            try {
                T data = dbQuery.apply(id);
                // 4. 随机TTL防雪崩
                long finalTTL = ttl + new Random().nextInt((int)(ttl / 6));
                redis.setex(key, finalTTL, data == null ? "NULL" : JSON.toJSONString(data));
                return data;
            } finally {
                redis.del(lockKey);
            }
        }
        // 等待后重试
        Thread.sleep(50);
        return get(key, id, type, dbQuery, ttl);
    }
}
```
