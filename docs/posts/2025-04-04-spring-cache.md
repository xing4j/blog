# Spring Cache：声明式缓存的正确使用姿势

<div class="post-meta">📅 2025-04-04 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

@Cacheable 加上去，查询速度确实快了，但缓存不更新、Key 冲突、缓存雪崩接踵而至。Spring Cache 抽象层让切换 Redis/Caffeine 变得简单，但缓存的难题从来不在存取，而在一致性和失效策略。

---

## 一、背景：Spring Cache 解决什么问题

没有 Spring Cache 时，缓存逻辑侵入业务代码：

```java
// ❌ 缓存逻辑与业务逻辑耦合
public User getUser(Long id) {
    String key = "user:" + id;
    User cached = redisTemplate.opsForValue().get(key);
    if (cached != null) return cached;
    User user = userDao.findById(id);
    redisTemplate.opsForValue().set(key, user, 30, TimeUnit.MINUTES);
    return user;
}
```
Spring Cache 通过 AOP 将缓存逻辑从业务中剥离：

```java
// ✅ 业务代码只关注查询
@Cacheable(value = "users", key = "#id")
public User getUser(Long id) {
    return userDao.findById(id);
}
```
---

## 二、四个核心注解

### @Cacheable：读缓存（有则返回缓存，无则执行方法并缓存结果）

```java
@Service
public class ProductService {

    // 基本用法：缓存名 "products"，key 为参数 id
    @Cacheable(value = "products", key = "#id")
    public Product getById(Long id) {
        return productDao.findById(id);
    }

    // 条件缓存：只有 VIP 用户的查询才缓存
    @Cacheable(value = "products", key = "#userId + ':' + #productId",
               condition = "#userId != null")
    public Product getByUser(Long userId, Long productId) {
        return productDao.findByUser(userId, productId);
    }

    // unless：结果为 null 时不缓存
    @Cacheable(value = "products", key = "#id", unless = "#result == null")
    public Product getOrNull(Long id) {
        return productDao.findByIdOrNull(id);
    }
}
```
### @CachePut：更新缓存（总是执行方法，并用返回值更新缓存）

```java
// 更新操作：更新 DB 的同时更新缓存，保持一致性
@CachePut(value = "products", key = "#product.id")
public Product update(Product product) {
    return productDao.update(product);  // 返回值会写入缓存
}
```
### @CacheEvict：删除缓存

```java
// 删除单个 key
@CacheEvict(value = "products", key = "#id")
public void delete(Long id) {
    productDao.deleteById(id);
}

// 清空 products 缓存下的所有 key（allEntries=true）
@CacheEvict(value = "products", allEntries = true)
public void clearAll() { }

// beforeInvocation=true：方法执行前就删缓存（避免方法异常时缓存未清）
@CacheEvict(value = "products", key = "#id", beforeInvocation = true)
public void deleteWithPreEvict(Long id) {
    productDao.deleteById(id);
}
```
### @Caching：组合多个缓存操作

```java
@Caching(
    evict = {
        @CacheEvict(value = "products", key = "#id"),
        @CacheEvict(value = "productList", allEntries = true)
    }
)
public void deleteProduct(Long id) {
    productDao.deleteById(id);
}
```
---

## 三、与 Redis 集成配置

```java
@Configuration
@EnableCaching
public class CacheConfig {

    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory connectionFactory) {
        // 默认缓存配置
        RedisCacheConfiguration defaultConfig = RedisCacheConfiguration.defaultCacheConfig()
            .entryTtl(Duration.ofMinutes(30))              // 全局 TTL 30 分钟
            .serializeKeysWith(RedisSerializationContext.SerializationPair
                .fromSerializer(new StringRedisSerializer()))
            .serializeValuesWith(RedisSerializationContext.SerializationPair
                .fromSerializer(new GenericJackson2JsonRedisSerializer()))  // JSON 序列化
            .disableCachingNullValues();                   // 不缓存 null（避免缓存穿透时需另处理）

        // 不同缓存区域使用不同 TTL
        Map<String, RedisCacheConfiguration> cacheConfigs = new HashMap<>();
        cacheConfigs.put("products", defaultConfig.entryTtl(Duration.ofHours(1)));
        cacheConfigs.put("userSessions", defaultConfig.entryTtl(Duration.ofDays(7)));

        return RedisCacheManager.builder(connectionFactory)
            .cacheDefaults(defaultConfig)
            .withInitialCacheConfigurations(cacheConfigs)
            .build();
    }
}
```
---

