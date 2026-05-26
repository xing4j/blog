# Spring Boot 条件装配：@Conditional 体系与 SPI 扩展机制

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
> - 👉 **SB-10 Spring Boot 条件装配：@Conditional 体系（本文）**
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

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 22 分钟｜**分类**：Spring 生态

---

## 导读

Spring Boot "零配置"的魔法根源在于条件装配：Redis 相关 Bean 只有在引入了 `spring-boot-starter-redis` 时才注册，数据源 Bean 只有在配置了 `spring.datasource.url` 时才创建。本文深入 `@Conditional` 体系，解析每个条件注解的实现原理，并结合自定义条件的实战示例，让你彻底掌握 Spring Boot 按需装配的机制。

---

## 一、@Conditional 的核心接口

`@Conditional` 是 Spring 4.0 引入的元注解，配合 `Condition` 接口实现"按条件注册 Bean"：

```java
// Condition 接口：实现类决定该 Bean/Configuration 是否注册
@FunctionalInterface
public interface Condition {
    boolean matches(ConditionContext context, AnnotatedTypeMetadata metadata);
}

// @Conditional 接受一个或多个 Condition 实现类
@Target({ElementType.TYPE, ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface Conditional {
    Class<? extends Condition>[] value();
}
```

`ConditionContext` 提供了丰富的上下文信息：

```java
public interface ConditionContext {
    BeanDefinitionRegistry getRegistry();     // 已注册的 BeanDefinition
    ConfigurableListableBeanFactory getBeanFactory();
    Environment getEnvironment();             // 配置属性
    ResourceLoader getResourceLoader();
    ClassLoader getClassLoader();
}
```

---

## 二、Spring Boot 内置条件注解大全

### 2.1 类路径条件

```java
// 当 classpath 中存在指定类时，注册该 Bean
@ConditionalOnClass(RedisOperations.class)
// 当 classpath 中不存在指定类时，注册该 Bean
@ConditionalOnMissingClass("io.lettuce.core.RedisClient")
```

**实现原理**：`OnClassCondition` 通过 `ClassLoader.loadClass()` 检测类是否存在，注意：这里加载的不是 Spring Bean，而是检查 classpath 中有没有这个字节码文件。

### 2.2 Bean 存在条件

```java
// 当容器中存在指定类型的 Bean 时注册
@ConditionalOnBean(DataSource.class)
// 当容器中不存在指定类型的 Bean 时注册（自定义配置覆盖默认）
@ConditionalOnMissingBean(DataSource.class)
```

**最常用场景**：Starter 的默认配置用 `@ConditionalOnMissingBean`，允许用户自定义覆盖：

```java
// Spring Boot DataSourceAutoConfiguration 简化版
@Configuration
public class DataSourceAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean(DataSource.class) // 用户没有自定义 DataSource 才创建
    public DataSource dataSource(DataSourceProperties properties) {
        return DataSourceBuilder.create()
            .url(properties.getUrl())
            .username(properties.getUsername())
            .password(properties.getPassword())
            .build();
    }
}
```

### 2.3 配置属性条件

```java
// 当 application.yml 中存在 spring.datasource.url 属性时注册
@ConditionalOnProperty(prefix = "spring.datasource", name = "url")

// 当属性值为特定值时才注册
@ConditionalOnProperty(prefix = "app.cache", name = "enabled", havingValue = "true")

// 当属性不存在时也注册（matchIfMissing = true 是关键）
@ConditionalOnProperty(prefix = "app.cache", name = "type",
    havingValue = "redis", matchIfMissing = false)
```

### 2.4 Web 环境条件

```java
// 只在 Servlet Web 应用中注册
@ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.SERVLET)
// 只在非 Web 应用中注册
@ConditionalOnNotWebApplication
```

### 2.5 表达式条件

```java
// SpEL 表达式为 true 时注册（最灵活但不推荐滥用）
@ConditionalOnExpression("${feature.new-order-flow:false} and '${env}'.equals('prod')")
```

### 2.6 条件注解汇总

| 注解 | 条件语义 |
|------|---------|
| `@ConditionalOnClass` | classpath 中存在指定类 |
| `@ConditionalOnMissingClass` | classpath 中不存在指定类 |
| `@ConditionalOnBean` | 容器中存在指定 Bean |
| `@ConditionalOnMissingBean` | 容器中不存在指定 Bean |
| `@ConditionalOnProperty` | 配置属性匹配 |
| `@ConditionalOnWebApplication` | 是 Web 应用 |
| `@ConditionalOnNotWebApplication` | 不是 Web 应用 |
| `@ConditionalOnResource` | classpath 中存在指定资源文件 |
| `@ConditionalOnJava` | JVM 版本匹配 |
| `@ConditionalOnCloudPlatform` | 运行在指定云平台 |
| `@ConditionalOnExpression` | SpEL 表达式为 true |
| `@ConditionalOnSingleCandidate` | 容器中仅有一个指定类型 Bean |

---

## 三、条件评估时机与顺序

条件评估发生在 `refresh()` 的 **步骤 5：invokeBeanFactoryPostProcessors()**，由 `ConfigurationClassPostProcessor` 触发，`ConditionEvaluator` 负责评估每个 `@Conditional`。

