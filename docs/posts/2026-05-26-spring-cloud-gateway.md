# SC-03 Spring Cloud Gateway：路由、过滤器与灰度发布

> 📚 **本文属于「Spring Cloud 微服务实战」系列**
> - [SC-01 Spring Cloud 微服务全景：架构演进与组件选型](2025-06-27-spring-cloud-overview.md)
> - [SC-02 Nacos 服务注册与配置中心实战](2025-02-15-nacos-registry-config.md)
> - 👉 **SC-03 Spring Cloud Gateway：路由、过滤器与灰度发布（本文）**
> - [SC-04 OpenFeign 深度实战：声明式调用、拦截器与熔断](2025-09-06-openfeign-timeout-retry.md)
> - [SC-05 Spring Cloud LoadBalancer：负载均衡原理与自定义策略](2026-05-26-spring-cloud-loadbalancer.md)
> - [SC-06 Sentinel 流量防护：限流、熔断与热点规则](2025-04-26-sentinel-rate-limit.md)
> - [SC-07 分布式链路追踪：Micrometer Tracing + SkyWalking 实战](2026-05-26-spring-cloud-tracing.md)
> - [SC-08 微服务安全：Gateway + JWT 统一鉴权方案](2026-05-26-spring-cloud-security.md)
> - [SC-09 Seata 分布式事务：AT/TCC/Saga 三模式对比实战](2025-01-11-seata-distributed-transaction.md)
> - [SC-10 Nacos 配置治理进阶：多环境、灰度与动态刷新](2026-05-26-nacos-config-advanced.md)
> - [SC-11 微服务可观测性：Actuator + Prometheus + Grafana](2026-05-26-spring-cloud-observability.md)
> - [SC-12 微服务最佳实践：接口幂等、版本兼容与蓝绿部署](2026-05-26-microservice-best-practices.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 25 分钟｜**分类**：微服务

## 导读

Gateway 是微服务集群对外的唯一入口，承担路由转发、认证鉴权、限流熔断、日志记录等横切职责。本文以 Spring Cloud Gateway 3.x（基于 Spring Boot 3.2 + WebFlux）为基础，讲解路由谓词、过滤器链的工作原理，并给出灰度发布的完整落地方案——读完你将能独立搭建一个生产级 API 网关。

---

## 一、为什么需要 API 网关

### 1.1 没有网关时的痛点

微服务拆分后，客户端面临的问题：

```
Client
  |
  |--- HTTP GET /order/123     -> order-service:8081
  |--- HTTP POST /pay          -> payment-service:8082
  |--- HTTP GET /user/profile  -> user-service:8083
  |--- HTTP GET /inventory/sku -> inventory-service:8084
```

- **多地址管理**：客户端需维护所有服务地址，任何服务扩缩容都要通知客户端
- **重复逻辑**：每个服务都要独立实现认证、限流、日志，代码高度重复
- **跨域问题**：多服务多端口，浏览器跨域配置分散
- **安全暴露**：内网服务直接暴露公网，攻击面扩大

API 网关统一收口，解决以上所有问题：

```
Client
  |
  v
+------------------+
|   API Gateway    |  <- 统一鉴权 / 限流 / 路由 / 日志
+--------+---------+
         |
    内网路由
   /      |      \
order  payment  user
```

### 1.2 Spring Cloud Gateway vs Nginx vs Zuul

| 维度 | Spring Cloud Gateway | Nginx | Zuul 1.x |
|------|---------------------|-------|----------|
| 编程模型 | 响应式（WebFlux + Reactor） | 事件驱动（C） | Servlet 阻塞 |
| 动态路由 | ✅ 原生支持（Nacos 动态刷新） | 需 OpenResty/Lua | ✅ |
| 过滤器扩展 | ✅ Java 代码，与 Spring 生态无缝集成 | Lua 脚本 | ✅ Java |
| 性能（RPS） | ~5 万（4 核） | ~10 万（4 核） | ~2 万（4 核） |
| 适用场景 | 微服务 API 网关、动态规则 | 静态资源、高并发反向代理 | 老项目兼容 |

**结论**：Spring Cloud Gateway 适合需要动态配置、与 Java 生态深度集成的微服务场景；Nginx 更适合静态内容和极高并发的纯反向代理场景。

---

## 二、核心架构与工作流程

### 2.1 架构组成

```
Request
  |
  v
+----------------------------------+
|         DispatcherHandler        |  <- WebFlux 核心
+----------------------------------+
  |
  v
+----------------------------------+
|       RoutePredicateHandlerMapping|  <- 路由匹配
|  Route 1: /api/order/** -> lb://order-service
|  Route 2: /api/pay/**   -> lb://payment-service
+----------------------------------+
  |
  v
+----------------------------------+
|     FilteringWebHandler          |  <- 过滤器链执行
|  GlobalFilter: Auth, Log, Trace  |
|  GatewayFilter: StripPrefix, ... |
+----------------------------------+
  |
  v
Upstream Service
```

**三大核心概念**：
- **Route（路由）**：`id` + `uri` + `predicates` + `filters`，是网关的基本转发单元
- **Predicate（断言）**：匹配请求条件（路径、Header、方法、时间、权重等），满足则命中该路由
- **Filter（过滤器）**：在请求转发前后执行逻辑，分 GatewayFilter（路由级）和 GlobalFilter（全局）

### 2.2 请求完整生命周期

```
1. 请求进入 -> RoutePredicateHandlerMapping 遍历所有 Route
2. 按 order 从小到大匹配 Predicate，命中第一个 Route
3. 构建过滤器链：GlobalFilter（排序）+ GatewayFilter
4. pre 过滤器顺序执行（鉴权、限流、日志写入 MDC）
5. 转发到 upstream（通过 NettyRoutingFilter）
6. 收到响应
7. post 过滤器逆序执行（响应日志、Header 改写）
8. 返回给客户端
```

---

## 三、路由配置实战

### 3.1 YAML 配置方式

```yaml
# application.yml  Spring Cloud Gateway 3.1 + Spring Boot 3.2
spring:
  cloud:
    gateway:
      routes:
        # 订单服务路由
        - id: order-service
          uri: lb://order-service          # lb:// 表示走 LoadBalancer 负载均衡
          predicates:
            - Path=/api/order/**           # 路径匹配
            - Method=GET,POST              # HTTP 方法匹配
          filters:
            - StripPrefix=1                # 去掉路径前缀 /api，转发 /order/**
            - name: RequestRateLimiter     # 内置限流过滤器
              args:
                redis-rate-limiter.replenishRate: 100   # 令牌桶速率
                redis-rate-limiter.burstCapacity: 200   # 令牌桶容量
                key-resolver: "#{@ipKeyResolver}"       # 按 IP 限流

        # 用户服务路由（带权重，用于灰度）
        - id: user-service-v1
          uri: lb://user-service
          predicates:
            - Path=/api/user/**
            - Weight=user-group, 90        # 90% 流量走 v1
          filters:
            - StripPrefix=1

        - id: user-service-v2
          uri: lb://user-service-v2
          predicates:
            - Path=/api/user/**
            - Weight=user-group, 10        # 10% 流量走 v2（灰度）
          filters:
            - StripPrefix=1

      # 全局默认过滤器
      default-filters:
        - AddResponseHeader=X-Gateway-Version, 3.1.0
        - DedupeResponseHeader=Access-Control-Allow-Origin
```

### 3.2 Java 代码方式（动态路由推荐）

```java
// RouteConfig.java  JDK 17 + Spring Cloud 2023.x
@Configuration
public class RouteConfig {

    @Bean
    public RouteLocator customRouteLocator(RouteLocatorBuilder builder) {
        return builder.routes()
            // 支付服务路由（带熔断）
            .route("payment-service", r -> r
                .path("/api/pay/**")
                .filters(f -> f
                    .stripPrefix(1)
                    .circuitBreaker(config -> config
                        .setName("payment-cb")
                        .setFallbackUri("forward:/fallback/payment"))  // 熔断降级地址
                    .retry(config -> config
                        .setRetries(2)
                        .setStatuses(HttpStatus.BAD_GATEWAY)))
                .uri("lb://payment-service"))
            .build();
    }

    // 限流 key：按登录用户 ID（未登录按 IP）
    @Bean
    public KeyResolver userKeyResolver() {
        return exchange -> {
            String userId = exchange.getRequest()
                .getHeaders().getFirst("X-User-Id");
            return Mono.just(userId != null ? userId
                : Objects.requireNonNull(exchange.getRequest().getRemoteAddress())
                         .getAddress().getHostAddress());
        };
    }
}
```

### 3.3 常用内置 Predicate 速查

| Predicate | 示例 | 说明 |
|-----------|------|------|
| `Path` | `Path=/api/**` | 路径匹配（支持 AntPath） |
| `Method` | `Method=GET,POST` | HTTP 方法 |
| `Header` | `Header=X-Version, v2` | 请求头匹配（正则） |
| `Query` | `Query=channel, app` | Query 参数匹配 |
| `After` | `After=2026-01-01T00:00:00+08:00[Asia/Shanghai]` | 指定时间后生效 |
| `Weight` | `Weight=group1, 80` | 按权重分流（灰度） |
| `RemoteAddr` | `RemoteAddr=192.168.1.0/24` | 来源 IP 段 |

---

## 四、过滤器开发实战

### 4.1 全局过滤器：请求日志 + TraceId 注入

```java
// GlobalTraceFilter.java  全局过滤器，order 越小越先执行
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class GlobalTraceFilter implements GlobalFilter {

    private static final String TRACE_ID_HEADER = "X-Trace-Id";

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest();

        // 从请求头获取 TraceId（链路追踪透传），若无则生成新的
        String traceId = request.getHeaders().getFirst(TRACE_ID_HEADER);
        if (traceId == null) {
            traceId = UUID.randomUUID().toString().replace("-", "");
        }

        long startTime = System.currentTimeMillis();
        String finalTraceId = traceId;

        // pre 阶段：注入 TraceId 到请求头（透传给下游服务）
        ServerHttpRequest mutatedRequest = request.mutate()
            .header(TRACE_ID_HEADER, finalTraceId)
            .build();

        return chain.filter(exchange.mutate().request(mutatedRequest).build())
            .then(Mono.fromRunnable(() -> {
                // post 阶段：记录响应日志
                long duration = System.currentTimeMillis() - startTime;
                int statusCode = Objects.requireNonNull(
                    exchange.getResponse().getStatusCode()).value();
                log.info("[Gateway] {} {} -> {} | {}ms | traceId={}",
                    request.getMethod(), request.getPath(),
                    statusCode, duration, finalTraceId);
            }));
    }
}
```

### 4.2 全局过滤器：统一鉴权

```java
// AuthGlobalFilter.java  鉴权过滤器，与 SC-08 JWT 方案配合使用
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 20)
public class AuthGlobalFilter implements GlobalFilter {

    // 白名单路径（无需鉴权）
    private static final List<String> WHITE_LIST = List.of(
        "/api/auth/login", "/api/auth/register",
        "/api/public/**", "/actuator/**"
    );

    @Autowired
    private JwtTokenValidator jwtValidator;

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        String path = exchange.getRequest().getPath().value();

        // 白名单放行
        boolean isWhite = WHITE_LIST.stream()
            .anyMatch(pattern -> new AntPathMatcher().match(pattern, path));
        if (isWhite) {
            return chain.filter(exchange);
        }

        // 提取并验证 JWT Token
        String token = exchange.getRequest().getHeaders()
            .getFirst(HttpHeaders.AUTHORIZATION);
        if (token == null || !token.startsWith("Bearer ")) {
            return unauthorized(exchange);
        }

        try {
            Claims claims = jwtValidator.validate(token.substring(7));
            // 将用户信息写入请求头，传递给下游服务
            ServerHttpRequest mutated = exchange.getRequest().mutate()
                .header("X-User-Id", claims.getSubject())
                .header("X-User-Roles", claims.get("roles", String.class))
                .build();
            return chain.filter(exchange.mutate().request(mutated).build());
        } catch (JwtException e) {
            return unauthorized(exchange);
        }
    }

    private Mono<Void> unauthorized(ServerWebExchange exchange) {
        exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
        return exchange.getResponse().setComplete();
    }
}
```

### 4.3 路由级过滤器：自定义请求改写

```java
// RequestSignatureGatewayFilter.java  路由级自定义过滤器工厂
@Component
public class RequestSignatureGatewayFilterFactory
        extends AbstractGatewayFilterFactory<RequestSignatureGatewayFilterFactory.Config> {

    public RequestSignatureGatewayFilterFactory() {
        super(Config.class);
    }

    @Override
    public GatewayFilter apply(Config config) {
        return (exchange, chain) -> {
            // 给下游请求添加内部调用签名，防止绕过网关直接访问
            String timestamp = String.valueOf(System.currentTimeMillis());
            String sign = DigestUtils.md5DigestAsHex(
                (timestamp + config.getSecret()).getBytes());

            ServerHttpRequest mutated = exchange.getRequest().mutate()
                .header("X-Internal-Timestamp", timestamp)
                .header("X-Internal-Sign", sign)
                .build();
            return chain.filter(exchange.mutate().request(mutated).build());
        };
    }

    @Data
    public static class Config {
        private String secret;  // 在 YAML 中配置
    }
}
```

在 YAML 中使用：
```yaml
filters:
  - name: RequestSignature
    args:
      secret: ${gateway.internal.secret}
```

---

## 五、灰度发布方案

### 5.1 基于 Weight Predicate 的流量分割

最简单的灰度：**按比例随机分流**，无法定向。

```yaml
routes:
  - id: order-v1
    uri: lb://order-service
    predicates:
      - Path=/api/order/**
      - Weight=order-group, 90     # 90% -> 稳定版
  - id: order-v2
    uri: lb://order-service-v2
    predicates:
      - Path=/api/order/**
      - Weight=order-group, 10     # 10% -> 灰度版
```

### 5.2 基于 Header 的定向灰度（推荐）

**更精确的灰度**：指定 Header 的用户走新版，其余走旧版。适合 A/B 测试和内测用户。

```yaml
routes:
  # 灰度路由（优先级更高，order 更小）
  - id: order-service-gray
    uri: lb://order-service-v2
    order: 1
    predicates:
      - Path=/api/order/**
      - Header=X-Gray-Version, v2   # Header 中携带 v2 的请求走灰度
    filters:
      - StripPrefix=1

  # 稳定路由
  - id: order-service-stable
    uri: lb://order-service
    order: 2
    predicates:
      - Path=/api/order/**
    filters:
      - StripPrefix=1
```

### 5.3 动态路由（结合 Nacos）

配合 Nacos 实现路由规则热更新，无需重启网关：

```java
// DynamicRouteService.java  监听 Nacos 配置变更，动态更新路由
@Service
public class DynamicRouteService implements ApplicationEventPublisherAware {

    @Autowired
    private RouteDefinitionWriter routeDefinitionWriter;

    private ApplicationEventPublisher publisher;

    // 从 Nacos 接收到新路由配置时调用
    public void updateRoutes(List<RouteDefinition> routes) {
        // 1. 删除旧路由
        routes.forEach(r -> routeDefinitionWriter.delete(Mono.just(r.getId()))
            .onErrorResume(e -> Mono.empty()).subscribe());

        // 2. 写入新路由
        routes.forEach(r -> routeDefinitionWriter.save(Mono.just(r)).subscribe());

        // 3. 发布刷新事件，触发路由重新加载
        publisher.publishEvent(new RefreshRoutesEvent(this));
        log.info("Routes refreshed: {} routes loaded", routes.size());
    }

    @Override
    public void setApplicationEventPublisher(ApplicationEventPublisher publisher) {
        this.publisher = publisher;
    }
}
```

---

## 六、踩坑总结

**❌ 坑 1：`StripPrefix` 与 `RewritePath` 混用导致 404**

`StripPrefix=1` 直接删除路径第一段，`RewritePath` 用正则改写。同时使用时顺序很重要：

```yaml
# ❌ 错误：RewritePath 先执行，StripPrefix 再删，导致路径错误
filters:
  - RewritePath=/api/(?<segment>.*), /$\{segment}
  - StripPrefix=1

# ✅ 正确：只用 RewritePath，不叠加 StripPrefix
filters:
  - RewritePath=/api/(?<segment>.*), /$\{segment}
```

**❌ 坑 2：WebFlux 中不能使用 `ThreadLocal`**

Gateway 基于响应式，同一请求可能在多个线程间切换，`MDC.put()` 和 `ThreadLocal` 会丢失上下文：

```java
// ❌ 错误：MDC 在响应式流中不可靠
MDC.put("traceId", traceId);
return chain.filter(exchange);  // 后续可能切换线程，MDC 丢失

// ✅ 正确：将 TraceId 写入请求头透传，下游服务从 Header 读取
ServerHttpRequest mutated = request.mutate()
    .header("X-Trace-Id", traceId).build();
return chain.filter(exchange.mutate().request(mutated).build());
```

**❌ 坑 3：GlobalFilter 未指定 `@Order` 导致执行顺序混乱**

多个 GlobalFilter 若未指定 `@Order`，执行顺序不确定，可能导致鉴权在日志之后执行：

```java
// ✅ 正确：明确指定优先级
@Order(Ordered.HIGHEST_PRECEDENCE + 10)  // 日志 filter，最先执行
public class GlobalTraceFilter implements GlobalFilter { ... }

@Order(Ordered.HIGHEST_PRECEDENCE + 20)  // 鉴权 filter，日志之后
public class AuthGlobalFilter implements GlobalFilter { ... }
```

**❌ 坑 4：`lb://` 负载均衡依赖 LoadBalancer 依赖未引入**

```xml
<!-- ✅ 必须引入，否则 lb:// 解析失败 -->
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-loadbalancer</artifactId>
</dependency>
```

---

## 七、文章小结

- **Spring Cloud Gateway** 基于 WebFlux 响应式模型，通过 Route → Predicate → Filter 三层抽象统一管理所有入站流量
- **路由配置**支持 YAML 静态配置和 Java 代码动态配置，结合 Nacos 可实现路由规则热更新，无需重启
- **GlobalFilter** 适合鉴权、日志、TraceId 注入等横切逻辑；**GatewayFilter** 适合路由级的请求改写、限流、重试
- **灰度发布**首选 `Header` 定向灰度（可控性强）；`Weight` 适合随机比例分流场景
- 响应式编程中禁止使用 `ThreadLocal`，上下文信息（如 TraceId、用户 ID）应通过请求头透传给下游

## 八、思考题

1. Gateway 使用 WebFlux，如果上游服务是阻塞式 Servlet，性能瓶颈在哪里？应该如何评估？
2. 如何实现基于用户 ID 尾号的定向灰度（尾号 0-4 走 v2，5-9 走 v1）？需要哪些改动？
3. 多个 Gateway 实例部署时，`RequestRateLimiter` 的 Redis 模式下，如何保证限流精度？

## 参考资料

- [Spring Cloud Gateway 官方文档（3.1.x）](https://docs.spring.io/spring-cloud-gateway/reference/)
- [Spring WebFlux 参考指南](https://docs.spring.io/spring-framework/reference/web/webflux.html)
- [Nacos 动态路由最佳实践](https://nacos.io/zh-cn/docs/v2/guide/user/best-practice.html)