## 四、对比：Spring Cache vs 手动 Redis 操作

| 特性 | Spring Cache | 手动 RedisTemplate |
|------|-------------|-------------------|
| 代码侵入性 | 低（注解声明式）| 高（业务逻辑混入缓存逻辑）|
| 切换缓存实现 | 一行配置（换 CacheManager）| 大量代码改动 |
| 细粒度控制 | 有限（注解表达能力有限）| 完全控制 |
| Pipeline / Lua 脚本 | ❌ 不支持 | ✅ 支持 |
| 复杂 Key 结构（Hash/Set）| ❌ 只支持 String | ✅ 全数据结构 |
| 适用场景 | 简单 K/V 缓存，查询缓存 | 复杂缓存逻辑，分布式锁 |

---

## 五、常见坑点与最佳实践

### 坑 1：同类方法内部调用缓存不生效（AOP 代理问题）

```java
@Service
public class ProductService {
    public Product getDetail(Long id) {
        // ❌ 内部调用，绕过代理，@Cacheable 不生效
        return this.getById(id);
    }

    @Cacheable(value = "products", key = "#id")
    public Product getById(Long id) {
        return productDao.findById(id);
    }
}
```
### 坑 2：Key 设计不合理导致缓存污染

```java
// ❌ 不同方法用同一个 key 名，互相覆盖
@Cacheable(value = "data", key = "#id")  // OrderService
@Cacheable(value = "data", key = "#id")  // UserService（同一 Redis key！）

// ✅ 用 value 区分不同缓存区域，或加前缀
@Cacheable(value = "orders", key = "#id")
@Cacheable(value = "users", key = "#id")
```
### 坑 3：缓存穿透（结果为 null 不缓存）

```java
// ❌ 查询结果为 null，每次都穿透到 DB
@Cacheable(value = "products", key = "#id", unless = "#result == null")
public Product getById(Long id) {
    return productDao.findById(id);  // 返回 null 不缓存，下次继续查 DB
}

// ✅ 缓存空对象（需定义空对象）
@Cacheable(value = "products", key = "#id")
public Product getById(Long id) {
    Product product = productDao.findById(id);
    return product != null ? product : Product.EMPTY;  // 缓存空对象占位
}
```
### 坑 4：@CachePut 与 @Cacheable Key 不一致

```java
// ❌ Key 不一致，更新缓存但读取的是旧 Key 的缓存
@Cacheable(value = "users", key = "#id")
public User getUser(Long id) { ... }

@CachePut(value = "users", key = "#user.userId")  // ❌ Key 不同！
public User updateUser(User user) { ... }

// ✅ 确保 Key 一致
@CachePut(value = "users", key = "#user.id")  // ✅ 与 @Cacheable 相同
public User updateUser(User user) { ... }
```
---

## 六、总结与延伸

**核心要点**：
- @Cacheable：读缓存；@CachePut：写缓存；@CacheEvict：删缓存
- Spring Cache 是缓存操作的抽象层，底层实现（Redis/Caffeine/EhCache）可一键切换
- 内部方法调用绕过 AOP 代理，缓存不生效
- Key 设计：用 value 区分缓存空间，Key 在同一 value 内保持唯一且一致

**延伸阅读方向**：
- Caffeine 本地缓存：高性能本地缓存，适合热点数据，与 Spring Cache 集成
- 多级缓存架构：本地缓存（Caffeine）+ 分布式缓存（Redis）的两级方案
- 缓存击穿/穿透/雪崩：三大缓存问题的成因与解决方案
- Canal + MQ：数据库 binlog 订阅实现缓存自动失效，保证强一致性
