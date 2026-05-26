# SC-12 微服务最佳实践：接口幂等、版本兼容与蓝绿部署

> 📚 **本文属于「Spring Cloud 微服务实战」系列**
> - [SC-01 Spring Cloud 微服务全景：架构演进与组件选型](posts/2025-06-27-spring-cloud-overview.md)
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
> - 👉 **SC-12 微服务最佳实践：接口幂等、版本兼容与蓝绿部署（本文）**

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 25 分钟｜**分类**：微服务

## 导读

走完前 11 篇，你已掌握 Spring Cloud 各组件的用法。本文聚焦三个高频工程问题：网络重试导致接口重复执行怎么防（幂等）、新旧版本 API 不兼容怎么过渡（版本兼容），以及如何零停机发布（蓝绿/金丝雀部署）。这些问题在面试和生产中都绕不开。

---

## 一、接口幂等性设计

### 1.1 为什么需要幂等

微服务中触发重复请求的场景：
- **客户端重试**：OpenFeign/Retry 策略，网络抖动后自动重试
- **消息队列重消费**：Kafka 或 RocketMQ 至少一次投递语义
- **前端重复提交**：用户快速双击"下单"按钮
- **超时重试**：支付回调超时，支付平台会重发通知

对于**写操作**（创建订单、扣库存、转账），重复执行会产生脏数据；对于**读操作**，天然幂等，无需处理。

### 1.2 Token 防重方案（适合前端提交）

```
前端请求令牌                  后端颁发 Token
GET /api/idempotent/token  ->  生成 UUID 存 Redis，返回给前端
                               key: idempotent:{token}，TTL 5 分钟

前端提交表单                  后端消费 Token
POST /api/order/create     ->  1. 从 Header 读取 X-Idempotent-Token
  Header: X-Idempotent-Token: abc-123
                               2. Redis SETNX idempotent:abc-123 "processing"
                               3. 存在 -> 返回"请勿重复提交"
                               4. 不存在 -> 执行业务，完成后更新为"done"
```

```java
// IdempotentAspect.java  通过 AOP 统一处理幂等
@Aspect
@Component
public class IdempotentAspect {

    @Autowired
    private StringRedisTemplate redisTemplate;

    @Around("@annotation(idempotent)")
    public Object around(ProceedingJoinPoint joinPoint,
            Idempotent idempotent) throws Throwable {
        HttpServletRequest request = ((ServletRequestAttributes)
            RequestContextHolder.getRequestAttributes()).getRequest();

        String token = request.getHeader("X-Idempotent-Token");
        if (token == null || token.isBlank()) {
            throw new BusinessException("幂等 Token 不能为空");
        }

        String key = "idempotent:" + token;

        // 使用 SETNX 原子操作，保证并发安全
        Boolean isFirstCall = redisTemplate.opsForValue()
            .setIfAbsent(key, "processing", 5, TimeUnit.MINUTES);

        if (Boolean.FALSE.equals(isFirstCall)) {
            // Token 已存在，判断是否已处理完成
            String status = redisTemplate.opsForValue().get(key);
            if ("done".equals(status)) {
                // 可选：返回缓存的处理结果（需要序列化存储）
                throw new BusinessException("请勿重复提交");
            }
            throw new BusinessException("请求处理中，请稍后再试");
        }

        try {
            Object result = joinPoint.proceed();
            // 业务执行成功，标记 Token 为已完成
            redisTemplate.opsForValue().set(key, "done",
                idempotent.expireMinutes(), TimeUnit.MINUTES);
            return result;
        } catch (Throwable e) {
            // 业务执行失败，删除 Token 允许重试
            redisTemplate.delete(key);
            throw e;
        }
    }
}

// 自定义注解
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface Idempotent {
    int expireMinutes() default 5;
}
```

使用：

```java
// OrderController.java
@PostMapping("/create")
@Idempotent(expireMinutes = 10)
public ResponseEntity<Order> createOrder(@RequestBody OrderRequest request) {
    return ResponseEntity.ok(orderService.create(request));
}
```

### 1.3 数据库唯一索引兜底

Token 方案是前置拦截，数据库唯一索引是最后的保障：

