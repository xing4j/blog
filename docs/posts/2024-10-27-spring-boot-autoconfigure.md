# Spring Boot 自动装配：零配置背后的魔法

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](posts/2026-05-24-spring-boot-startup.md)
> - 👉 **SB-08 Spring Boot 自动装配原理深度解析（本文）**
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
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](posts/2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](posts/2026-05-24-spring-boot-testing.md)

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 20 分钟｜**分类**：Spring 生态

<div class="post-meta">📅 2024-10-27 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

## 导读

加一个 spring-boot-starter-data-redis 依赖，不写任何配置类，Redis 连接池就自动初始化好了。Spring Boot 的自动装配让"约定大于配置"成为现实。理解这套机制，才能在出现问题时知道如何调试，以及如何编写自己的 Starter。

---

## 一、背景：Spring Boot 之前的痛点

Spring 时代（Spring 4.x 之前），整合 Redis 需要：
1. 在 XML 或 Java Config 中手动定义 JedisConnectionFactory
2. 手动定义 RedisTemplate 并配置序列化器
3. 手动定义连接池配置

Spring Boot 的目标：让 80% 的场景下，引入依赖即可用。

---

## 二、自动装配的核心流程

```
@SpringBootApplication
    v 包含
@EnableAutoConfiguration
    v 导入
AutoConfigurationImportSelector
    v 读取
spring.factories / AutoConfiguration.imports（Spring Boot 3.x）
    v 过滤（@Conditional）
符合条件的 AutoConfiguration 类
    v 执行
注册所需的 Bean 到容器
```
### 2.1 入口：@EnableAutoConfiguration

```java
@SpringBootApplication
// 等价于：
@SpringBootConfiguration
@EnableAutoConfiguration   // <- 自动装配的开关
@ComponentScan
```
### 2.2 SPI 配置文件

Spring Boot 通过类 SPI 机制发现所有自动配置类：

```
Spring Boot 2.x：
META-INF/spring.factories 文件中：
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
  org.springframework.boot.autoconfigure.data.redis.RedisAutoConfiguration,\
  org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration,\
  ...（120+ 个自动配置类）

Spring Boot 3.x（新格式）：
META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
文件中每行一个自动配置类全限定名
```
### 2.3 @Conditional：按需生效

自动配置类不是全部生效，通过 @Conditional 系列注解控制：

```java
@Configuration
@ConditionalOnClass(RedisOperations.class)          // classpath 有 Redis 相关类时生效
@EnableConfigurationProperties(RedisProperties.class) // 读取 spring.redis.* 配置
@Import({ LettuceConnectionConfiguration.class, JedisConnectionConfiguration.class })
public class RedisAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean(name = "redisTemplate")  // 用户没有自定义 redisTemplate 时才创建
    @ConditionalOnSingleCandidate(RedisConnectionFactory.class)
    public RedisTemplate<Object, Object> redisTemplate(RedisConnectionFactory connectionFactory) {
        RedisTemplate<Object, Object> template = new RedisTemplate<>();
        template.setConnectionFactory(connectionFactory);
        return template;
    }

    @Bean
    @ConditionalOnMissingBean    // 用户没有自定义 StringRedisTemplate 时才创建
    @ConditionalOnSingleCandidate(RedisConnectionFactory.class)
    public StringRedisTemplate stringRedisTemplate(RedisConnectionFactory connectionFactory) {
        return new StringRedisTemplate(connectionFactory);
    }
}
```
**关键注解速查**：

| 注解 | 条件 |
|------|------|
| @ConditionalOnClass | classpath 存在指定类 |
| @ConditionalOnMissingClass | classpath 不存在指定类 |
| @ConditionalOnBean | 容器中存在指定 Bean |
| @ConditionalOnMissingBean | 容器中不存在指定 Bean |
| @ConditionalOnProperty | 配置属性满足条件 |
| @ConditionalOnWebApplication | 是 Web 应用 |
| @ConditionalOnExpression | SpEL 表达式为 true |

---

## 三、自定义 Starter：实现一个限流 Starter

### 3.1 项目结构

```
rate-limit-spring-boot-starter/
+-- src/main/java/
|   +-- com/example/ratelimit/
|       +-- RateLimitAutoConfiguration.java  <- 自动配置类
|       +-- RateLimitProperties.java          <- 配置属性类
|       +-- RateLimitService.java             <- 核心服务
+-- src/main/resources/
    +-- META-INF/
        +-- spring/
            +-- org.springframework.boot.autoconfigure.AutoConfiguration.imports
```
### 3.2 配置属性类

```java
@ConfigurationProperties(prefix = "ratelimit")
public class RateLimitProperties {
    private int maxRequests = 100;   // 默认每秒最大请求数
    private int windowSeconds = 1;   // 时间窗口（秒）
    private boolean enabled = true;

    // getters/setters
}
```
### 3.3 自动配置类

```java
@AutoConfiguration
@ConditionalOnClass(RateLimitService.class)              // 依赖存在时生效
@ConditionalOnProperty(prefix = "ratelimit", name = "enabled", havingValue = "true", matchIfMissing = true)
@EnableConfigurationProperties(RateLimitProperties.class)
public class RateLimitAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean   // 用户可以覆盖
    public RateLimitService rateLimitService(RateLimitProperties props) {
        return new RateLimitService(props.getMaxRequests(), props.getWindowSeconds());
    }
}
```
### 3.4 注册自动配置

