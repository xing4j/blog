# SC-11 微服务可观测性：Actuator + Prometheus + Grafana

> 📚 **本文属于「Spring Cloud 微服务实战」系列**
> - [SC-01 Spring Cloud 微服务全景：架构演进与组件选型](2025-06-27-spring-cloud-overview.md)
> - [SC-02 Nacos 服务注册与配置中心实战](2025-02-15-nacos-registry-config.md)
> - [SC-03 Spring Cloud Gateway：路由、过滤器与灰度发布](2026-05-26-spring-cloud-gateway.md)
> - [SC-04 OpenFeign 深度实战：声明式调用、拦截器与熔断](2025-09-06-openfeign-timeout-retry.md)
> - [SC-05 Spring Cloud LoadBalancer：负载均衡原理与自定义策略](2026-05-26-spring-cloud-loadbalancer.md)
> - [SC-06 Sentinel 流量防护：限流、熔断与热点规则](2025-04-26-sentinel-rate-limit.md)
> - [SC-07 分布式链路追踪：Micrometer Tracing + SkyWalking 实战](2026-05-26-spring-cloud-tracing.md)
> - [SC-08 微服务安全：Gateway + JWT 统一鉴权方案](2026-05-26-spring-cloud-security.md)
> - [SC-09 Seata 分布式事务：AT/TCC/Saga 三模式对比实战](2025-01-11-seata-distributed-transaction.md)
> - [SC-10 Nacos 配置治理进阶：多环境、灰度与动态刷新](2026-05-26-nacos-config-advanced.md)
> - 👉 **SC-11 微服务可观测性：Actuator + Prometheus + Grafana（本文）**
> - [SC-12 微服务最佳实践：接口幂等、版本兼容与蓝绿部署](2026-05-26-microservice-best-practices.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 25 分钟｜**分类**：微服务

## 导读

可观测性（Observability）由三大支柱构成：Metrics（指标）、Logs（日志）、Traces（链路追踪）。SC-07 讲了链路追踪，本文聚焦 Metrics：通过 Spring Boot Actuator 暴露指标、Prometheus 采集、Grafana 可视化，再到 Alertmanager 告警，构建完整的微服务监控体系。

---

## 一、可观测性三大支柱

| 支柱 | 回答的问题 | 工具 |
|------|-----------|------|
| **Metrics（指标）** | 系统现在运行状态如何？QPS 是多少？响应时间 P99 多少？ | Micrometer + Prometheus + Grafana |
| **Logs（日志）** | 发生了什么事件？报错信息是什么？ | Logback + ELK（Elasticsearch + Logstash + Kibana） |
| **Traces（链路）** | 一次请求经过了哪些服务？每一跳耗时多少？ | SkyWalking / Micrometer Tracing（见 SC-07） |

三者相互补充：Metrics 发现异常 → Traces 定位问题链路 → Logs 找到根因。

---

## 二、Spring Boot Actuator 配置

### 2.1 依赖引入

```xml
<!-- pom.xml  Spring Boot 3.2 -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<!-- Micrometer Prometheus Registry：将 Actuator 指标转为 Prometheus 格式 -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

### 2.2 暴露端点配置

```yaml
# application.yml
management:
  endpoints:
    web:
      exposure:
        # 生产环境只暴露必要端点，不要暴露 /shutdown、/env 等危险端点
        include: health,info,prometheus,metrics
      base-path: /actuator
  endpoint:
    health:
      show-details: when-authorized   # 只对已鉴权请求显示详情
      show-components: when-authorized
    prometheus:
      enabled: true
  metrics:
    tags:
      # 给所有指标打上服务名和环境标签，Grafana 过滤时用
      application: ${spring.application.name}
      env: ${spring.profiles.active:dev}
    distribution:
      percentiles-histogram:
        http.server.requests: true    # 开启 HTTP 请求耗时直方图（P50/P90/P99）
      percentiles:
        http.server.requests: 0.5, 0.9, 0.95, 0.99
```

### 2.3 自定义健康检查

```java
// OrderServiceHealthIndicator.java  自定义健康检查端点
@Component("orderService")
public class OrderServiceHealthIndicator implements HealthIndicator {

    @Autowired
    private DataSource dataSource;

    @Autowired
    private RedisTemplate<String, String> redisTemplate;

    @Override
    public Health health() {
        Health.Builder builder = Health.up();

        // 检查数据库连接
        try (Connection conn = dataSource.getConnection()) {
            builder.withDetail("db", "OK");
        } catch (SQLException e) {
            return Health.down()
                .withDetail("db", "Connection failed: " + e.getMessage())
                .build();
        }

        // 检查 Redis 连接
        try {
            redisTemplate.opsForValue().get("health-check-ping");
            builder.withDetail("redis", "OK");
        } catch (Exception e) {
            builder.down().withDetail("redis", "Connection failed");
        }

        return builder.build();
    }
}
```

访问 `/actuator/health` 响应：
```json
{
  "status": "UP",
  "components": {
    "orderService": {
      "status": "UP",
      "details": { "db": "OK", "redis": "OK" }
    },
    "diskSpace": { "status": "UP" }
  }
}
```

---

## 三、自定义业务指标

### 3.1 Counter（计数器）：统计事件发生次数

```java
// OrderMetrics.java  业务指标采集
@Component
public class OrderMetrics {

    private final Counter orderCreatedCounter;
    private final Counter orderFailedCounter;
    private final DistributionSummary orderAmountSummary;

    public OrderMetrics(MeterRegistry registry) {
        // 订单创建成功计数（按支付方式分组）
        this.orderCreatedCounter = Counter.builder("order.created.total")
            .description("Total number of orders created")
            .tag("service", "order-service")
            .register(registry);

        this.orderFailedCounter = Counter.builder("order.failed.total")
            .description("Total number of failed orders")
            .register(registry);

        // 订单金额分布（DistributionSummary 适合数值分布统计）
        this.orderAmountSummary = DistributionSummary.builder("order.amount")
            .description("Order amount distribution")
            .baseUnit("yuan")
            .publishPercentiles(0.5, 0.9, 0.99)
            .register(registry);
    }

    public void recordOrderCreated(String payType) {
        // 带动态 Tag 的计数（按支付方式区分）
        Counter.builder("order.created.total")
            .tag("pay_type", payType)
            .register(Metrics.globalRegistry)
            .increment();
    }

    public void recordOrderFailed(String reason) {
        Counter.builder("order.failed.total")
            .tag("reason", reason)
            .register(Metrics.globalRegistry)
            .increment();
    }

    public void recordOrderAmount(double amount) {
        orderAmountSummary.record(amount);
    }
}
```

### 3.2 Timer（计时器）：统计操作耗时

```java
// InventoryService.java  记录第三方调用耗时
@Service
public class InventoryService {

    @Autowired
    private MeterRegistry meterRegistry;

    public boolean checkStock(String sku) {
        // 用 Timer 记录调用耗时，自动统计 P50/P95/P99
        return Timer.builder("inventory.check.duration")
            .description("Time spent checking inventory")
            .tag("sku_category", extractCategory(sku))
            .register(meterRegistry)
            .record(() -> {
                // 实际业务调用
                return inventoryClient.checkStock(sku);
            });
    }
}
```

### 3.3 Gauge（仪表盘）：反映当前状态值

```java
// 监控线程池队列积压（实时值用 Gauge）
@Bean
public ThreadPoolExecutor orderExecutor(MeterRegistry registry) {
    ThreadPoolExecutor executor = new ThreadPoolExecutor(
        10, 50, 60, TimeUnit.SECONDS, new LinkedBlockingQueue<>(1000));

    // 注册队列积压指标
    Gauge.builder("order.executor.queue.size",
            executor, e -> e.getQueue().size())
        .description("Order executor queue size")
        .register(registry);

    Gauge.builder("order.executor.active.threads",
            executor, ThreadPoolExecutor::getActiveCount)
        .description("Active thread count in order executor")
        .register(registry);

    return executor;
}
```

---

## 四、Prometheus + Grafana 部署

### 4.1 Prometheus 采集配置

```yaml
# prometheus.yml
global:
  scrape_interval: 15s      # 每 15 秒采集一次
  evaluation_interval: 15s

scrape_configs:
  # 静态配置（适合固定服务）
  - job_name: 'order-service'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets: ['order-service:8080']
        labels:
          service: order-service
          env: prod

  # 动态发现（适合 K8s 或多实例服务）
  - job_name: 'spring-cloud-services'
    metrics_path: '/actuator/prometheus'
    # 从 Nacos 动态发现服务实例（需要 prometheus-nacos-discovery 插件）
    nacos_sd_configs:
      - server: nacos-server:8848
        namespace_id: prod
```

### 4.2 Docker Compose 一键启动监控栈

```yaml
# docker-compose.monitoring.yml
services:
  prometheus:
    image: prom/prometheus:v2.47.0
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    ports:
      - "9090:9090"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=30d'   # 数据保留 30 天

  grafana:
    image: grafana/grafana:10.1.0
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin123
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning  # 预置 Dashboard
    ports:
      - "3000:3000"
    depends_on:
      - prometheus

  alertmanager:
    image: prom/alertmanager:v0.26.0
    volumes:
      - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml
    ports:
      - "9093:9093"

volumes:
  prometheus_data:
  grafana_data:
```

### 4.3 关键 PromQL 查询

```promql
# 接口 QPS（每秒请求数）
rate(http_server_requests_seconds_count{application="order-service"}[1m])

# P99 响应时间（毫秒）
histogram_quantile(0.99,
  rate(http_server_requests_seconds_bucket{application="order-service"}[5m])
) * 1000

# 错误率（5xx 响应占比）
rate(http_server_requests_seconds_count{status=~"5.."}[1m])
/
rate(http_server_requests_seconds_count[1m])

# JVM 堆内存使用率
jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"}

# 线程池队列积压
order_executor_queue_size{application="order-service"}
```

---

## 五、告警规则配置

```yaml
# alert-rules.yml（Prometheus 告警规则）
groups:
  - name: spring-cloud-alerts
    rules:
      # 服务实例下线告警
      - alert: ServiceInstanceDown
        expr: up{job="spring-cloud-services"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Service instance {{ $labels.instance }} is down"
          description: "{{ $labels.service }} has been down for more than 1 minute"

      # P99 响应时间超过 2 秒
      - alert: HighResponseTime
        expr: |
          histogram_quantile(0.99,
            rate(http_server_requests_seconds_bucket[5m])
          ) > 2
        for: 3m
        labels:
          severity: warning
        annotations:
          summary: "High P99 response time on {{ $labels.application }}"
          description: "P99 latency is {{ $value | humanizeDuration }}"

      # 错误率超过 5%
      - alert: HighErrorRate
        expr: |
          rate(http_server_requests_seconds_count{status=~"5.."}[5m])
          /
          rate(http_server_requests_seconds_count[5m]) > 0.05
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "High error rate on {{ $labels.application }}"
          description: "Error rate is {{ $value | humanizePercentage }}"

      # JVM 堆内存超过 85%
      - alert: JvmHeapUsageHigh
        expr: |
          jvm_memory_used_bytes{area="heap"}
          / jvm_memory_max_bytes{area="heap"} > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "JVM heap usage high on {{ $labels.application }}"
```

---

## 六、踩坑总结

**❌ 坑 1：`/actuator/prometheus` 暴露在公网**

Prometheus 端点包含服务内部状态信息，不应公开访问：

```yaml
# ✅ 将 Actuator 端口与业务端口分离（Spring Boot 支持独立 management 端口）
management:
  server:
    port: 8081    # Actuator 端口，只在内网可访问
  endpoints:
    web:
      exposure:
        include: health,prometheus,metrics
```

**❌ 坑 2：高基数（High Cardinality）Tag 导致 Prometheus 崩溃**

Tag 的取值空间越大，时间序列越多，内存消耗越大：

```java
// ❌ 错误：用 userId 或 orderId 作为 Tag（取值无界）
Counter.builder("order.created")
    .tag("user_id", userId)    // 百万用户 = 百万条时间序列，Prometheus OOM
    .register(registry);

// ✅ 正确：Tag 只用有限枚举值（支付类型、渠道、状态码等）
Counter.builder("order.created")
    .tag("pay_type", payType)  // 取值有限：alipay/wechat/bank_card
    .register(registry);
```

**❌ 坑 3：未配置 percentiles-histogram，P99 无法计算**

```yaml
# ✅ 必须开启直方图，histogram_quantile() 才能计算分位数
management:
  metrics:
    distribution:
      percentiles-histogram:
        http.server.requests: true
```

---

## 七、文章小结

- **可观测性三支柱**：Metrics 监控运行状态，Logs 记录事件，Traces 追踪请求链路，三者配合快速定位问题
- **Actuator + Micrometer + Prometheus** 是 Spring Cloud 生态的标准监控方案；Micrometer 作为门面，底层可替换为任意监控系统
- 自定义业务指标时，Counter 统计累计次数、Timer 统计耗时分布、Gauge 反映实时状态，**避免将无界值（userId、orderId）作为 Tag**
- **告警规则**是监控的最终价值体现，建议至少配置：实例下线、P99 超阈值、错误率超阈值、JVM 堆内存超阈值

## 八、思考题

1. Prometheus 是拉取模型（Pull），Kafka 等消息队列适合推送模型（Push）。如果某个服务运行在防火墙后无法被 Prometheus 拉取，应该怎么办？
2. 业务指标（如订单创建数）和基础设施指标（JVM 内存）的告警阈值应该如何制定？有什么方法论？
3. Grafana 的 Dashboard 应该如何版本化管理？如何做到重新部署后 Dashboard 不丢失？

## 参考资料

- [Micrometer 官方文档](https://micrometer.io/docs)
- [Spring Boot Actuator 文档](https://docs.spring.io/spring-boot/reference/actuator/index.html)
- [Prometheus 最佳实践](https://prometheus.io/docs/practices/naming/)
- [Grafana Spring Boot Dashboard（社区模板 ID 4701）](https://grafana.com/grafana/dashboards/4701)