```sql
-- 订单表加唯一约束
ALTER TABLE orders ADD UNIQUE INDEX uk_order_no (order_no);

-- 业务逻辑中捕获唯一键冲突
```

```java
try {
    orderRepository.save(order);
} catch (DataIntegrityViolationException e) {
    // 唯一键冲突 = 重复提交，返回已存在的订单
    return orderRepository.findByOrderNo(order.getOrderNo())
        .orElseThrow();
}
```

---

## 二、API 版本兼容

### 2.1 三种版本管理策略

| 策略 | 示例 | 优点 | 缺点 |
|------|------|------|------|
| **URL 路径版本** | `/api/v1/orders` | 直观、易缓存 | URL 膨胀，旧版本路由难清理 |
| **Header 版本** | `Accept-Version: v2` | URL 整洁 | 不易测试，不支持浏览器直接访问 |
| **Media Type** | `Accept: application/vnd.api.v2+json` | 语义最规范 | 使用复杂，客户端实现成本高 |

Spring Cloud 场景下推荐 **URL 路径版本**，原因是 Gateway 路由和 Nacos 服务发现都能直接按路径区分版本。

### 2.2 向后兼容原则（必须遵守）

```
✅ 可以做：
  - 新增字段（旧客户端会忽略）
  - 新增可选参数（有默认值）
  - 新增接口端点

❌ 不能做（需要升版本号）：
  - 删除或重命名已有字段
  - 修改字段类型（String -> Integer）
  - 修改已有参数的语义
  - 修改 HTTP 状态码含义
```

### 2.3 API 版本路由（Gateway 配置）

```yaml
# gateway application.yml  通过路由规则隔离 v1/v2 流量
spring:
  cloud:
    gateway:
      routes:
        # v2 路由（新版本，优先匹配）
        - id: order-service-v2
          uri: lb://order-service-v2
          predicates:
            - Path=/api/v2/order/**
          filters:
            - RewritePath=/api/v2/order/(?<segment>.*), /order/$\{segment}

        # v1 路由（旧版本，兼容期保留）
        - id: order-service-v1
          uri: lb://order-service
          predicates:
            - Path=/api/v1/order/**
          filters:
            - RewritePath=/api/v1/order/(?<segment>.*), /order/$\{segment}
```

### 2.4 代码层面的版本控制器

```java
// 同一个 Controller 支持两个版本（字段兼容时）
@RestController
public class OrderController {

    // v1：返回旧格式
    @GetMapping("/api/v1/order/{id}")
    public OrderV1Response getOrderV1(@PathVariable String id) {
        Order order = orderService.getById(id);
        return OrderV1Response.from(order);  // 只包含 v1 字段
    }

    // v2：返回新格式（增加了 trackingInfo 字段）
    @GetMapping("/api/v2/order/{id}")
    public OrderV2Response getOrderV2(@PathVariable String id) {
        Order order = orderService.getById(id);
        return OrderV2Response.from(order);  // 包含 v1 + v2 新增字段
    }
}
```

---

## 三、发布策略：蓝绿与金丝雀

### 3.1 蓝绿部署

```
当前状态：
  负载均衡 -> [Blue 环境 v1.0] (100% 流量)
  [Green 环境 v2.0]             (空跑，等待发布)

发布步骤：
  1. 部署 Green 环境（v2.0），完成自动化测试
  2. 切换负载均衡：Blue v1.0 -> Green v2.0（瞬时切换，0 停机）
  3. 观察 Green 环境 15~30 分钟（监控告警）
  4. 确认正常后，Blue 环境保留（回滚备用）或下线

回滚：
  切换负载均衡 Green -> Blue（秒级回滚）
```

**在 Spring Cloud + K8s 中实现**：

```yaml
# k8s-service.yaml  通过修改 Service selector 切换流量
apiVersion: v1
kind: Service
metadata:
  name: order-service
spec:
  selector:
    app: order-service
    version: blue    # 切换时改为 green

---
# Blue Deployment（v1.0）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service-blue
spec:
  replicas: 3
  template:
    metadata:
      labels:
        app: order-service
        version: blue
    spec:
      containers:
        - name: order-service
          image: order-service:1.0.0

---
# Green Deployment（v2.0）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service-green
spec:
  replicas: 3
  template:
    metadata:
      labels:
        app: order-service
        version: green
    spec:
      containers:
        - name: order-service
          image: order-service:2.0.0
```