**评估顺序的坑**：`@ConditionalOnBean` 依赖 BeanDefinition 已被注册，而注册顺序取决于 `@Configuration` 类的处理顺序。如果 A 依赖 B 的 Bean 已存在，但 B 还未被处理，`@ConditionalOnBean` 会误判：

```java
// 问题场景：AutoConfig A 依赖 AutoConfig B 中的 Bean
@Configuration
@ConditionalOnBean(MyService.class)  // 如果 MyServiceAutoConfig 还未处理，这里会 false
public class MyFeatureAutoConfig { ... }

// 解决：使用 @AutoConfigureAfter 声明顺序依赖
@Configuration
@AutoConfigureAfter(MyServiceAutoConfig.class)
@ConditionalOnBean(MyService.class)
public class MyFeatureAutoConfig { ... }
```

---

## 四、自定义 Condition 实战

```java
// Spring Boot 3.2 + JDK 17
// 场景：当系统属性 os.name 包含 "linux" 时才注册某个 Bean（生产环境专用）

// 1. 实现 Condition
public class LinuxCondition implements Condition {
    @Override
    public boolean matches(ConditionContext context, AnnotatedTypeMetadata metadata) {
        String osName = System.getProperty("os.name");
        return osName != null && osName.toLowerCase().contains("linux");
    }
}

// 2. 自定义组合注解（推荐，语义更清晰）
@Target({ElementType.TYPE, ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
@Conditional(LinuxCondition.class)
public @interface ConditionalOnLinux {}

// 3. 使用
@Configuration
public class ProdOnlyConfig {
    @Bean
    @ConditionalOnLinux
    public MetricsExporter linuxMetricsExporter() {
        return new LinuxMetricsExporter(); // 只在 Linux 生产机器上注册
    }
}
```

---

## 五、Spring Boot SPI 机制：SpringFactoriesLoader

条件装配通常配合 SPI 机制一起使用——自动配置类通过 SPI 被发现，条件注解决定是否生效。

**Spring Boot 2.x 的 spring.factories**：

```properties
# META-INF/spring.factories
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
  com.example.MyRedisAutoConfiguration,\
  com.example.MyDataSourceAutoConfiguration
```

**Spring Boot 3.x 新格式（推荐）**：

```
# META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
com.example.MyRedisAutoConfiguration
com.example.MyDataSourceAutoConfiguration
```

`AutoConfigurationImportSelector.selectImports()` 在 `@EnableAutoConfiguration` 处理时被调用，读取上述文件，将所有自动配置类加载到 BeanDefinition 处理流程中，然后由条件注解决定哪些真正生效。

---

## 六、踩坑总结

❌ **`@ConditionalOnMissingBean` 写在自动配置类上，用户自定义 Bean 已有但条件仍然触发**

✅ `@ConditionalOnMissingBean` 会检查 Bean 类型（by type）或名称（by name）。如果用户的 Bean 实现了接口，但 `@ConditionalOnMissingBean(MyService.class)` 检查的是具体类型，可能检测不到。应改为 `@ConditionalOnMissingBean(type = "com.example.MyService")`（字符串形式，避免 classpath 不存在时报错）或用 Bean 接口类型。

❌ **在 `@Bean` 方法上用 `@ConditionalOnBean`，但因为 BeanDefinition 注册顺序问题，运行时始终不生效**

✅ 自动配置类的处理顺序无法保证，使用 `@AutoConfigureAfter`、`@AutoConfigureBefore`、`@AutoConfigureOrder` 显式声明依赖顺序，或改用 `@ConditionalOnClass` 替代（按类路径条件更稳定）。

---

## 七、文章小结

- `@Conditional` 是 Spring 4.0 引入的通用条件机制，`Condition.matches()` 返回 true 才注册 Bean
- Spring Boot 基于 `@Conditional` 封装了十余个语义化注解，最核心的是 `@ConditionalOnClass`、`@ConditionalOnMissingBean`、`@ConditionalOnProperty`
- 条件评估发生在 `refresh()` 的 BeanDefinition 注册阶段，顺序依赖用 `@AutoConfigureAfter` 声明
- SPI 机制（`spring.factories` / `AutoConfiguration.imports`）发现候选自动配置类，条件注解决定是否生效
- `@ConditionalOnMissingBean` 是 Starter 默认配置"可被覆盖"的标准实现方式

---

## 八、思考题

1. 如果你想实现"只在单元测试环境下注册某个 Mock Bean"，应该用哪个条件注解？如何实现？

2. `@ConditionalOnClass` 和 `@ConditionalOnBean` 有什么本质区别？在 Starter 开发中，通常先用哪个？为什么？

---

## 参考资料

> 1. [Spring Boot 官方文档 - Condition Annotations](https://docs.spring.io/spring-boot/docs/current/reference/html/features.html#features.developing-auto-configuration.condition-annotations)
> 2. Spring Boot 源码：`OnClassCondition`、`OnBeanCondition`、`ConditionEvaluator`（版本：3.2）
> 3. [SB-08 Spring Boot 自动装配原理深度解析](posts/2024-10-27-spring-boot-autoconfigure.md)
> 4. [SB-19 Spring Boot 自定义 Starter：从设计到发布](posts/2026-05-24-spring-boot-custom-starter.md)
