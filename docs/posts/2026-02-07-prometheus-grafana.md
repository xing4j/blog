# Prometheus + Grafana：Spring Boot 监控实践

<div class="post-meta">📅 2026-02-07 &nbsp;·&nbsp; 🏷️ <span class="tag">监控</span> <span class="tag">DevOps</span></div>

Prometheus 负责采集指标，Grafana 负责可视化，是生产环境监控的黄金组合。

---

## 一、架构概览

```
Spring Boot 应用
  └── /actuator/prometheus 暴露 metrics

Prometheus（拉取模式）
  └── 每 15s 抓取一次 /actuator/prometheus

Grafana
  └── 查询 Prometheus 数据，绘制图表

Alertmanager
  └── Prometheus 触发告警规则 → 发送到邮件/钉钉/企业微信
```

---

## 二、Spring Boot 集成

```xml
<!-- pom.xml -->
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
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
        include: health,info,prometheus,metrics
  endpoint:
    prometheus:
      enabled: true
  metrics:
    tags:
      application: ${spring.application.name}  # 所有指标加上应用名标签
    distribution:
      percentiles-histogram:
        http.server.requests: true  # 开启请求延迟直方图
      percentiles:
        http.server.requests: [0.5, 0.95, 0.99]  # P50/P95/P99
```

---

## 三、自定义业务指标

```java
import io.micrometer.core.instrument.*;

@Service
public class OrderService {
    private final Counter orderCreated;
    private final Timer orderProcessTimer;
    private final Gauge pendingOrders;
    
    private AtomicInteger pendingCount = new AtomicInteger(0);

    public OrderService(MeterRegistry registry) {
        // 计数器：订单创建次数
        orderCreated = Counter.builder("order.created.total")
            .description("订单创建总数")
            .tag("status", "success")
            .register(registry);

        // 计时器：订单处理耗时
        orderProcessTimer = Timer.builder("order.process.duration")
            .description("订单处理耗时")
            .register(registry);

        // 仪表盘：当前待处理订单数
        pendingOrders = Gauge.builder("order.pending.count", pendingCount, AtomicInteger::get)
            .description("待处理订单数量")
            .register(registry);
    }

    public Order createOrder(OrderRequest req) {
        return orderProcessTimer.record(() -> {
            // 业务逻辑
            Order order = doCreateOrder(req);
            orderCreated.increment();
            pendingCount.incrementAndGet();
            return order;
        });
    }
}
```

---

## 四、Prometheus 配置

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "rules/*.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

scrape_configs:
  - job_name: 'spring-boot-apps'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets:
          - 'app1:8080'
          - 'app2:8080'
    # 或使用服务发现（K8s 环境）
  
  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
```

---

## 五、告警规则

```yaml
# rules/spring-boot.yml
groups:
  - name: spring-boot
    rules:
      # 服务不可用告警
      - alert: ServiceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "服务 {{ $labels.job }} 不可用"
          description: "{{ $labels.instance }} 已离线超过 1 分钟"

      # 高错误率告警
      - alert: HighErrorRate
        expr: |
          rate(http_server_requests_seconds_count{status=~"5.."}[5m]) 
          / rate(http_server_requests_seconds_count[5m]) > 0.05
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "服务 {{ $labels.application }} 5xx 错误率超过 5%"

      # JVM 堆内存告警
      - alert: HighHeapUsage
        expr: |
          jvm_memory_used_bytes{area="heap"} 
          / jvm_memory_max_bytes{area="heap"} > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.application }} 堆内存使用率超过 85%"
```

---

## 六、Grafana 常用 PromQL

```promql
# HTTP 请求 QPS
rate(http_server_requests_seconds_count{application="myapp"}[1m])

# P99 延迟（毫秒）
histogram_quantile(0.99, 
  rate(http_server_requests_seconds_bucket{application="myapp"}[5m])
) * 1000

# 5xx 错误率
rate(http_server_requests_seconds_count{status=~"5.."}[5m])
/ rate(http_server_requests_seconds_count[5m])

# JVM 堆内存使用率
jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"} * 100

# GC 频率（次/分钟）
rate(jvm_gc_pause_seconds_count[1m]) * 60

# 线程池活跃线程数
executor_active_threads{name="threadPoolExecutor"}
```

---

## 七、Docker Compose 快速搭建

```yaml
# monitoring/docker-compose.yml
services:
  prometheus:
    image: prom/prometheus:v2.47.0
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    ports: ["9090:9090"]

  grafana:
    image: grafana/grafana:10.0.0
    environment:
      GF_SECURITY_ADMIN_PASSWORD: admin123
    volumes:
      - grafana-data:/var/lib/grafana
    ports: ["3000:3000"]

volumes:
  prometheus-data:
  grafana-data:
```

---

## 总结

监控关键指标（RED 方法）：  
- **Rate**：QPS（每秒请求数）  
- **Errors**：错误率  
- **Duration**：请求延迟（P95/P99）  

推荐 Grafana Dashboard ID：`4701`（JVM Micrometer）、`12900`（Spring Boot）