### 3.2 金丝雀发布（渐进式）

蓝绿是"全切"，金丝雀是"渐进切"：先切 5% 流量观察，无问题再逐步增加。

```yaml
# Gateway 权重路由实现金丝雀（结合 SC-03 的 Weight Predicate）
routes:
  - id: order-canary
    uri: lb://order-service-v2
    predicates:
      - Path=/api/order/**
      - Weight=order-group, 5       # 5% 流量给新版本

  - id: order-stable
    uri: lb://order-service
    predicates:
      - Path=/api/order/**
      - Weight=order-group, 95      # 95% 流量给旧版本
```

金丝雀发布节奏（以订单服务为例）：

| 阶段 | 金丝雀流量 | 观察时间 | 关注指标 |
|------|-----------|---------|---------|
| 第一波 | 5% | 30 分钟 | 错误率、P99 延迟 |
| 第二波 | 20% | 1 小时 | 同上 + 业务成功率 |
| 第三波 | 50% | 2 小时 | 同上 + 数据库负载 |
| 全量 | 100% | — | 完成发布 |

---

## 四、踩坑总结

**❌ 坑 1：幂等 Token 在业务失败时未删除，导致无法重试**

```java
// ❌ 错误：Token 在业务异常时仍标记为"处理中"，用户无法重试
Boolean set = redis.setIfAbsent(key, "processing", 5, MINUTES);
if (set) {
    processOrder();  // 抛出异常后，key 仍存在，下次请求被拦截
}

// ✅ 正确：业务异常时删除 Token，让用户重试；业务成功才标记完成
try {
    processOrder();
    redis.opsForValue().set(key, "done", 10, MINUTES);
} catch (BusinessException e) {
    redis.delete(key);  // 业务失败，允许重试
    throw e;
}
```

**❌ 坑 2：蓝绿切换时未等待旧版本连接排空**

流量切换后，旧版本仍有正在处理的请求，立即强杀会导致请求中断：

```yaml
# k8s Deployment 配置优雅停机
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 60   # 给旧实例 60 秒完成在途请求
      containers:
        - lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]  # 等 LB 摘流完成
```

**❌ 坑 3：API 版本号只增不减，版本爆炸**

```
# ✅ 制定版本生命周期策略：
# - 新版本发布后，旧版本进入 Deprecated 状态，通知客户端迁移
# - 旧版本 Deprecated 3 个月后下线（需在 API 文档和 Header 中声明）
response.addHeader("Deprecation", "version=v1; sunset=2027-01-01");
response.addHeader("Sunset", "Sat, 01 Jan 2027 00:00:00 GMT");
```

---

## 五、文章小结

- **接口幂等**：前置用 Token + Redis SETNX 拦截重复请求，后置用数据库唯一索引兜底；业务失败时必须删除 Token 允许重试
- **API 版本兼容**：遵守只增不删原则，新版本走新路径（`/v2/`）；Gateway 按路径路由不同版本的服务实例
- **蓝绿部署**实现瞬时切换和秒级回滚，适合风险敏感的核心服务；**金丝雀发布**渐进放量，适合需要小范围验证的场景
- 发布前必须确认优雅停机配置，防止流量切换时旧实例被强杀导致请求中断

## 六、思考题

1. 幂等 Token 方案在分布式场景下（多个 Gateway 实例）能保证幂等吗？Redis SETNX 在这里起什么作用？
2. 蓝绿部署中，如果 Green 环境涉及数据库 Schema 变更（新增列），如何保证 Blue 和 Green 同时运行时数据兼容？
3. 金丝雀发布过程中，如果新版本引入了 Breaking Change（如修改了某个字段类型），5% 的用户报错后如何快速回滚且不影响剩余 95% 的用户？

## 参考资料

- [Idempotency 设计模式（Martin Fowler）](https://martinfowler.com/articles/patterns-of-distributed-systems/idempotent-receiver.html)
- [API 版本化最佳实践（Stripe API 设计）](https://stripe.com/docs/api/versioning)
- [Kubernetes 蓝绿部署指南](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy)
- [Google SRE Book - Release Engineering](https://sre.google/sre-book/release-engineering/)