```
文件：META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
内容：
com.example.ratelimit.RateLimitAutoConfiguration
```
### 3.5 使用方只需引入依赖

```yaml
# application.yml（可选，有默认值）
ratelimit:
  max-requests: 200
  window-seconds: 1
  enabled: true
```
```java
@Service
public class ApiService {
    @Autowired
    private RateLimitService rateLimitService;  // 自动注入，无需任何额外配置
}
```
---

## 四、调试自动装配

当自动配置不生效时：

```bash
# 启动时加参数，查看所有自动配置的生效/未生效原因
java -jar app.jar --debug

# 或在 application.yml 中开启
logging:
  level:
    org.springframework.boot.autoconfigure: DEBUG
```
输出示例：

```
============================
CONDITIONS EVALUATION REPORT
============================
Positive matches:
-----------------
   RedisAutoConfiguration matched:
      - @ConditionalOnClass found required class 'RedisOperations' (OnClassCondition)

Negative matches:
-----------------
   MongoAutoConfiguration:
      Did not match:
         - @ConditionalOnClass did not find required class 'com.mongodb.client.MongoClient'
```
---

## 五、常见坑点

### 坑 1：自定义 Bean 没有覆盖自动配置

```java
// ❌ 没加 @Primary 或 @ConditionalOnMissingBean，与自动配置的 Bean 产生冲突
@Bean
public RedisTemplate<String, Object> redisTemplate() { ... }

// ✅ 加 @Primary 优先使用，或者自动配置类用了 @ConditionalOnMissingBean（大多数情况可以直接定义）
@Bean
@Primary
public RedisTemplate<String, Object> redisTemplate() { ... }
```
### 坑 2：@ConfigurationProperties 未绑定

```java
// ❌ 忘记加 @EnableConfigurationProperties 或 @Component
@ConfigurationProperties(prefix = "myapp")
public class MyProperties {
    private String name;  // 值为 null，未从配置文件读取
}

// ✅ 方式一：在 @SpringBootApplication 类上加 @EnableConfigurationProperties
// ✅ 方式二：在 Properties 类上加 @Component
// ✅ 方式三：在 AutoConfiguration 类上加 @EnableConfigurationProperties(MyProperties.class)
```
---

## 六、踩坑总结

❌ **自定义 `@Bean` 与 Starter 的 `@Bean` 冲突，报 `BeanDefinitionOverrideException`**

✅ Spring Boot 2.1+ 默认禁止 Bean 覆盖（`spring.main.allow-bean-definition-overriding=false`）。根本原因通常是 AutoConfiguration 没有 `@ConditionalOnMissingBean`，或者用户定义的 Bean 与自动配置 Bean 同名。正确做法：不要依赖 Bean 覆盖，在 AutoConfiguration 的 `@Bean` 方法上加 `@ConditionalOnMissingBean`，用户定义 Bean 后自动装配不再注册。

❌ **`@ConfigurationProperties` 类的属性值为 null，配置文件中明明写了值**

✅ 两个常见原因：①`@ConfigurationProperties` 类没有被注册为 Bean（缺少 `@Component` 或没有在 `@Configuration` 上加 `@EnableConfigurationProperties(MyProperties.class)`）；②配置文件 key 大小写问题（Spring Boot 会自动进行 relaxed binding，但对象嵌套时需要检查前缀是否完全匹配）。

---

## 七、文章小结

- 自动装配核心链路：`@EnableAutoConfiguration` → `AutoConfigurationImportSelector` → SPI 文件 → `@Conditional` 过滤 → 注册 Bean
- Spring Boot 3.x 使用 `META-INF/spring/AutoConfiguration.imports` 替代 `spring.factories`，格式更简洁
- `@ConditionalOnMissingBean` 是 Starter 设计的核心原则——用户定义 Bean 优先于自动配置
- 通过 `/actuator/conditions`（需引入 Actuator）可在运行时查看每个条件的评估结果，是自动装配调试的利器
- 自动装配顺序可用 `@AutoConfigureAfter/@AutoConfigureBefore/@AutoConfigureOrder` 控制

---

## 八、思考题

1. `@ConditionalOnMissingBean` 检查的时机是什么？如果 AutoConfiguration A 依赖 AutoConfiguration B 注册的 Bean，但没有配置顺序约束，会发生什么？

2. Spring Boot 为什么在 3.x 将 `spring.factories` 改为 `AutoConfiguration.imports`？性能上有什么提升？

---

## 参考资料

> 1. [Spring Boot 官方文档 - Auto-configuration](https://docs.spring.io/spring-boot/docs/current/reference/html/features.html#features.auto-configuration)
> 2. Spring Boot 源码：`AutoConfigurationImportSelector`（版本：3.2）
> 3. [SB-10 Spring Boot 条件装配：@Conditional 体系](posts/2026-05-24-spring-boot-conditional.md)
> 4. [SB-19 Spring Boot 自定义 Starter：从设计到发布](posts/2026-05-24-spring-boot-custom-starter.md)
