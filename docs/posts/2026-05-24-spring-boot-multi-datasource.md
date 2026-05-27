# Spring Boot 多数据源：动态路由与跨库事务

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
> - 👉 **SB-17 Spring Boot 多数据源：动态路由与跨库事务（本文）**
> - [SB-18 Spring Boot Actuator：健康检查与自定义端点](posts/2026-05-24-spring-boot-actuator.md)
> - [SB-19 Spring Boot 自定义 Starter：从设计到发布](posts/2026-05-24-spring-boot-custom-starter.md)
> - [SB-20 Spring Security 认证授权完整流程](posts/2024-12-23-spring-security-auth.md)
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](posts/2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](posts/2026-05-24-spring-boot-testing.md)

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 25 分钟｜**分类**：Spring 生态

---

## 导读

主从分离、多业务库隔离是生产中的高频场景。Spring 的 `AbstractRoutingDataSource` 提供了动态数据源路由的标准扩展点，配合 AOP 注解可以实现简洁的切换。本文构建从配置、路由核心、AOP 切换到跨库事务边界的完整多数据源方案。

---

## 一、多数据源的典型场景

| 场景 | 数据源数量 | 路由策略 |
|------|----------|---------|
| 主从读写分离 | 1 主 + N 从 | 读操作走从库，写操作走主库 |
| 多租户隔离 | N 个租户库 | 按租户 ID 路由 |
| 业务库拆分 | N 个业务库 | 按业务类型路由（订单库、用户库）|
| 分库分表 | N 个分片库 | 按分片键路由（通常用 ShardingSphere）|

---

## 二、AbstractRoutingDataSource：核心原理

`AbstractRoutingDataSource` 是 Spring 提供的抽象数据源路由类，内部维护一个数据源 Map，通过 `determineCurrentLookupKey()` 返回的 key 选择实际数据源：

```java
// AbstractRoutingDataSource 核心方法（Spring 6.1）
public abstract class AbstractRoutingDataSource extends AbstractDataSource {

    // key -> DataSource 的映射
    private Map<Object, DataSource> resolvedDataSources;

    @Override
    protected DataSource determineTargetDataSource() {
        Object lookupKey = determineCurrentLookupKey(); // 子类实现，返回 key
        DataSource dataSource = resolvedDataSources.get(lookupKey);
        if (dataSource == null) {
            dataSource = resolvedDefaultDataSource; // 找不到则用默认数据源
        }
        return dataSource;
    }

    // 子类必须实现：返回当前线程应该使用的数据源 key
    protected abstract Object determineCurrentLookupKey();
}
```

---

## 三、完整实现：主从读写分离

### 3.1 数据源 Key 存储（ThreadLocal）

```java
// Spring Boot 3.2 + JDK 17 + HikariCP
public class DataSourceContextHolder {
    private static final ThreadLocal<String> CONTEXT = new ThreadLocal<>();

    public static void set(String dataSourceKey) {
        CONTEXT.set(dataSourceKey);
    }

    public static String get() {
        return CONTEXT.get();
    }

    public static void clear() {
        CONTEXT.remove(); // 必须清理，防止线程池复用时污染
    }
}

public interface DataSourceType {
    String MASTER = "master";
    String SLAVE  = "slave";
}
```

### 3.2 动态路由数据源实现

```java
public class DynamicRoutingDataSource extends AbstractRoutingDataSource {

    @Override
    protected Object determineCurrentLookupKey() {
        String key = DataSourceContextHolder.get();
        return (key != null) ? key : DataSourceType.MASTER; // 默认主库
    }
}
```

### 3.3 配置多数据源

```java
@Configuration
public class DataSourceConfig {

    @Bean
    @ConfigurationProperties("spring.datasource.master")
    public DataSource masterDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }

    @Bean
    @ConfigurationProperties("spring.datasource.slave")
    public DataSource slaveDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }

    @Primary // 标为主数据源，让 Spring Boot 自动配置使用这个
    @Bean("dynamicDataSource")
    public DataSource dynamicDataSource(
            @Qualifier("masterDataSource") DataSource master,
            @Qualifier("slaveDataSource") DataSource slave) {
        DynamicRoutingDataSource routing = new DynamicRoutingDataSource();
        Map<Object, Object> dsMap = new HashMap<>();
        dsMap.put(DataSourceType.MASTER, master);
        dsMap.put(DataSourceType.SLAVE, slave);
        routing.setTargetDataSources(dsMap);
        routing.setDefaultTargetDataSource(master);
        return routing;
    }
}
```

```yaml
# application.yml
spring:
  datasource:
    master:
      jdbc-url: jdbc:mysql://master-host:3306/mydb
      username: root
      password: secret
      hikari:
        maximum-pool-size: 20
    slave:
      jdbc-url: jdbc:mysql://slave-host:3306/mydb
      username: readonly
      password: secret
      hikari:
        maximum-pool-size: 30
  autoconfigure:
    exclude: DataSourceAutoConfiguration  # 排除默认自动配置
```

### 3.4 AOP 注解切换数据源

