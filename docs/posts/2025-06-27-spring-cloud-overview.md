# SC-01 Spring Cloud 微服务全景：架构演进与组件选型

<div class="post-meta">📅 2025-06-27 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring Cloud</span> <span class="tag">微服务</span></div>

> 📚 **本文属于「Spring Cloud 微服务实战」系列**
> - 👉 **SC-01 Spring Cloud 微服务全景：架构演进与组件选型（本文）**
> - [SC-02 Nacos 服务注册与配置中心实战](posts/2025-02-15-nacos-registry-config.md)
> - [SC-03 Spring Cloud Gateway：路由、过滤器与灰度发布](posts/2026-05-26-spring-cloud-gateway.md)
> - [SC-04 OpenFeign 深度实战：声明式调用、拦截器与熔断](posts/2025-09-06-openfeign-timeout-retry.md)
> - [SC-05 Spring Cloud LoadBalancer：负载均衡原理与自定义策略](posts/2026-05-26-spring-cloud-loadbalancer.md)
> - [SC-06 Sentinel 流量防护：限流、熔断与热点规则](posts/2025-04-26-sentinel-rate-limit.md)
> - [SC-07 分布式链路追踪：Micrometer Tracing + SkyWalking 实战](posts/2026-05-26-spring-cloud-tracing.md)
> - [SC-08 微服务安全：Gateway + JWT 统一鉴权方案](posts/2026-05-26-spring-cloud-security.md)
> - [SC-09 Seata 分布式事务：AT/TCC/Saga 三模式对比实战](posts/2025-01-11-seata-distributed-transaction.md)
> - [SC-10 Nacos 配置治理进阶：多环境、灰度与动态刷新](posts/2026-05-26-nacos-config-advanced.md)
> - [SC-11 微服务可观测性：Actuator + Prometheus + Grafana](posts/2026-05-26-spring-cloud-observability.md)
> - [SC-12 微服务最佳实践：接口幂等、版本兼容与蓝绿部署](posts/2026-05-26-microservice-best-practices.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 20 分钟｜**分类**：微服务

Spring Cloud 是构建微服务架构的核心框架，提供了从服务注册到链路追踪的全套解决方案。本文梳理各核心组件的职责、版本对应关系和最小可用架构，帮助快速建立体系化认知。

---

## 一、微服务架构全景图

```
                      ┌──────────────────────────────────────────────┐
                      │            External Traffic Entry            │
                      │  Browser / Mobile App / Third-party System   │
                      └─────────────────┬────────────────────────────┘
                                        │
                      ┌─────────────────▼────────────────────────────┐
                      │      API Gateway (Spring Cloud Gateway)      │
                      │   Route / Auth / RateLimit / Canary / Log    │
                      └──┬──────────┬──────────┬──────────┬──────────┘
                         │          │          │          │
              ┌──────────▼──┐  ┌────▼─────┐  ┌▼────────┐ ┌▼──────────┐
              │ User-Svc    │  │Order-Svc │  │ Inv-Svc │ │ Pay-Svc   │
              │ :8001       │  │ :8002    │  │ :8003   │ │ :8004     │
              └──────┬──────┘  └────┬─────┘  └────┬────┘ └─────┬─────┘
                     │              │              │             │
                     └──────────────┴──────────────┴─────────────┘
                                         │
                     ┌───────────────────┼───────────────────────┐
                     │                   │                        │
          ┌──────────▼──────┐  ┌─────────▼────────┐  ┌──────────▼──────┐
          │  Registry       │  │  Config Center    │  │  Dist-TX        │
          │  Nacos          │  │  Nacos Config     │  │  Seata          │
          └─────────────────┘  └──────────────────┘  └─────────────────┘

          ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐
          │  RPC Client     │  │  Circuit Breaker  │  │  Tracing        │
          │  OpenFeign      │  │  Sentinel         │  │  SkyWalking     │
          └─────────────────┘  └──────────────────┘  └─────────────────┘
```

> **组件说明**：外部流量（浏览器/移动端/第三方）→ API Gateway 路由分发 → 用户/订单/库存/支付微服务；底层支撑：注册中心（Nacos）、配置中心（Nacos Config）、分布式事务（Seata）；横切关注点：RPC 调用（OpenFeign）、熔断限流（Sentinel）、链路追踪（SkyWalking）。

---

## 二、核心组件职责详解

### 2.1 Spring Cloud Gateway（API 网关）

```
职责：统一入口 + 横切关注点处理

核心功能：
├── 路由转发：根据 Path/Host/Header 路由到对应服务
├── 负载均衡：集成 LoadBalancer，自动发现服务实例
├── 鉴权认证：JWT 验证、OAuth2 集成
├── 限流：集成 Sentinel 或内置 Redis 令牌桶
├── 灰度发布：按权重/Header 路由到新版本
├── 日志审计：统一请求/响应日志
└── 跨域处理：统一 CORS 配置
```

### 2.2 Nacos（注册中心 + 配置中心）

```
职责：服务发现 + 动态配置

注册中心功能：
├── 服务注册：服务启动时注册实例（IP:Port + 元数据）
├── 服务发现：客户端订阅服务列表，获取可用实例
├── 健康检查：心跳检测（默认5s），剔除不健康实例
└── 临时/持久实例：AP（临时）vs CP（持久）

配置中心功能：
├── 集中配置：DataId + Group + Namespace 三级隔离
├── 动态刷新：配置变更推送，@RefreshScope 自动刷新
└── 灰度配置：按标签推送不同配置
```

### 2.3 Sentinel（熔断 + 限流 + 降级）

```
职责：流量防护

三种规则：
├── 流控规则（FlowRule）：QPS 或并发线程数限制
├── 降级规则（DegradeRule）：慢调用/异常比例/异常数熔断
└── 系统规则（SystemRule）：系统 CPU/负载保护

保护对象：
├── 接口（URL）：@SentinelResource 或过滤器自动识别
├── 服务调用：Feign 集成
└── 消息消费：MQ 消费限流
```

### 2.4 OpenFeign（声明式 HTTP 客户端）

```
职责：服务间 RPC 调用

核心特性：
├── 声明式接口：@FeignClient + 接口方法
├── 负载均衡：集成 LoadBalancer（轮询/随机）
├── 熔断降级：集成 Sentinel/Resilience4j
├── 超时重试：可配置超时时间和重试策略
└── 拦截器：请求头透传（Token/TraceId）
```

### 2.5 Seata（分布式事务）

```
职责：跨服务数据一致性

支持模式：
├── AT 模式：自动补偿（最常用，侵入性低）
├── TCC 模式：Try-Confirm-Cancel（侵入性高，性能好）
├── Saga 模式：长事务（复杂业务流程）
└── XA 模式：基于 XA 协议（强一致，性能差）
```

---

## 三、版本对应关系

| Spring Boot | Spring Cloud | Spring Cloud Alibaba | Nacos | Sentinel | Seata |
|------------|--------------|---------------------|-------|----------|-------|
| 3.2.x | 2023.0.x | 2023.0.x | 2.3.x | 1.8.x | 2.0.x |
| 3.1.x | 2022.0.x | 2022.0.x | 2.2.x | 1.8.x | 1.7.x |
| 2.7.x | 2021.0.x | 2021.0.x | 2.0.x | 1.8.x | 1.6.x |
| 2.6.x | 2021.0.x | 2021.0.x | 2.0.x | 1.8.x | 1.5.x |
| 2.3.x | Hoxton | 2.2.x | 1.4.x | 1.7.x | 1.3.x |

> 选型原则：优先选择同一大版本（如都用 2023.0.x），避免兼容性问题。

---

## 四、各代际组件对比

| 功能 | 第一代（Netflix OSS）| 第二代（Spring Cloud Alibaba）| 说明 |
|------|---------------------|------------------------------|------|
| 注册中心 | Eureka | Nacos | Eureka 已停止维护 |
| 配置中心 | Config + Bus | Nacos Config | Nacos 更易用 |
| 网关 | Zuul | Spring Cloud Gateway | Zuul 基于 Servlet，Gateway 基于 Netty |
| 熔断 | Hystrix | Sentinel / Resilience4j | Hystrix 已停止维护 |
| 服务调用 | Ribbon + Feign | OpenFeign + LoadBalancer | Ribbon 已弃用 |
| 分布式事务 | 无 | Seata | Spring Cloud Alibaba 特有 |
| 链路追踪 | Sleuth + Zipkin | SkyWalking / Micrometer | Sleuth 已在 3.x 移除 |

---

## 五、最小可用微服务架构（Spring Boot 3.x）

### 5.1 依赖配置

```xml
<!-- pom.xml -->
<properties>
    <java.version>17</java.version>
    <spring-boot.version>3.2.5</spring-boot.version>
    <spring-cloud.version>2023.0.1</spring-cloud.version>
    <spring-cloud-alibaba.version>2023.0.1.0</spring-cloud-alibaba.version>
</properties>

<dependencyManagement>
    <dependencies>
        <!-- Spring Boot BOM -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-dependencies</artifactId>
            <version>${spring-boot.version}</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
        <!-- Spring Cloud BOM -->
        <dependency>
            <groupId>org.springframework.cloud</groupId>
            <artifactId>spring-cloud-dependencies</artifactId>
            <version>${spring-cloud.version}</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
        <!-- Spring Cloud Alibaba BOM -->
        <dependency>
            <groupId>com.alibaba.cloud</groupId>
            <artifactId>spring-cloud-alibaba-dependencies</artifactId>
            <version>${spring-cloud-alibaba.version}</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>

<dependencies>
    <!-- 核心：Nacos 服务注册发现 -->
    <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
    </dependency>
    <!-- 核心：Nacos 配置中心 -->
    <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-starter-alibaba-nacos-config</artifactId>
    </dependency>
    <!-- 核心：OpenFeign -->
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-starter-openfeign</artifactId>
    </dependency>
    <!-- 核心：负载均衡 -->
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-starter-loadbalancer</artifactId>
    </dependency>
    <!-- 网关（仅 gateway 服务需要）-->
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-starter-gateway</artifactId>
    </dependency>
    <!-- Sentinel 限流熔断 -->
    <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-starter-alibaba-sentinel</artifactId>
    </dependency>
</dependencies>
```

### 5.2 微服务公共配置（bootstrap.yml）

```yaml
spring:
  application:
    name: order-service
  cloud:
    nacos:
      # 注册中心
      discovery:
        server-addr: localhost:8848
        namespace: dev
        group: DEFAULT_GROUP
      # 配置中心
      config:
        server-addr: localhost:8848
        namespace: dev
        group: DEFAULT_GROUP
        file-extension: yaml
        # 共享配置（多服务公共）
        shared-configs:
          - data-id: common.yaml
            group: DEFAULT_GROUP
            refresh: true
    # Sentinel 控制台
    sentinel:
      transport:
        dashboard: localhost:8080
        port: 8719

server:
  port: 8002

feign:
  sentinel:
    enabled: true  # Feign 集成 Sentinel
  client:
    config:
      default:
        connect-timeout: 5000
        read-timeout: 10000
```

### 5.3 网关配置

```yaml
# gateway 服务的 application.yml
spring:
  cloud:
    gateway:
      routes:
        # 用户服务路由
        - id: user-service
          uri: lb://user-service        # lb:// 表示负载均衡
          predicates:
            - Path=/api/user/**
          filters:
            - StripPrefix=1             # 去掉 /api 前缀
            - name: RequestRateLimiter  # 限流过滤器
              args:
                redis-rate-limiter.replenishRate: 100
                redis-rate-limiter.burstCapacity: 200
        # 订单服务路由
        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/api/order/**
          filters:
            - StripPrefix=1
      # 全局跨域配置
      globalcors:
        cors-configurations:
          '[/**]':
            allowed-origins: "*"
            allowed-methods: "*"
            allowed-headers: "*"
```

---

## 六、服务间调用示例

```java
// 订单服务调用用户服务
@FeignClient(
    name = "user-service",           // 服务名（Nacos 中注册的名称）
    fallback = UserFeignFallback.class  // 降级实现
)
public interface UserFeignClient {
    
    @GetMapping("/user/{userId}")
    UserDTO getUserById(@PathVariable("userId") Long userId);
    
    @PostMapping("/user/batch")
    List<UserDTO> getUsersByIds(@RequestBody List<Long> userIds);
}

// 降级实现
@Component
public class UserFeignFallback implements UserFeignClient {
    
    @Override
    public UserDTO getUserById(Long userId) {
        log.warn("用户服务不可用，返回降级数据，userId={}", userId);
        return UserDTO.empty(userId); // 返回默认值
    }
    
    @Override
    public List<UserDTO> getUsersByIds(List<Long> userIds) {
        return Collections.emptyList();
    }
}
```

---

## 七、微服务设计原则

| 原则 | 说明 | 反例 |
|------|------|------|
| 单一职责 | 每个服务只负责一个业务域 | 用户+订单+商品放在一个服务 |
| 松耦合 | 服务间通过接口交互，不共享数据库 | 多个服务操作同一张表 |
| 高内聚 | 相关功能放在同一服务 | 用户注册和用户支付分两个服务 |
| 独立部署 | 每个服务独立打包部署 | 多个服务共用一个 JAR |
| 故障隔离 | 单服务故障不影响整体 | 无熔断降级，级联故障 |

---

## 八、总结与延伸

**核心要点**：
1. Spring Cloud Alibaba 技术栈已成国内微服务首选：**Nacos（注册+配置）+ Gateway（网关）+ Sentinel（熔断限流）+ OpenFeign（服务调用）+ Seata（分布式事务）**
2. 组件版本必须对齐，推荐通过 `spring-cloud-alibaba-dependencies` BOM 统一管理，避免手动指定版本导致的兼容问题
3. 微服务的复杂度不仅在代码，更在**服务治理**：注册发现、配置管理、熔断降级、链路追踪缺一不可
4. 拆分粒度的黄金原则：**单一职责 + 独立部署 + 不共享数据库**；过度拆分（纳米服务）会显著增加运维负担和网络开销

**延伸阅读**：
- [Spring Cloud Alibaba GitHub](https://github.com/alibaba/spring-cloud-alibaba) — 版本兼容表与最新特性
- [微服务架构设计模式](https://microservices.io/patterns/index.html) — Chris Richardson 著，服务治理最佳实践
- [Nacos 注册与配置中心](./2025-02-15-nacos-registry-config.md) — 注册发现与动态配置详解
- [Sentinel 限流熔断](./2025-04-26-sentinel-rate-limit.md) — 流控与熔断规则深度实践
- [OpenFeign 超时重试](./2025-09-06-openfeign-timeout-retry.md) — 服务间调用的可靠性保障
