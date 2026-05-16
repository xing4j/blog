# Spring Cache 注解使用与缓存穿透防护

<div class="post-meta">📅 2025-04-04 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span> <span class="tag">Redis</span> <span class="tag">缓存</span></div>

Spring Cache 提供了统一的缓存抽象，配合 Redis + Caffeine 两级缓存可构建高性能的防穿透方案。

---

## 一、基础注解速览

| 注解 | 作用 | 执行时机 |
|------|------|---------|
| `@Cacheable` | 查询时先读缓存，命中则返回，未命中则执行方法并写入缓存 | 方法执行前判断 |
| `@CachePut` | 总是执行方法，并将结果写入缓存（用于更新） | 方法执行后 |
| `@CacheEvict` | 删除缓存 | 方法执行前或后 |
| `@Caching` | 组合多个缓存操作 | 组合 |
| `@CacheConfig` | 类级别统一配置缓存名称 | 类级别 |

---

## 二、@Cacheable 详解

```java
@Service
public class ProductService {

    // 基本用法：以 id 为 key，缓存到 "products" 命名空间
    @Cacheable(cacheNames = "products", key = "#id")
    public Product findById(Long id) {
        return productMapper.selectById(id); // 仅在缓存未命中时执行
    }

    // 条件缓存：只缓存 id > 0 的查询
    @Cacheable(cacheNames = "products", key = "#id", condition = "#id > 0")
    public Product findByIdConditional(Long id) {
        return productMapper.selectById(id);
    }

    // unless：方法返回 null 时不缓存
    @Cacheable(cacheNames = "products", key = "#id", unless = "#result == null")
    public Product findByIdSafe(Long id) {
        return productMapper.selectById(id);
    }

    // 复合 key
    @Cacheable(cacheNames = "products", key = "#category + ':' + #page")
    public List<Product> findByCategory(String category, int page) {
        return productMapper.selectByCategory(category, page);
    }
}
```

---

## 三、@CachePut 与 @CacheEvict

```java
@Service
@CacheConfig(cacheNames = "products") // 类级别统一设置缓存名
public class ProductService {

    // 更新：总是执行方法，同时更新缓存（保持缓存与数据库一致）
    @CachePut(key = "#product.id")
    public Product update(Product product) {
        productMapper.updateById(product);
        return product;
    }

    // 删除：执行方法后清除指定 key 的缓存
    @CacheEvict(key = "#id")
    public void delete(Long id) {
        productMapper.deleteById(id);
    }

    // 清空整个缓存命名空间（谨慎使用）
    @CacheEvict(allEntries = true)
    public void clearAll() {
        // 批量操作后清空全部
    }

    // beforeInvocation = true：方法执行前删缓存（即使方法抛异常也删）
    @CacheEvict(key = "#id", beforeInvocation = true)
    public void deleteBeforeMethod(Long id) {
        productMapper.deleteById(id);
    }
}
```

---

## 四、@Caching 组合操作

```java
@Service
public class UserService {

    // 一次操作：更新 user 缓存 + 清除 user-list 缓存
    @Caching(
        put  = { @CachePut(cacheNames = "users", key = "#user.id") },
        evict = { @CacheEvict(cacheNames = "user-list", allEntries = true) }
    )
    public User save(User user) {
        userMapper.insertOrUpdate(user);
        return user;
    }
}
```

---

## 五、自定义 KeyGenerator

```java
@Component("myKeyGenerator")
public class MyKeyGenerator implements KeyGenerator {

    @Override
    public Object generate(Object target, Method method, Object... params) {
        StringBuilder sb = new StringBuilder();
        sb.append(target.getClass().getSimpleName()).append(":");
        sb.append(method.getName()).append(":");
        for (Object param : params) {
            sb.append(param).append("_");
        }
        return sb.toString();
    }
}

// 使用自定义 KeyGenerator
@Cacheable(cacheNames = "products", keyGenerator = "myKeyGenerator")
public List<Product> search(String keyword, String category, int page) {
    return productMapper.search(keyword, category, page);
}
```

---

## 六、缓存穿透、击穿、雪崩

```
缓存穿透：查询不存在的数据 → 每次都打到数据库
         ┌────────────────────────────────────────────────────┐
         │ 解决：缓存空值 / 布隆过滤器                          │
         └────────────────────────────────────────────────────┘

缓存击穿：热点 key 过期 → 大量请求同时打到数据库
         ┌────────────────────────────────────────────────────┐
         │ 解决：互斥锁（只让一个请求重建缓存）/ 永不过期         │
         └────────────────────────────────────────────────────┘

缓存雪崩：大量 key 同时过期 / Redis 宕机 → 数据库压力骤增
         ┌────────────────────────────────────────────────────┐
         │ 解决：过期时间加随机值 / Redis 集群 / 熔断降级         │
         └────────────────────────────────────────────────────┘
```

### 穿透防护：缓存空值