```java
// 自定义注解
@Target({ElementType.METHOD, ElementType.TYPE})
@Retention(RetentionPolicy.RUNTIME)
public @interface DS {
    String value() default DataSourceType.MASTER;
}

// AOP 切面
@Aspect
@Component
@Order(1) // 必须在 @Transactional 之前执行（数据源切换要先于事务开启）
public class DataSourceAspect {

    @Around("@annotation(ds)")
    public Object switchDataSource(ProceedingJoinPoint pjp, DS ds) throws Throwable {
        String previousKey = DataSourceContextHolder.get();
        try {
            DataSourceContextHolder.set(ds.value());
            return pjp.proceed();
        } finally {
            // 恢复之前的数据源（支持嵌套切换）
            if (previousKey != null) {
                DataSourceContextHolder.set(previousKey);
            } else {
                DataSourceContextHolder.clear();
            }
        }
    }
}

// 使用
@Service
public class UserService {

    @DS(DataSourceType.SLAVE) // 读走从库
    public List<User> list() {
        return userRepo.findAll();
    }

    @DS(DataSourceType.MASTER) // 写走主库（默认就是主库，可省略）
    @Transactional
    public void save(User user) {
        userRepo.save(user);
    }
}
```

---

## 四、跨库事务的边界与处理方案

### 4.1 为什么单个 @Transactional 不支持跨库事务

Spring 的 `DataSourceTransactionManager` 管理的是**单个数据源连接**的本地事务。如果方法中切换了数据源，`@Transactional` 只能保证其中一个数据源的事务，另一个数据源的操作在独立连接中执行，无法统一提交或回滚。

### 4.2 方案一：避免跨库事务（推荐）

最优解：业务设计上避免单个事务操作多个库。通过消息队列（如 Kafka）实现最终一致性：

```
库 A 写入 + 发送 MQ 消息 (本地事务保证)
       v
   MQ 消息消费
       v
   库 B 写入 (独立事务)
```

### 4.3 方案二：XA 分布式事务（强一致，但性能差）

使用 JTA（Java Transaction API）事务管理器，如 Atomikos：

```xml
<!-- pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-jta-atomikos</artifactId>
</dependency>
```

Atomikos 通过 XA 协议的两阶段提交（2PC）保证跨数据源的强一致性，但性能损耗约 3~5 倍，且长事务会锁资源，生产环境需谨慎评估。

---

## 五、踩坑总结

❌ **`@DS` 切换数据源的 AOP 和 `@Transactional` 的 AOP 执行顺序不对，导致事务在错误的数据源上开启**

✅ 事务的数据源在事务开启时确定（`getConnection()`），如果 `@Transactional` 的 AOP 先于 `@DS` 的 AOP 执行，数据源就已经绑定了默认主库，切换 `DataSourceContextHolder` 也无效。解决方案：设置 `@DS` 切面的 `@Order` 比 `@Transactional` 的优先级高（值更小，如 `@Order(1)` vs 事务默认 `@Order(Integer.MAX_VALUE)`）。

❌ **多线程场景下 `ThreadLocal` 数据源 key 污染：线程池复用线程，上个任务设置的 key 被下一个任务读取**

✅ 在 AOP 的 `finally` 块中必须调用 `DataSourceContextHolder.clear()`，确保方法执行完毕后清除 ThreadLocal，而不是简单地设置回去。如果有线程池 + 异步场景，需要传播 ThreadLocal（参考 [SB-14](posts/2026-05-24-spring-async.md)）。

---

## 六、文章小结

- `AbstractRoutingDataSource` 通过 `ThreadLocal` + 抽象 key 方法实现运行时数据源动态切换
- 主从读写分离的标准实现：`DynamicRoutingDataSource` + `DataSourceContextHolder` + `@DS` AOP 注解
- `@DS` 切面的 `@Order` 必须小于 `@Transactional` 的 order（数字越小优先级越高），否则事务在错误连接上开启
- 单个 `@Transactional` 无法跨多个数据源，跨库一致性应通过 MQ 最终一致或 XA 分布式事务实现
- ThreadLocal 必须在 finally 中清理，防止线程池复用时的数据污染

---

## 七、思考题

1. 如果使用连接池（HikariCP），主从数据源各有自己的连接池。当读请求突然激增时，从库连接池耗尽会怎样？如何监控和处理连接池的健康状态？

2. `AbstractRoutingDataSource` 是在 `getConnection()` 时才决定用哪个数据源，而 `@Transactional` 在方法开始时就调用 `getConnection()` 并绑定到当前线程。这意味着什么？如何在 `@Transactional` 方法内部切换数据源？

---

## 参考资料

> 1. [Spring 官方文档 - AbstractRoutingDataSource](https://docs.spring.io/spring-framework/reference/data-access/jdbc/datasource.html#jdbc-AbstractRoutingDataSource)
> 2. Spring Framework 源码：`AbstractRoutingDataSource`、`DataSourceTransactionManager`（版本：6.1）
> 3. [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> 4. [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
