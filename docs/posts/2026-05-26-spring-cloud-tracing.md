# SC-07 分布式链路追踪：Micrometer Tracing + SkyWalking 实战

> 📚 **本文属于「Spring Cloud 微服务实战」系列**
> - [SC-01 Spring Cloud 微服务全景：架构演进与组件选型](posts/2025-06-27-spring-cloud-overview.md)
> - [SC-02 Nacos 服务注册与配置中心实战](posts/2025-02-15-nacos-registry-config.md)
> - [SC-03 Spring Cloud Gateway：路由、过滤器与灰度发布](posts/2026-05-26-spring-cloud-gateway.md)
> - [SC-04 OpenFeign 深度实战：声明式调用、拦截器与熔断](posts/2025-09-06-openfeign-timeout-retry.md)
> - [SC-05 Spring Cloud LoadBalancer：负载均衡原理与自定义策略](posts/2026-05-26-spring-cloud-loadbalancer.md)
> - [SC-06 Sentinel 流量防护：限流、熔断与热点规则](posts/2025-04-26-sentinel-rate-limit.md)
> - 👉 **SC-07 分布式链路追踪：Micrometer Tracing + SkyWalking 实战（本文）**
> - [SC-08 微服务安全：Gateway + JWT 统一鉴权方案](posts/2026-05-26-spring-cloud-security.md)
> - [SC-09 Seata 分布式事务：AT/TCC/Saga 三模式对比实战](posts/2025-01-11-seata-distributed-transaction.md)
> - [SC-10 Nacos 配置治理进阶：多环境、灰度与动态刷新](posts/2026-05-26-nacos-config-advanced.md)
> - [SC-11 微服务可观测性：Actuator + Prometheus + Grafana](posts/2026-05-26-spring-cloud-observability.md)
> - [SC-12 微服务最佳实践：接口幂等、版本兼容与蓝绿部署](posts/2026-05-26-microservice-best-practices.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 25 分钟｜**分类**：微服务

## 导读

一个下单请求经过 Gateway → 订单服务 → 库存服务 → 支付服务，中间某环节超时，你如何快速定位是哪一跳出了问题？链路追踪（Distributed Tracing）正是为此而生。本文讲解 TraceId/SpanId 模型、Micrometer Tracing + Zipkin 快速接入，以及生产首选的 SkyWalking 全链路监控方案。

---

## 一、核心概念

### 1.1 Trace、Span、TraceId

```
一次完整请求 = 一个 Trace
  |
  +-- Span 1: Gateway 接收请求          (traceId=abc, spanId=001, parentSpanId=null)
       |
       +-- Span 2: 调用 order-service   (traceId=abc, spanId=002, parentSpanId=001)
            |
            +-- Span 3: 调用 inventory  (traceId=abc, spanId=003, parentSpanId=002)
            |
            +-- Span 4: 调用 payment    (traceId=abc, spanId=004, parentSpanId=002)
```

- **Trace**：一次完整的分布式请求，唯一标识为 `traceId`
- **Span**：Trace 中的一个原子操作单元（一次 RPC、一次 DB 查询），包含开始/结束时间、操作名、状态码
- **TraceId 传播**：调用方通过 HTTP Header（`traceparent` / `b3`）将 traceId 透传给被调方，形成完整调用链

### 1.2 两大方案对比

| 维度 | Micrometer Tracing + Zipkin | SkyWalking |
|------|----------------------------|------------|
| 接入方式 | 代码侵入（Spring Boot Starter） | Java Agent，**零代码侵入** |
| 数据上报 | HTTP/Kafka 推送到 Zipkin Server | gRPC 推送到 OAP Server |
| 存储后端 | Zipkin（内存/MySQL/Elasticsearch） | Elasticsearch / H2 / TiDB |
| UI 功能 | 基础调用链视图 | 拓扑图、告警、服务大盘 |
| 采样率控制 | 代码配置 | Agent 配置 |
| 适用场景 | 快速验证、小型项目 | 生产推荐，功能完整 |

---

## 二、方案一：Micrometer Tracing + Zipkin

### 2.1 依赖引入

```xml
<!-- pom.xml  Spring Boot 3.2 -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-tracing-bridge-brave</artifactId>  <!-- Brave 实现 -->
</dependency>
<dependency>
    <groupId>io.zipkin.reporter2</groupId>
    <artifactId>zipkin-reporter-brave</artifactId>
</dependency>
<!-- 上报到 Zipkin Server -->
<dependency>
    <groupId>io.zipkin.reporter2</groupId>
    <artifactId>zipkin-sender-urlconnection</artifactId>
</dependency>
```

### 2.2 配置

```yaml
# application.yml
management:
  tracing:
    sampling:
      probability: 1.0      # 采样率 1.0 = 100%（生产建议 0.1~0.2）
  zipkin:
    tracing:
      endpoint: http://zipkin-server:9411/api/v2/spans

logging:
  pattern:
    # 在日志中自动打印 traceId 和 spanId
    level: "%5p [${spring.application.name},%X{traceId},%X{spanId}]"
```

### 2.3 自动传播

Micrometer Tracing 与 Spring 组件自动集成，以下场景**无需手动编码**：

- **OpenFeign**：请求头自动注入 `b3` 或 `traceparent` Header
- **RestTemplate / WebClient**：通过拦截器自动传播
- **@Async 方法**：通过 `ObservationThreadLocalAccessor` 跨线程传播
- **Kafka Producer/Consumer**：通过消息头传播

### 2.4 手动创建 Span

```java
// OrderService.java  JDK 17 + Spring Boot 3.2
@Service
public class OrderService {

    @Autowired
    private Tracer tracer;   // io.micrometer.tracing.Tracer

    public Order createOrder(OrderRequest request) {
        // 手动创建子 Span，用于追踪复杂业务逻辑
        Span inventorySpan = tracer.nextSpan()
            .name("check-inventory")
            .tag("sku", request.getSku())
            .start();

        try (Tracer.SpanInScope scope = tracer.withSpan(inventorySpan)) {
            boolean available = inventoryClient.checkStock(request.getSku());
            if (!available) {
                inventorySpan.tag("result", "out-of-stock");
                throw new BusinessException("库存不足");
            }
            inventorySpan.tag("result", "ok");
        } finally {
            inventorySpan.end();   // 必须 end，否则 Span 不会上报
        }
        // ... 后续逻辑
    }
}
```

---

## 三、方案二：SkyWalking（生产推荐）

### 3.1 SkyWalking 架构

```
+------------------+     gRPC      +------------------+
|  Java Agent      | ----------->  |   OAP Server     |
|  (每个服务 JVM)  |               | (分析 + 聚合)    |
+------------------+               +--------+---------+
                                            |
                                   +--------v---------+
                                   |  Elasticsearch   |
                                   |  (数据存储)       |
                                   +------------------+
                                            |
                                   +--------v---------+
                                   |   SkyWalking UI  |
                                   |  (拓扑图 + 告警)  |
                                   +------------------+
```

### 3.2 Agent 接入（零代码侵入）

**Step 1：下载 SkyWalking Agent**

```bash
# 下载 SkyWalking 9.x
wget https://archive.apache.org/dist/skywalking/9.7.0/apache-skywalking-apm-9.7.0.tar.gz
tar -xzf apache-skywalking-apm-9.7.0.tar.gz
# agent 目录位于 apache-skywalking-apm-bin/agent/
```

**Step 2：JVM 启动参数添加 Agent**

```bash
# 启动服务时添加 -javaagent 参数
java -javaagent:/opt/skywalking/agent/skywalking-agent.jar \
     -Dskywalking.agent.service_name=order-service \
     -Dskywalking.collector.backend_service=oap-server:11800 \
     -jar order-service.jar
```

**Step 3：Docker 部署配置**

```yaml
# docker-compose.yml
services:
  order-service:
    image: order-service:latest
    environment:
      - JAVA_OPTS=-javaagent:/skywalking/agent/skywalking-agent.jar
                  -Dskywalking.agent.service_name=order-service
                  -Dskywalking.collector.backend_service=oap:11800
    volumes:
      - ./skywalking/agent:/skywalking/agent:ro

  oap-server:
    image: apache/skywalking-oap-server:9.7.0
    environment:
      - SW_STORAGE=elasticsearch
      - SW_STORAGE_ES_CLUSTER_NODES=elasticsearch:9200
    ports:
      - "11800:11800"   # gRPC 收数据端口
      - "12800:12800"   # HTTP REST 端口

  skywalking-ui:
    image: apache/skywalking-ui:9.7.0
    environment:
      - SW_OAP_ADDRESS=http://oap-server:12800
    ports:
      - "8080:8080"
```

### 3.3 自定义追踪（注解方式）

```java
// 需引入 skywalking-toolkit-trace 依赖（仅注解，Agent 运行时才生效）
<dependency>
    <groupId>org.apache.skywalking</groupId>
    <artifactId>apm-toolkit-trace</artifactId>
    <version>9.7.0</version>
</dependency>
```

```java
// PaymentService.java
@Service
public class PaymentService {

    // @Trace 注解的方法会被 Agent 自动创建 Span
    @Trace(operationName = "payment-process")
    @Tag(key = "orderId", value = "arg[0]")   // 记录参数
    public PaymentResult process(String orderId, BigDecimal amount) {
        // 在日志中打印当前 TraceId（Agent 自动注入）
        log.info("Processing payment, traceId={}", TraceContext.traceId());
        // ... 业务逻辑
    }
}
```

### 3.4 采样率配置

```yaml
# agent.config（SkyWalking Agent 配置文件）
# 采样率：0~10000，10000 = 100%，生产建议 1000（10%）
agent.sample_n_per_3_secs=-1    # -1 表示全采样
# 或通过环境变量
# SW_AGENT_SAMPLE=-1
```

---

## 四、跨线程 / 跨消息队列传播

### 4.1 线程池场景

```java
// Micrometer Tracing 跨线程传播
@Bean
public Executor tracingExecutor(ObservationRegistry registry) {
    // 使用 ContextExecutorService 包装，自动传播 Observation 上下文
    return new ObservationContextExecutorService(
        Executors.newFixedThreadPool(10), registry);
}
```

### 4.2 Kafka 消息传播

```java
// 生产者：将 traceId 写入消息头
@KafkaListener(topics = "order-created")
public void onOrderCreated(ConsumerRecord<String, String> record) {
    // SkyWalking Agent 自动从 Kafka Header 提取 TraceId 并续接链路
    // Micrometer Tracing 需手动提取
    String traceId = new String(record.headers()
        .lastHeader("sw8").value());   // SkyWalking 格式
    log.info("Received order event, traceId={}", traceId);
    // ...
}
```

---

## 五、踩坑总结

**❌ 坑 1：采样率设 100% 导致 OAP 磁盘爆满**

生产流量大时，100% 采样会产生海量 Span 数据：

```yaml
# ✅ 生产环境按流量调整采样率
# 高频接口（如健康检查）可通过 SkyWalking 的 ignore_suffix 忽略
agent.ignore_suffix=.jpg,.css,.js,/actuator/health
# 采样率设为 10%
agent.sample_n_per_3_secs=1000
```

**❌ 坑 2：@Async 方法中 TraceId 断链**

Spring `@Async` 默认的 `SimpleAsyncTaskExecutor` 不传播上下文：

```java
// ✅ 替换为支持 Tracing 上下文传播的线程池
@Bean
public TaskExecutor asyncExecutor(ObservationRegistry registry) {
    ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
    executor.setCorePoolSize(10);
    executor.initialize();
    // 包装为支持 Micrometer Tracing 上下文传播的执行器
    return new ObservationContextExecutorService(
        executor.getThreadPoolExecutor(), registry);
}
```

**❌ 坑 3：SkyWalking Agent 与 Lombok、ByteBuddy 版本冲突**

SkyWalking 通过字节码增强实现零侵入，可能与其他字节码工具冲突：

```bash
# ✅ 升级到 SkyWalking Agent 9.x，并在 agent.config 中排除冲突插件
agent.exclude_plugins=apm-spring-annotation-plugin-9.x.jar
```

---

## 六、文章小结

- **TraceId + SpanId** 是分布式追踪的基石，通过 HTTP Header 在服务间传播，串联完整调用链
- **Micrometer Tracing** 与 Spring Boot 3.x 深度集成，自动追踪 OpenFeign、RestTemplate、Kafka 等调用，适合快速接入
- **SkyWalking Agent** 零代码侵入，提供完整的服务拓扑图、性能大盘和告警规则，是生产环境首选
- 生产采样率建议设为 **5%~10%**，避免磁盘和 OAP 压力；高价值链路（支付、下单）可设置强制采样标记

## 七、思考题

1. TraceId 在跨服务传播时使用 HTTP Header，如果中间某个服务没有接入追踪组件，链路会断吗？如何处理？
2. 压测环境和生产环境共用一套 SkyWalking 时，如何区分压测流量和真实流量的追踪数据？
3. SkyWalking 的 Segment（SkyWalking 特有概念）和 OpenTracing 的 Span 有什么区别？

## 参考资料

- [SkyWalking 9.x 官方文档](https://skywalking.apache.org/docs/)
- [Micrometer Tracing 文档（Spring Boot 3.x）](https://micrometer.io/docs/tracing)
- [OpenTelemetry 规范（W3C TraceContext）](https://www.w3.org/TR/trace-context/)
- [Zipkin 快速入门](https://zipkin.io/pages/quickstart.html)