```java
@Service
public class ProductService {

    @Autowired
    private StringRedisTemplate redisTemplate;

    @Autowired
    private ProductMapper productMapper;

    private static final String NULL_VALUE = "NULL";
    private static final long NULL_TTL = 2 * 60; // 空值缓存2分钟

    public Product findById(Long id) {
        String key = "product:" + id;
        String cached = redisTemplate.opsForValue().get(key);

        if (cached != null) {
            if (NULL_VALUE.equals(cached)) {
                return null; // 缓存了空值，直接返回 null，不查 DB
            }
            return JSON.parseObject(cached, Product.class);
        }

        // 查数据库
        Product product = productMapper.selectById(id);

        if (product == null) {
            // 缓存空值，防止穿透
            redisTemplate.opsForValue().set(key, NULL_VALUE, NULL_TTL, TimeUnit.SECONDS);
            return null;
        }

        redisTemplate.opsForValue().set(key, JSON.toJSONString(product), 30, TimeUnit.MINUTES);
        return product;
    }
}
```

### 击穿防护：互斥锁重建

```java
public Product findByIdWithLock(Long id) {
    String key = "product:" + id;
    String lockKey = "lock:product:" + id;

    // 先查缓存
    String cached = redisTemplate.opsForValue().get(key);
    if (cached != null) {
        return NULL_VALUE.equals(cached) ? null : JSON.parseObject(cached, Product.class);
    }

    // 缓存未命中，尝试获取互斥锁
    Boolean locked = redisTemplate.opsForValue().setIfAbsent(lockKey, "1", 10, TimeUnit.SECONDS);

    if (Boolean.TRUE.equals(locked)) {
        try {
            // double check：获取锁后再查一次缓存
            cached = redisTemplate.opsForValue().get(key);
            if (cached != null) {
                return NULL_VALUE.equals(cached) ? null : JSON.parseObject(cached, Product.class);
            }
            Product product = productMapper.selectById(id);
            String value = product == null ? NULL_VALUE : JSON.toJSONString(product);
            long ttl = product == null ? NULL_TTL : 30 * 60;
            redisTemplate.opsForValue().set(key, value, ttl, TimeUnit.SECONDS);
            return product;
        } finally {
            redisTemplate.delete(lockKey); // 释放锁
        }
    } else {
        // 未获取到锁，等待后重试
        try { Thread.sleep(50); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        return findByIdWithLock(id);
    }
}
```

### 雪崩防护：随机过期时间

```java
@Configuration
public class RedisCacheConfig {

    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory factory) {
        RedisCacheConfiguration config = RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(30))  // 基础过期时间
            .serializeValuesWith(
                RedisSerializationContext.SerializationPair.fromSerializer(
                    new GenericJackson2JsonRedisSerializer()
                )
            );

        return RedisCacheManager.builder(factory)
            .cacheDefaults(config)
            // 各缓存设置不同过期时间，避免同时过期
            .withCacheConfiguration("products", config.entryTtl(
                Duration.ofMinutes(30 + new Random().nextInt(10))))
            .withCacheConfiguration("users", config.entryTtl(
                Duration.ofMinutes(60 + new Random().nextInt(15))))
            .build();
    }
}
```

---

## 七、Caffeine + Redis 两级缓存

```
请求
 │
 ▼
L1 Caffeine（本地内存缓存，微秒级）
 │  命中 → 直接返回
 │  未命中
 ▼
L2 Redis（分布式缓存，毫秒级）
 │  命中 → 回填 L1，返回
 │  未命中
 ▼
数据库（回填 L1 + L2）
```

```java
@Configuration
public class TwoLevelCacheConfig {

    @Bean
    public CacheManager cacheManager(RedisConnectionFactory factory) {
        // L1：Caffeine 本地缓存（最大1000条，5分钟过期）
        CaffeineCache caffeineCache = new CaffeineCache("products",
            Caffeine.newBuilder()
                .maximumSize(1000)
                .expireAfterWrite(5, TimeUnit.MINUTES)
                .recordStats()
                .build()
        );

        // L2：Redis 分布式缓存
        RedisCacheConfiguration redisConfig = RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(30));
        RedisCacheManager redisCacheManager = RedisCacheManager.builder(factory)
            .cacheDefaults(redisConfig).build();

        // 组合成两级缓存（实际项目可使用 layering-cache 等框架）
        CompositeCacheManager compositeCacheManager = new CompositeCacheManager(
            new CaffeineCacheManager() {{ addCache(caffeineCache); }},
            redisCacheManager
        );
        compositeCacheManager.setFallbackToNoOpCache(false);
        return compositeCacheManager;
    }
}
```

---

## 八、总结

| 问题 | 解决方案 |
|------|---------|
| 缓存穿透 | 缓存空值 / 布隆过滤器（BloomFilter） |
| 缓存击穿 | 互斥锁（Redis SETNX）/ 逻辑过期 |
| 缓存雪崩 | 过期时间加随机值 / Redis 集群 / 熔断 |
| 数据一致性 | 先更新DB再删缓存（Cache-Aside） |
| 性能优化 | L1 Caffeine + L2 Redis 两级缓存 |

- `@Cacheable` 不执行方法直接返回缓存，适合读多写少场景
- `@CachePut` 总是执行并更新缓存，用于写操作
- `@CacheEvict` 删除缓存，写操作后及时清理
- 生产中推荐 `unless = "#result == null"` 避免缓存 null 引发误判
