# Spring @Async 异步编程：代理原理、失效场景与线程池配置

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
> - 👉 **SB-14 Spring @Async 异步编程：代理原理、失效场景与线程池配置（本文）**
> - [SB-15 Spring 扩展点：BPP、BFPP 与 ImportSelector](posts/2026-05-24-spring-extension-points.md)
> - [SB-16 Spring Boot 全局异常处理与参数校验](posts/2026-05-24-spring-exception-handler.md)
> - [SB-17 Spring Boot 多数据源：动态路由与跨库事务](posts/2026-05-24-spring-boot-multi-datasource.md)
> - [SB-18 Spring Boot Actuator：健康检查与自定义端点](posts/2026-05-24-spring-boot-actuator.md)
> - [SB-19 Spring Boot 自定义 Starter：从设计到发布](posts/2026-05-24-spring-boot-custom-starter.md)
> - [SB-20 Spring Security 认证授权完整流程](posts/2024-12-23-spring-security-auth.md)
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](posts/2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](posts/2026-05-24-spring-boot-testing.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 20 分钟｜**分类**：Spring 生态

---

## 导读

`@Async` 是 Spring 最常用的异步工具，但"加了 `@Async` 发现没异步"是高频踩坑场景。本文从代理实现原理出发，解释 `@Async` 为什么会失效，分析生产中常见的线程池配置问题，以及异步方法中的异常如何处理。

---

## 一、@Async 的启用与基本用法

```java
// Spring Boot 3.2 + JDK 17
// 1. 在配置类上开启异步支持
@SpringBootApplication
@EnableAsync  // 开启 @Async 支持
public class MyApplication { ... }

// 2. 标注异步方法
@Service
public class ReportService {

    // 无返回值：调用方立即返回，方法在线程池中执行
    @Async
    public void generateReport(Long orderId) {
        // 耗时操作，如导出 Excel、发邮件
        Thread.sleep(3000);
        System.out.println("Report generated in: " + Thread.currentThread().getName());
    }

    // 有返回值：返回 CompletableFuture，调用方可等待结果
    @Async
    public CompletableFuture<Report> generateReportAsync(Long orderId) {
        Report report = buildReport(orderId);
        return CompletableFuture.completedFuture(report);
    }
}

// 3. 调用
@Service
public class OrderService {
    @Autowired
    private ReportService reportService;

    public void placeOrder(Order order) {
        orderRepo.save(order);
        reportService.generateReport(order.getId()); // 立即返回，不等 generateReport 完成
        // 继续处理其他逻辑
    }
}
```

---

## 二、@Async 的实现原理

`@Async` 基于 Spring AOP 代理实现：`@EnableAsync` 向容器注册了 `AsyncAnnotationBeanPostProcessor`，它在 Bean 初始化完成后检测是否有 `@Async` 方法，如有则生成代理对象：

```
@Async 方法调用链路：

调用方 -> 代理对象 (AsyncAnnotationAdvisor)
              |
              | 在方法调用前，将真实方法包装成 Callable/Runnable
              | 提交到 TaskExecutor 线程池
              |
              v
          ThreadPoolExecutor（异步执行）
              |
              v
          真实方法体
```

关键类：`AsyncExecutionInterceptor` — 拦截 `@Async` 方法，使用 `AsyncTaskExecutor` 提交任务。

---

## 三、@Async 失效的所有场景

### 场景一：同类内调用（最常见）

```java
@Service
public class NotificationService {

    public void sendAll(Order order) {
        this.sendEmail(order);  // ❌ this 调用，绕过代理，@Async 不生效
        sendSms(order);         // ❌ 同上
    }

    @Async
    public void sendEmail(Order order) { ... }

    @Async
    public void sendSms(Order order) { ... }
}
```

✅ 解决方案：将 `@Async` 方法拆到独立的 Bean 中，通过 Spring 注入调用。

### 场景二：未标注 @EnableAsync

```java
// ❌ 忘记加 @EnableAsync，@Async 完全不生效（同步执行）
@SpringBootApplication
// @EnableAsync  <- 漏了
public class MyApp { ... }
```

### 场景三：@Async 方法不是 public

```java
@Service
public class MyService {
    @Async
    protected void asyncMethod() { ... }  // ❌ 非 public，代理不拦截
}
```

### 场景四：@Async 和 @Transactional 同时标注在同一方法

```java
@Async
@Transactional  // ⚠️ 可以共存，但需理解：@Async 在新线程执行，@Transactional 在新线程开启新事务
public void asyncTransactional() { ... }
// 原调用线程的事务与此方法的事务完全独立
```

---

## 四、线程池配置（生产必备）

默认情况下，`@Async` 使用 Spring Boot 自动配置的 `TaskExecutor`（底层是 `ThreadPoolTaskExecutor`，基于配置 `spring.task.execution.*`）。生产环境**强烈建议显式配置**：

```yaml
# application.yml - Spring Boot 默认 TaskExecutor 配置
spring:
  task:
    execution:
      pool:
        core-size: 8          # 核心线程数
        max-size: 32          # 最大线程数
        queue-capacity: 100   # 队列容量（超过则创建新线程直到 max-size）
        keep-alive: 60s       # 空闲线程存活时间
      thread-name-prefix: "async-"  # 线程名前缀，便于监控
```

**更推荐的方式**：按业务隔离线程池，防止慢任务拖垮其他异步任务：

```java
// Spring Boot 3.2 + JDK 17
@Configuration
@EnableAsync
public class AsyncConfig {

    // 邮件/通知发送线程池（允许慢一些，队列大）
    @Bean("notificationExecutor")
    public TaskExecutor notificationExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(4);
        executor.setMaxPoolSize(8);
        executor.setQueueCapacity(500);
        executor.setThreadNamePrefix("notification-");
        executor.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy()); // 拒绝时由调用方线程执行
        executor.initialize();
        return executor;
    }

    // 报表生成线程池（CPU 密集型，线程数 = CPU 核数）
    @Bean("reportExecutor")
    public TaskExecutor reportExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        int cpuCores = Runtime.getRuntime().availableProcessors();
        executor.setCorePoolSize(cpuCores);
        executor.setMaxPoolSize(cpuCores * 2);
        executor.setQueueCapacity(50);
        executor.setThreadNamePrefix("report-");
        executor.setRejectedExecutionHandler(new ThreadPoolExecutor.AbortPolicy());
        executor.initialize();
        return executor;
    }
}

// 使用：指定线程池名称
@Service
public class NotificationService {
    @Async("notificationExecutor")  // 明确指定
    public void sendEmail(String to, String content) { ... }
}
```

---

## 五、异步方法的异常处理

`@Async` 无返回值方法中的异常不会传播到调用方。默认行为：打印堆栈，但**调用方感知不到**。

```java
// 全局异步异常处理器
@Component
public class AsyncExceptionHandler implements AsyncUncaughtExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(AsyncExceptionHandler.class);

    @Override
    public void handleUncaughtException(Throwable ex, Method method, Object... params) {
        log.error("Async method [{}] failed with params {}: {}",
            method.getName(), Arrays.toString(params), ex.getMessage(), ex);
        // 可以发送告警、写入异常记录等
    }
}

// 注册到 AsyncConfigurer
@Configuration
@EnableAsync
public class AsyncConfig implements AsyncConfigurer {

    @Override
    public AsyncUncaughtExceptionHandler getAsyncUncaughtExceptionHandler() {
        return new AsyncExceptionHandler();
    }
}
```

有返回值的异步方法（`CompletableFuture`）异常通过 `CompletableFuture.exceptionally()` 或 `handle()` 处理：

```java
@Async
public CompletableFuture<Report> generateReport(Long id) {
    try {
        return CompletableFuture.completedFuture(buildReport(id));
    } catch (Exception e) {
        return CompletableFuture.failedFuture(e);
    }
}

// 调用方处理异常
reportService.generateReport(orderId)
    .exceptionally(ex -> {
        log.error("Report generation failed", ex);
        return Report.empty();
    });
```

---

## 六、踩坑总结

❌ **使用默认 `SimpleAsyncTaskExecutor`（老版本 Spring Boot）：每次调用都创建新线程，线程数无限增长，导致 OOM**

✅ `SimpleAsyncTaskExecutor` 不是真正的线程池，每次都 `new Thread()`。Spring Boot 2.1+ 自动配置了 `ThreadPoolTaskExecutor`，无需手动处理。但仍建议显式配置并通过 `@Bean("xxx")` 指定，避免依赖默认行为。

❌ **`@Async` 方法中使用了 `ThreadLocal` 存储的用户信息，执行时获取不到（为 null）**

✅ `@Async` 在新线程执行，原线程的 `ThreadLocal` 数据不会自动传播。解决方案：在提交任务前手动复制上下文，或使用 `TransmittableThreadLocal`（TTL）框架自动传播，或在方法参数中显式传入所需数据（最简单，最推荐）。

---

## 七、文章小结

- `@Async` 基于 AOP 代理，被代理方法在提交到线程池后由线程池线程异步执行
- 同类内调用（`this.xxx()`）、非 public 方法、未加 `@EnableAsync` 是 `@Async` 失效的三大原因
- 生产环境必须显式配置线程池并按业务隔离，防止慢任务拖垮全局
- 无返回值方法的异常不传播到调用方，需实现 `AsyncUncaughtExceptionHandler` 全局处理
- `ThreadLocal` 数据不随 `@Async` 自动传播，需手动传递或使用 TTL 框架

---

## 八、思考题

1. `@Async` 和 `CompletableFuture.supplyAsync()` 都能实现异步操作，各有什么优缺点？在 Spring 应用中如何选择？

2. 如果 `@Async` 方法中需要读取当前登录用户信息（通常存在 `ThreadLocal` 中），有哪些方案可以传递这个上下文？

---

## 参考资料

> 1. [Spring 官方文档 - @Async](https://docs.spring.io/spring-framework/reference/integration/scheduling.html#scheduling-annotation-support-async)
> 2. Spring Framework 源码：`AsyncAnnotationBeanPostProcessor`、`AsyncExecutionInterceptor`（版本：6.1）
> 3. [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> 4. [SB-13 Spring 事件驱动：ApplicationEvent 与监听器](posts/2026-05-24-spring-events.md)
