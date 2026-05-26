# SC-05 Spring Cloud LoadBalancer：负载均衡原理与自定义策略

> 📚 **本文属于「Spring Cloud 微服务实战」系列**
> - [SC-01 Spring Cloud 微服务全景：架构演进与组件选型](2025-06-27-spring-cloud-overview.md)
> - [SC-02 Nacos 服务注册与配置中心实战](2025-02-15-nacos-registry-config.md)
> - [SC-03 Spring Cloud Gateway：路由、过滤器与灰度发布](2026-05-26-spring-cloud-gateway.md)
> - [SC-04 OpenFeign 深度实战：声明式调用、拦截器与熔断](2025-09-06-openfeign-timeout-retry.md)
> - 👉 **SC-05 Spring Cloud LoadBalancer：负载均衡原理与自定义策略（本文）**
> - [SC-06 Sentinel 流量防护：限流、熔断与热点规则](2025-04-26-sentinel-rate-limit.md)
> - [SC-07 分布式链路追踪：Micrometer Tracing + SkyWalking 实战](2026-05-26-spring-cloud-tracing.md)
> - [SC-08 微服务安全：Gateway + JWT 统一鉴权方案](2026-05-26-spring-cloud-security.md)
> - [SC-09 Seata 分布式事务：AT/TCC/Saga 三模式对比实战](2025-01-11-seata-distributed-transaction.md)
> - [SC-10 Nacos 配置治理进阶：多环境、灰度与动态刷新](2026-05-26-nacos-config-advanced.md)
> - [SC-11 微服务可观测性：Actuator + Prometheus + Grafana](2026-05-26-spring-cloud-observability.md)
> - [SC-12 微服务最佳实践：接口幂等、版本兼容与蓝绿部署](2026-05-26-microservice-best-practices.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 20 分钟｜**分类**：微服务

## 导读

Ribbon 已停止维护，Spring Cloud 2021.x 起默认使用 Spring Cloud LoadBalancer（SCL）作为客户端负载均衡器。本文讲解 SCL 的工作原理、内置策略，以及如何实现加权轮询、区域感知等自定义策略——读完你能在 OpenFeign 和 Gateway 中灵活控制流量分发。

---

## 一、客户端 vs 服务端负载均衡

| 维度 | 客户端负载均衡（SCL） | 服务端负载均衡（Nginx/SLB） |
|------|---------------------|--------------------------|
| 位置 | 在调用方 JVM 内 | 独立的代理层 |
| 服务发现 | 直接读注册中心实例列表 | 由代理层维护后端列表 |
| 网络跳数 | 调用方 -> 目标实例（1 跳） | 调用方 -> 代理 -> 目标实例（2 跳） |
| 动态感知 | 实时（缓存刷新周期内） | 依赖代理配置刷新频率 |
| 适用场景 | 微服务内部调用 | 外部流量入口、跨语言服务 |

Spring Cloud LoadBalancer 是**客户端负载均衡**：调用方从 Nacos/Eureka 拉取服务实例列表，在本地按策略选择一个实例直接发起请求，不经过代理层。

---

## 二、SCL 工作原理

### 2.1 核心流程

```
OpenFeign 发起调用
  |
  v
ReactorLoadBalancerExchangeFilterFunction
  |  (或 BlockingLoadBalancerClient，取决于 WebClient/RestTemplate)
  v
ReactorServiceInstanceLoadBalancer
  |-- 调用 ServiceInstanceListSupplier.get() 获取实例列表
  |     |-- NacosServiceDiscovery 从注册中心拉取（有缓存，默认 35s 刷新）
  v
RoundRobinLoadBalancer / RandomLoadBalancer / 自定义
  |-- 按策略选择一个 ServiceInstance
  v
重构请求 URL（替换 lb://service-name 为 http://ip:port）
  v
实际 HTTP 调用
```

### 2.2 依赖引入

Spring Cloud Gateway 和 OpenFeign 都依赖 SCL，显式引入：

```xml
<!-- pom.xml  Spring Cloud 2023.0.x -->
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-loadbalancer</artifactId>
</dependency>
<!-- 排除旧版 Ribbon（Spring Boot 2.x 项目迁移时需要） -->
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-netflix-ribbon</artifactId>
    <scope>provided</scope>  <!-- 或直接 exclude -->
</dependency>
```

### 2.3 实例列表缓存机制

SCL 不会每次请求都去注册中心查询，而是在本地维护一份**缓存列表**：

```yaml
spring:
  cloud:
    loadbalancer:
      cache:
        enabled: true           # 默认开启
        ttl: 35s                # 缓存过期时间（默认 35 秒）
        capacity: 256           # 最大缓存服务数
      health-check:
        enabled: true           # 启用健康检查，自动移除不健康实例
        interval: 25s           # 健康检查间隔
```

**注意**：缓存 TTL 内下线的实例仍可能被路由到，导致调用失败。生产中建议搭配重试策略（见 SC-04）。

---

## 三、内置策略

### 3.1 轮询（RoundRobin，默认）

```java
// RoundRobinLoadBalancer 核心逻辑（简化）
// 使用 AtomicInteger 保证并发安全
private final AtomicInteger position = new AtomicInteger(0);

public Mono<Response<ServiceInstance>> choose(Request request) {
    return serviceInstanceListSupplier.get(request)
        .next()
        .map(instances -> {
            if (instances.isEmpty()) return new EmptyResponse();
            int pos = Math.abs(position.incrementAndGet());
            ServiceInstance instance = instances.get(pos % instances.size());
            return new DefaultResponse(instance);
        });
}
```

适合所有实例配置相同、处理能力均等的场景。

### 3.2 随机（Random）

```yaml
spring:
  cloud:
    loadbalancer:
      configurations: random   # 切换为随机策略
```

或通过 `@LoadBalancerClient` 指定特定服务使用随机策略：

```java
// OrderServiceLoadBalancerConfig.java
// 注意：此配置类不能放在 @ComponentScan 扫描路径内
public class OrderServiceLoadBalancerConfig {
    @Bean
    public ReactorLoadBalancer<ServiceInstance> randomLoadBalancer(
            Environment env,
            LoadBalancerClientFactory factory) {
        String serviceId = env.getProperty(
            LoadBalancerClientFactory.PROPERTY_NAME);
        return new RandomLoadBalancer(
            factory.getLazyProvider(serviceId, ServiceInstanceListSupplier.class),
            serviceId);
    }
}

// 在调用方启动类或配置类上指定
@LoadBalancerClient(name = "order-service",
                   configuration = OrderServiceLoadBalancerConfig.class)
@SpringBootApplication
public class ConsumerApplication { ... }
```

---

## 四、自定义策略实战

### 4.1 加权轮询策略

Nacos 实例上设置权重（0.1 ~ 100），权重越高分配流量越多：

```java
// WeightedLoadBalancer.java  基于 Nacos 实例权重的加权轮询
@Slf4j
public class NacosWeightedLoadBalancer implements ReactorServiceInstanceLoadBalancer {

    private final String serviceId;
    private final ObjectProvider<ServiceInstanceListSupplier> supplierProvider;

    public NacosWeightedLoadBalancer(
            ObjectProvider<ServiceInstanceListSupplier> supplierProvider,
            String serviceId) {
        this.serviceId = serviceId;
        this.supplierProvider = supplierProvider;
    }

    @Override
    public Mono<Response<ServiceInstance>> choose(Request request) {
        ServiceInstanceListSupplier supplier = supplierProvider
            .getIfAvailable(NoopServiceInstanceListSupplier::new);
        return supplier.get(request).next().map(this::getInstanceResponse);
    }

    private Response<ServiceInstance> getInstanceResponse(
            List<ServiceInstance> instances) {
        if (instances.isEmpty()) {
            log.warn("No instances available for {}", serviceId);
            return new EmptyResponse();
        }
        // 按 Nacos 元数据中的 weight 字段加权随机选择
        double totalWeight = instances.stream()
            .mapToDouble(i -> Double.parseDouble(
                i.getMetadata().getOrDefault("nacos.weight", "1.0")))
            .sum();
        double rand = Math.random() * totalWeight;
        double current = 0;
        for (ServiceInstance instance : instances) {
            current += Double.parseDouble(
                instance.getMetadata().getOrDefault("nacos.weight", "1.0"));
            if (current >= rand) {
                return new DefaultResponse(instance);
            }
        }
        return new DefaultResponse(instances.get(instances.size() - 1));
    }
}
```

### 4.2 同机房优先（区域感知策略）

生产多机房部署时，优先调用同机房实例，降低跨机房延迟：

```java
// ZonePreferenceLoadBalancer.java  同机房优先策略
public class ZonePreferenceLoadBalancer implements ReactorServiceInstanceLoadBalancer {

    private final String localZone;  // 当前服务所在区域，从配置读取
    private final RoundRobinLoadBalancer fallback;  // 无同机房实例时降级轮询
    private final ObjectProvider<ServiceInstanceListSupplier> supplierProvider;

    @Override
    public Mono<Response<ServiceInstance>> choose(Request request) {
        return supplierProvider.getIfAvailable(NoopServiceInstanceListSupplier::new)
            .get(request).next()
            .map(instances -> {
                // 优先过滤同区域实例
                List<ServiceInstance> sameZone = instances.stream()
                    .filter(i -> localZone.equals(i.getMetadata().get("zone")))
                    .collect(Collectors.toList());

                List<ServiceInstance> candidates = sameZone.isEmpty()
                    ? instances   // 无同区域实例则全部参与
                    : sameZone;

                // 在候选列表内轮询
                int idx = ThreadLocalRandom.current().nextInt(candidates.size());
                return new DefaultResponse(candidates.get(idx));
            });
    }
}
```

配置当前服务区域标签（在 Nacos 注册时带上元数据）：

```yaml
spring:
  cloud:
    nacos:
      discovery:
        metadata:
          zone: beijing-zone-a   # 当前实例所在区域
```

---

## 五、踩坑总结

**❌ 坑 1：缓存导致已下线实例仍被路由**

SCL 默认缓存 35 秒，期间下线实例仍会被选中，导致请求失败：

```yaml
# ✅ 缩短缓存 TTL + 开启重试，兼顾性能与可用性
spring:
  cloud:
    loadbalancer:
      cache:
        ttl: 10s          # 缩短到 10 秒
    retry:
      enabled: true
      max-attempts-on-next-service-instance: 2   # 换实例重试 2 次
```

**❌ 坑 2：自定义 LoadBalancer 配置类被 @ComponentScan 扫描**

`@LoadBalancerClient(configuration = Xxx.class)` 指定的配置类**不能**被 `@SpringBootApplication` 的组件扫描到，否则会变成全局配置，覆盖所有服务的策略：

```java
// ✅ 将自定义配置类放在主包扫描路径之外的独立包
// 例如主包是 com.example，配置类放在 com.example.lb.config
// 或使用 @ComponentScan 的 excludeFilters 排除
```

**❌ 坑 3：Spring Boot 3.x 中 Ribbon 自动配置冲突**

从 Spring Boot 2.x 迁移到 3.x 时，如果 classpath 中同时存在 Ribbon 和 SCL 依赖：

```xml
<!-- ✅ 在父 pom 中明确排除 Ribbon -->
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-openfeign</artifactId>
    <exclusions>
        <exclusion>
            <groupId>org.springframework.cloud</groupId>
            <artifactId>spring-cloud-starter-netflix-ribbon</artifactId>
        </exclusion>
    </exclusions>
</dependency>
```

---

## 六、文章小结

- **Spring Cloud LoadBalancer** 是官方推荐的客户端负载均衡器，替代已停止维护的 Ribbon，默认策略为轮询
- 实例列表**本地缓存**（默认 35s TTL）是 SCL 的核心性能优化，代价是短暂可能路由到已下线实例，需配合重试兜底
- 通过实现 `ReactorServiceInstanceLoadBalancer` 接口可自定义策略，常见场景：加权轮询（对接 Nacos 权重）、区域感知（同机房优先）
- 自定义配置类必须放在 `@ComponentScan` 扫描范围外，否则会成为全局策略影响所有服务

## 七、思考题

1. SCL 的实例缓存和 Nacos 客户端的本地缓存是同一份吗？两者的关系是什么？
2. 如果想实现"最少连接数"策略，需要什么信息？在无状态的 HTTP 调用场景中，这个信息从哪里获取？
3. 灰度发布时，如何让打了 `X-Gray: true` Header 的请求，只路由到带有 `gray=true` 元数据的实例？

## 参考资料

- [Spring Cloud LoadBalancer 官方文档](https://docs.spring.io/spring-cloud-commons/reference/spring-cloud-commons/loadbalancer.html)
- [Nacos 实例权重说明](https://nacos.io/zh-cn/docs/v2/guide/user/concepts.html)
- [Spring Cloud 2023.x 发布说明（Ribbon 移除）](https://spring.io/blog/2023/08/30/spring-cloud-2023-0-0-m2-is-available)
