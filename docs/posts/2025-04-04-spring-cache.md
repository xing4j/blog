# Spring Cache：声明式缓存的正确使用姿势

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](posts/2026-05-24-spring-boot-startup.md)
> - [SB-08 Spring Boot 自动装配原理深度解析](posts/2024-10-27-spring-boot-autoconfigure.md)
> - [SB-09 Spring Boot 配置体系详解](posts/2026-05-16-spring-boot-config-priority.md)
> - [SB-10 Spring Boot 条件装配：@Conditional 体系](posts/2026-05-24-spring-boot-conditional.md)
> - [SB-11 Spring 循环依赖：三级缓存的设计原理](posts/2026-05-24-spring-circular-dependency.md)
> - [SB-12 Filter、Interceptor、AOP 三者对比与选型](posts/2026-05-24-spring-filter-interceptor-aop.md)
> - [SB-13 Spring 事件驱动：ApplicationEvent 与监听器](posts/2026-05-24-spring-events.md)
> - [SB-14 Spring @Async 异步编程：原理与线程池配置](posts/2026-05-24-spring-async.md)
> - [SB-15 Spring 扩展点：BPP、BFPP 与 ImportSelector](posts/2026-05-24-spring-extension-points.md)
> - [SB-16 Spring Boot 全局异常处理与参数校验](posts/2026-05-24-spring-exception-handler.md)
> - [SB-17 Spring Boot 多数据源：动态路由与跨库事务](posts/2026-05-24-spring-boot-multi-datasource.md)
> - [SB-18 Spring Boot Actuator：健康检查与自定义端点](posts/2026-05-24-spring-boot-actuator.md)
> - [SB-19 Spring Boot 自定义 Starter：从设计到发布](posts/2026-05-24-spring-boot-custom-starter.md)
> - [SB-20 Spring Security 认证授权完整流程](posts/2024-12-23-spring-security-auth.md)
> - 👉 **SB-21 Spring Cache 注解与 Redis 缓存集成（本文）**
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](posts/2026-05-24-spring-boot-testing.md)

**深度等级**：⭐ 入门｜**阅读时长**：约 15 分钟｜**分类**：Spring 生态

<div class="post-meta">📅 2025-04-04 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

## 导读

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

## 六、踩坑总结

❌ **`@Cacheable` 注解同类内部调用不生效，添加缓存但查询结果每次都穿透到数据库**

✅ Spring Cache 基于 AOP 代理，同类内部调用绕过代理，缓存注解失效。这与 `@Transactional` 同类调用失效是完全相同的原因。修复方法：将带缓存注解的方法移到独立 Bean，或通过 `ApplicationContext.getBean()` 获取代理再调用。

❌ **`@CachePut` 更新了缓存，但 `@Cacheable` 读到的仍是旧数据**

✅ 原因是 `@CachePut` 和 `@Cacheable` 的 Key 表达式不一致。例如 `@Cacheable(key = "#id")` 和 `@CachePut(key = "#user.id")`——如果 `id` 是方法参数而 `user.id` 是对象属性，两者虽然值相同，但如果 Key 生成策略有差异（如类型不同导致 `toString()` 不同）就会不命中。建议将 Key 逻辑提取为统一的 SpEL 表达式或常量。

---

## 七、文章小结

- Spring Cache 的四个核心注解：`@Cacheable`（读）、`@CachePut`（写）、`@CacheEvict`（删）、`@Caching`（组合）
- `value`（缓存空间名）+ `key`（SpEL 表达式）共同决定缓存 Key；`unless`/`condition` 控制是否缓存
- Spring Cache 是抽象层，底层可接入 Redis/Caffeine/EhCache，引入对应 Starter 自动切换
- 内部调用绕过 AOP 代理导致缓存不生效，与 `@Transactional` 同类问题，根因相同
- `@CachePut` 和 `@Cacheable` 必须使用完全一致的 Key 表达式，否则更新缓存对读取无效

---

## 八、思考题

1. `@Cacheable` 标注的方法，如果数据库查到的结果为 `null`，会被缓存吗？如果不缓存 `null`，大量查询不存在的 key 会引发什么问题？如何解决？

2. 生产环境中，多个服务实例共享同一个 Redis 缓存，某个服务 A 更新了数据库并用 `@CacheEvict` 清除了缓存，但服务 B 的本地缓存（Caffeine）仍有旧数据，如何解决多级缓存的一致性问题？

---

## 参考资料

> 1. [Spring 官方文档 - Cache Abstraction](https://docs.spring.io/spring-framework/reference/integration/cache.html)
> 2. [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> 3. [2024-06-29 Redis 缓存穿透、击穿与雪崩](posts/2024-06-29-redis-cache-problems.md)
