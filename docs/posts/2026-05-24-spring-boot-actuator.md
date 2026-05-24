# Spring Boot Actuator：健康检查、自定义端点与 Micrometer 指标

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](2024-08-22-spring-aop-proxy.md)
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](2026-05-24-spring-boot-startup.md)
> - [SB-08 Spring Boot 自动装配原理深度解析](2024-10-27-spring-boot-autoconfigure.md)
> - [SB-09 Spring Boot 配置体系详解](2026-05-16-spring-boot-config-priority.md)
> - [SB-10 Spring Boot 条件装配：@Conditional 体系](2026-05-24-spring-boot-conditional.md)
> - [SB-11 Spring 循环依赖：三级缓存的设计原理](2026-05-24-spring-circular-dependency.md)
> - [SB-12 Filter、Interceptor、AOP 三者对比与选型](2026-05-24-spring-filter-interceptor-aop.md)
> - [SB-13 Spring 事件驱动：ApplicationEvent 与监听器](2026-05-24-spring-events.md)
> - [SB-14 Spring @Async 异步编程：原理与线程池配置](2026-05-24-spring-async.md)
> - [SB-15 Spring 扩展点：BPP、BFPP 与 ImportSelector](2026-05-24-spring-extension-points.md)
> - [SB-16 Spring Boot 全局异常处理与参数校验](2026-05-24-spring-exception-handler.md)
> - [SB-17 Spring Boot 多数据源：动态路由与跨库事务](2026-05-24-spring-boot-multi-datasource.md)
> - 👉 **SB-18 Spring Boot Actuator：健康检查、自定义端点与 Micrometer 指标（本文）**
> - [SB-19 Spring Boot 自定义 Starter：从设计到发布](2026-05-24-spring-boot-custom-starter.md)
> - [SB-20 Spring Security 认证授权完整流程](2024-12-23-spring-security-auth.md)
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](2026-05-24-spring-boot-testing.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 20 分钟｜**分类**：Spring 生态

---

## 导读

K8s 的就绪探针、Prometheus 的指标采集、运维的健康检查——这些都依赖 Spring Boot Actuator。本文介绍 Actuator 的核心端点、安全配置，以及如何自定义健康检查指标和业务 Endpoint，让应用可观测性达到生产标准。

---

## 一、Actuator 快速启用

```xml
<!-- pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<!-- Prometheus 指标暴露（可选）-->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

```yaml
# application.yml
management:
  endpoints:
    web:
      exposure:
        include: health, info, metrics, prometheus, env, loggers
      base-path: /actuator  # 默认
  endpoint:
    health:
      show-details: when-authorized  # 生产：授权后才显示详情
      probes:
        enabled: true  # 启用 K8s 就绪/存活探针
  server:
    port: 8081  # 将 Actuator 绑定到独立端口，避免对外暴露
```

---

## 二、核心内置端点

| 端点路径 | HTTP 方法 | 功能 |
|---------|---------|------|
| `/actuator/health` | GET | 健康状态（UP/DOWN/OUT_OF_SERVICE）|
| `/actuator/health/liveness` | GET | K8s 存活探针 |
| `/actuator/health/readiness` | GET | K8s 就绪探针 |
| `/actuator/info` | GET | 应用信息（版本、Git 提交等）|
| `/actuator/metrics` | GET | 所有指标列表 |
| `/actuator/metrics/{name}` | GET | 具体指标值 |
| `/actuator/prometheus` | GET | Prometheus 格式指标 |
| `/actuator/env` | GET | 配置环境变量 |
| `/actuator/loggers/{name}` | POST | 动态修改日志级别 |
| `/actuator/heapdump` | GET | 触发 Heap Dump |
| `/actuator/threaddump` | GET | 当前线程快照 |

---

## 三、自定义 HealthIndicator

`HealthIndicator` 是 `/actuator/health` 的扩展接口，Spring 内置了 DB、Redis、RabbitMQ 等的实现：

```java
// Spring Boot 3.2 + JDK 17
// 场景：检查外部依赖的支付网关是否可达
@Component
public class PaymentGatewayHealthIndicator implements HealthIndicator {

    @Autowired
    private PaymentGatewayClient gatewayClient;

    @Override
    public Health health() {
        try {
            // 调用支付网关的心跳接口
            boolean alive = gatewayClient.ping();
            if (alive) {
                return Health.up()
                    .withDetail("gateway", "payment-gateway-v2")
                    .withDetail("latency", gatewayClient.getLastPingLatencyMs() + "ms")
                    .build();
            } else {
                return Health.down()
                    .withDetail("reason", "ping returned false")
                    .build();
            }
        } catch (Exception ex) {
            return Health.down(ex)
                .withDetail("error", ex.getMessage())
                .build();
        }
    }
}
```

健康检查结果聚合后影响整体状态：任意一个 `HealthIndicator` 返回 `DOWN`，`/actuator/health` 返回 `503 Service Unavailable`。

### K8s 探针区分存活与就绪

```java
// 就绪探针：控制是否接收流量（初始化完成才就绪）
@Component
public class CacheWarmupReadinessIndicator implements ReadinessHealthIndicator {

    private volatile boolean cacheWarmed = false;

    @EventListener(ApplicationReadyEvent.class)
    public void warmCache() {
        // 预热缓存
        cacheService.warmup();
        cacheWarmed = true;
    }

    @Override
    public Health health() {
        return cacheWarmed
            ? Health.up().build()
            : Health.outOfService().withDetail("reason", "cache warming in progress").build();
    }
}
```

---

## 四、自定义 Endpoint

```java
// Spring Boot 3.2 + JDK 17
// 场景：暴露当前线程池状态（通过自定义 Endpoint）

@Endpoint(id = "threadpools") // 路径：/actuator/threadpools
@Component
public class ThreadPoolEndpoint {

    @Autowired
    @Qualifier("taskExecutor")
    private ThreadPoolTaskExecutor taskExecutor;

    // GET /actuator/threadpools
    @ReadOperation
    public Map<String, Object> threadPoolStatus() {
        ThreadPoolExecutor executor = taskExecutor.getThreadPoolExecutor();
        Map<String, Object> status = new LinkedHashMap<>();
        status.put("corePoolSize", executor.getCorePoolSize());
        status.put("maximumPoolSize", executor.getMaximumPoolSize());
        status.put("activeCount", executor.getActiveCount());
        status.put("poolSize", executor.getPoolSize());
        status.put("queueSize", executor.getQueue().size());
        status.put("completedTaskCount", executor.getCompletedTaskCount());
        return status;
    }

    // POST /actuator/threadpools (修改核心线程数)
    @WriteOperation
    public String resizeCorePool(@Selector String poolName, int coreSize) {
        taskExecutor.setCorePoolSize(coreSize);
        return "Core pool size updated to " + coreSize;
    }
}
```

---

## 五、Micrometer 自定义业务指标

Micrometer（JVM 指标库，Spring Boot Actuator 的指标后端）支持 Counter、Gauge、Timer、DistributionSummary 四种基本类型：

```java
// Spring Boot 3.2 + JDK 17 + Micrometer
@Service
public class OrderService {

    private final Counter orderCreatedCounter;
    private final Counter orderFailedCounter;
    private final Timer orderProcessingTimer;

    // 通过构造器注入 MeterRegistry
    public OrderService(MeterRegistry meterRegistry) {
        this.orderCreatedCounter = Counter.builder("order.created")
            .description("Total orders created")
            .tag("env", System.getenv().getOrDefault("APP_ENV", "local"))
            .register(meterRegistry);

        this.orderFailedCounter = Counter.builder("order.failed")
            .description("Total orders failed")
            .register(meterRegistry);

        this.orderProcessingTimer = Timer.builder("order.processing.time")
            .description("Order processing duration")
            .publishPercentiles(0.5, 0.95, 0.99) // P50/P95/P99
            .register(meterRegistry);
    }

    public Order placeOrder(OrderRequest request) {
        return orderProcessingTimer.record(() -> { // 计时
            try {
                Order order = doPlaceOrder(request);
                orderCreatedCounter.increment(); // 计数
                return order;
            } catch (Exception e) {
                orderFailedCounter.increment();
                throw e;
            }
        });
    }
}

// Gauge 示例：监控活跃连接数（实时值）
@Component
public class ActiveConnectionMetric {
    public ActiveConnectionMetric(MeterRegistry registry, ConnectionPool pool) {
        Gauge.builder("connection.pool.active", pool, ConnectionPool::getActiveCount)
            .description("Active connections in pool")
            .register(registry);
    }
}
```

Prometheus 会定期抓取 `/actuator/prometheus`，这些自定义指标自动包含在内，可在 Grafana 中配置告警和可视化。

---

## 六、生产安全配置

Actuator 端点会暴露敏感信息，生产环境必须做安全防护：

```yaml
# 方案一：绑定到独立内部端口（推荐）
management:
  server:
    port: 8081      # 只在内网暴露
    address: 127.0.0.1  # 只允许本机访问

# 方案二：Spring Security 保护（如果 Actuator 和业务在同一端口）
# 在 SecurityFilterChain 中配置：
# .requestMatchers("/actuator/**").hasRole("ACTUATOR_ADMIN")
```

---

## 七、踩坑总结

❌ **生产环境 `/actuator/env` 暴露了数据库密码等敏感配置**

✅ `/actuator/env` 会显示所有配置属性（含密码），即使配置了 `spring.datasource.password`。生产必须：①将 Actuator 绑定到内网端口；②只暴露必要的端点（`include: health,info,metrics,prometheus`）；③配置 Spring Security 或网关鉴权保护 Actuator 路径。

❌ **K8s 就绪探针用 `/actuator/health` 而非 `/actuator/health/readiness`，导致 DB 连接失败时 Pod 被摘流，期间正在处理的请求全部失败**

✅ K8s 建议分开使用：`livenessProbe` 对应 `/actuator/health/liveness`（容器是否存活），`readinessProbe` 对应 `/actuator/health/readiness`（容器是否就绪接收流量）。就绪探针应该只检查应用本身的初始化状态，不应包含外部依赖（DB、Redis）的健康检查——外部依赖故障时不应让 Pod 被摘流，而应降级处理。

---

## 八、文章小结

- Actuator 通过独立端点暴露应用健康、指标、配置等可观测信息，是生产监控体系的基础
- `HealthIndicator` 可自定义外部依赖的健康检查，K8s 探针应区分存活（liveness）和就绪（readiness）
- 自定义 Endpoint 用 `@Endpoint(id=xxx)` + `@ReadOperation/@WriteOperation` 声明，可暴露任意业务状态
- Micrometer 提供 Counter/Gauge/Timer/Summary 四种指标类型，通过 `/actuator/prometheus` 与 Prometheus 对接
- 生产环境必须通过独立端口或 Security 保护 Actuator，避免敏感信息泄露

---

## 九、思考题

1. `health` 端点聚合了多个 `HealthIndicator` 的结果，如果有 5 个检查项，其中一个是非关键的外部接口偶发超时，应该如何避免这个检查项影响整体健康状态？

2. Micrometer 的 Timer 记录了 P99 耗时，但你发现 P99 在高峰时段异常飙高，具体哪个请求路径导致的如何定位？

---

## 参考资料

> 1. [Spring Boot Actuator 官方文档](https://docs.spring.io/spring-boot/docs/current/reference/html/actuator.html)
> 2. [Micrometer 官方文档 - Concepts](https://micrometer.io/docs/concepts)
> 3. [Prometheus + Grafana 与 Spring Boot 集成](2026-02-07-prometheus-grafana.md)
> 4. [SB-07 Spring Boot 启动流程](2026-05-24-spring-boot-startup.md)
