# Sentinel 限流降级熔断实战

<div class="post-meta">📅 2025-04-26 &nbsp;·&nbsp; 🏷️ <span class="tag">Sentinel</span> <span class="tag">微服务</span></div>

Sentinel 是阿里巴巴开源的流量防控组件，从流量控制、熔断降级到系统自适应保护，全面保障微服务稳定性。本文详解三种规则配置、@SentinelResource 注解用法，以及将规则持久化到 Nacos 的完整方案。

---

## 一、Sentinel 核心概念

```
资源（Resource）：需要保护的代码块（接口/方法/SQL/外部调用）
规则（Rule）：作用在资源上的保护策略
                    
                         ┌─────────────────────────────────┐
                         │          Sentinel 核心           │
   请求 ──────────────→  │                                  │ ──→ 资源执行
                         │  流控规则  降级规则  系统规则      │
                         │     ↓          ↓         ↓       │
                         │  BlockException（被拒绝）         │
                         └─────────────────────────────────┘
```

---

## 二、快速集成

### 2.1 依赖引入

```xml
<!-- pom.xml -->
<!-- Spring Cloud Alibaba Sentinel -->
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-sentinel</artifactId>
</dependency>
<!-- Sentinel Datasource Nacos（规则持久化）-->
<dependency>
    <groupId>com.alibaba.csp</groupId>
    <artifactId>sentinel-datasource-nacos</artifactId>
</dependency>
```

### 2.2 基础配置

```yaml
# application.yml
spring:
  cloud:
    sentinel:
      transport:
        dashboard: localhost:8080    # Sentinel 控制台地址
        port: 8719                  # 本地与控制台通信端口
      eager: true                   # 饥饿加载（启动即连接控制台）
      # 规则持久化到 Nacos
      datasource:
        flow:                       # 流控规则数据源名称
          nacos:
            server-addr: localhost:8848
            namespace: dev
            data-id: ${spring.application.name}-sentinel-flow
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: flow         # 规则类型
        degrade:                    # 降级规则
          nacos:
            server-addr: localhost:8848
            namespace: dev
            data-id: ${spring.application.name}-sentinel-degrade
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: degrade

# 接口限流日志
feign:
  sentinel:
    enabled: true
```

---

## 三、流控规则（FlowRule）

### 3.1 QPS 限流

```java
/**
 * 编程方式设置流控规则
 */
@PostConstruct
public void initFlowRules() {
    List<FlowRule> rules = new ArrayList<>();
    
    FlowRule rule = new FlowRule();
    rule.setResource("queryUser");     // 资源名
    rule.setGrade(RuleConstant.FLOW_GRADE_QPS);  // 限流类型：QPS
    rule.setCount(100);                // 阈值：100 QPS
    rule.setStrategy(RuleConstant.STRATEGY_DIRECT); // 流控模式：直接
    rule.setControlBehavior(RuleConstant.CONTROL_BEHAVIOR_DEFAULT); // 快速失败
    
    rules.add(rule);
    FlowRuleManager.loadRules(rules);
}
```

### 3.2 并发线程数限流

```java
FlowRule threadRule = new FlowRule();
threadRule.setResource("callSlowService");
threadRule.setGrade(RuleConstant.FLOW_GRADE_THREAD); // 并发线程数
threadRule.setCount(10);  // 最多 10 个线程同时执行
```

### 3.3 三种流控模式

| 模式 | 说明 | 场景 |
|------|------|------|
| 直接（Direct）| 资源本身触发限流 | 通用场景 |
| 关联（Relate）| 关联资源达到阈值时，限流当前资源 | 写接口限流保护读接口 |
| 链路（Chain）| 仅统计指定调用链上的流量 | 按来源区分限流 |

### 3.4 四种流控效果

| 效果 | 说明 | 适用场景 |
|------|------|---------|
| 快速失败 | 超过阈值直接抛异常 | 大多数接口 |
| Warm Up | 预热启动（冷启动保护）| 刚启动的服务 |
| 排队等待 | 匀速排队（漏桶算法）| 消息处理、批量任务 |
| Warm Up + 排队 | 预热 + 排队组合 | 复杂场景 |

```java
// Warm Up 配置（冷启动：10s 内从 阈值/3 逐渐升到阈值）
FlowRule warmUpRule = new FlowRule("hotApi");
warmUpRule.setGrade(RuleConstant.FLOW_GRADE_QPS);
warmUpRule.setCount(100);
warmUpRule.setControlBehavior(RuleConstant.CONTROL_BEHAVIOR_WARM_UP);
warmUpRule.setWarmUpPeriodSec(10); // 预热时间10s

// 排队等待（匀速）
FlowRule queueRule = new FlowRule("messageConsumer");
queueRule.setGrade(RuleConstant.FLOW_GRADE_QPS);
queueRule.setCount(10); // 每秒10个，匀速处理
queueRule.setControlBehavior(RuleConstant.CONTROL_BEHAVIOR_RATE_LIMITER);
queueRule.setMaxQueueingTimeMs(2000); // 最长等待2s，超过则拒绝
```

---

## 四、降级规则（DegradeRule）

### 4.1 三种熔断策略

| 策略 | 触发条件 | 说明 |
|------|---------|------|
| 慢调用比例 | 慢调用比例超过阈值 | 响应时间超过 RT 的请求占比 |
| 异常比例 | 异常比例超过阈值 | 异常请求占总请求的比例 |
| 异常数 | 异常数超过阈值 | 滑动窗口内异常总数 |

```java
@PostConstruct
public void initDegradeRules() {
    List<DegradeRule> rules = new ArrayList<>();
    
    // 策略1：慢调用比例熔断
    DegradeRule slowRule = new DegradeRule("callThirdPartyApi");
    slowRule.setGrade(CircuitBreakerStrategy.SLOW_REQUEST_RATIO.getType());
    slowRule.setCount(1.0);       // RT 阈值：1000ms（响应>1s算慢调用）
    slowRule.setSlowRatioThreshold(0.5); // 慢调用比例 > 50% 触发熔断
    slowRule.setMinRequestAmount(5);     // 最少5个请求才统计
    slowRule.setStatIntervalMs(10000);   // 统计窗口：10s
    slowRule.setTimeWindow(10);          // 熔断持续时间：10s（后进入半开状态）
    rules.add(slowRule);
    
    // 策略2：异常比例熔断
    DegradeRule exceptionRatioRule = new DegradeRule("callPaymentService");
    exceptionRatioRule.setGrade(CircuitBreakerStrategy.ERROR_RATIO.getType());
    exceptionRatioRule.setCount(0.5);    // 异常比例 > 50%
    exceptionRatioRule.setMinRequestAmount(10);
    exceptionRatioRule.setTimeWindow(60);
    rules.add(exceptionRatioRule);
    
    // 策略3：异常数熔断
    DegradeRule exceptionCountRule = new DegradeRule("queryInventory");
    exceptionCountRule.setGrade(CircuitBreakerStrategy.ERROR_COUNT.getType());
    exceptionCountRule.setCount(5);      // 异常数 > 5
    exceptionCountRule.setTimeWindow(30);
    rules.add(exceptionCountRule);
    
    DegradeRuleManager.loadRules(rules);
}
```

### 4.2 熔断状态机

```
         正常请求通过
  CLOSED ──────────────────────────→ CLOSED
    │                                    ↑
    │ 触发熔断阈值                        │ 探测请求成功
    ↓                                    │
  OPEN  ──── 熔断时间窗口到期 ──→ HALF_OPEN
    │         （拒绝所有请求）       │
    │                               │ 探测请求失败
    └───────────────────────────────┘
                                    重置为 OPEN，延长时间窗口
```

---

## 五、系统规则（SystemRule）

```java
/**
 * 系统自适应保护：当系统整体指标超过阈值时，拒绝流量入口
 */
@PostConstruct
public void initSystemRules() {
    List<SystemRule> rules = new ArrayList<>();
    SystemRule rule = new SystemRule();
    
    // 以下条件任一满足即触发保护（-1 表示不限制）
    rule.setHighestSystemLoad(3.0);   // 系统 Load（load1）> 3
    rule.setAvgRt(500);               // 平均响应时间 > 500ms
    rule.setQps(10000);               // 入口 QPS > 10000
    rule.setMaxThread(800);           // 并发线程数 > 800
    rule.setHighestCpuUsage(0.9);     // CPU 使用率 > 90%
    
    rules.add(rule);
    SystemRuleManager.loadRules(rules);
}
```

| 指标 | 建议阈值 | 说明 |
|------|---------|------|
| System Load | CPU核数 * 2.5 | Linux `uptime` 的 load1 |
| CPU 使用率 | 0.8 | 0~1 范围 |
| 平均 RT | 根据业务 | 所有接口平均响应时间 |
| 入口 QPS | 压测得出 | 系统最大处理能力 |

---

## 六、@SentinelResource 注解

```java
@RestController
@RequestMapping("/order")
public class OrderController {
    
    @Autowired
    private OrderService orderService;
    
    /**
     * @SentinelResource 注解：声明资源并指定处理方法
     *
     * value：资源名
     * blockHandler：限流/降级时调用的处理方法（BlockException）
     * fallback：业务异常时调用的降级方法（非 BlockException）
     * exceptionsToIgnore：忽略哪些异常（不触发 fallback）
     */
    @GetMapping("/{orderId}")
    @SentinelResource(
        value = "getOrder",
        blockHandler = "handleBlock",          // 必须在同一类中
        blockHandlerClass = OrderBlockHandler.class, // 或指定类
        fallback = "handleFallback",
        exceptionsToIgnore = {IllegalArgumentException.class}
    )
    public OrderDTO getOrder(@PathVariable Long orderId) {
        return orderService.findById(orderId);
    }
    
    /**
     * BlockHandler：限流/降级时调用
     * 方法签名：必须与原方法参数一致，末尾加 BlockException
     * 返回类型：必须与原方法相同
     */
    public OrderDTO handleBlock(Long orderId, BlockException ex) {
        log.warn("订单查询被限流，orderId={}, rule={}", orderId, ex.getRule());
        return OrderDTO.limited(); // 返回限流提示
    }
    
    /**
     * Fallback：业务异常时调用
     * 方法签名：可以有 Throwable 参数
     */
    public OrderDTO handleFallback(Long orderId, Throwable t) {
        log.error("订单查询异常降级，orderId={}", orderId, t);
        return OrderDTO.empty(); // 返回默认空对象
    }
}

/**
 * 将 BlockHandler 抽取到独立类（避免污染业务类）
 * 注意：方法必须是 public static
 */
public class OrderBlockHandler {
    
    public static OrderDTO handleBlock(Long orderId, BlockException ex) {
        if (ex instanceof FlowException) {
            return OrderDTO.rateLimited();
        } else if (ex instanceof DegradeException) {
            return OrderDTO.degraded();
        }
        return OrderDTO.limited();
    }
}
```

---

## 七、规则持久化到 Nacos

### 7.1 Nacos 中的流控规则格式

在 Nacos 控制台创建配置：
- DataId：`order-service-sentinel-flow`
- Group：`SENTINEL_GROUP`
- 内容：

```json
[
  {
    "resource": "getOrder",
    "limitApp": "default",
    "grade": 1,
    "count": 100,
    "strategy": 0,
    "controlBehavior": 0,
    "clusterMode": false
  },
  {
    "resource": "createOrder",
    "limitApp": "default",
    "grade": 1,
    "count": 50,
    "strategy": 0,
    "controlBehavior": 0,
    "clusterMode": false
  }
]
```

### 7.2 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| resource | String | 资源名 |
| grade | int | 0=并发线程数，1=QPS |
| count | double | 限流阈值 |
| strategy | int | 0=直接，1=关联，2=链路 |
| controlBehavior | int | 0=快速失败，1=Warm Up，2=排队 |
| clusterMode | boolean | 是否集群限流 |

### 7.3 降级规则 Nacos 配置

```json
[
  {
    "resource": "callPaymentService",
    "grade": 1,
    "count": 0.5,
    "timeWindow": 60,
    "minRequestAmount": 10,
    "statIntervalMs": 1000,
    "slowRatioThreshold": 0.5
  }
]
```

---

## 八、完整配置示例

```yaml
spring:
  cloud:
    sentinel:
      transport:
        dashboard: sentinel-dashboard:8080
        port: 8719
      eager: true
      datasource:
        # 流控规则
        flow-rule:
          nacos:
            server-addr: ${nacos.server-addr}
            namespace: ${nacos.namespace}
            data-id: ${spring.application.name}-sentinel-flow
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: flow
        # 降级规则
        degrade-rule:
          nacos:
            server-addr: ${nacos.server-addr}
            namespace: ${nacos.namespace}
            data-id: ${spring.application.name}-sentinel-degrade
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: degrade
        # 系统规则
        system-rule:
          nacos:
            server-addr: ${nacos.server-addr}
            namespace: ${nacos.namespace}
            data-id: ${spring.application.name}-sentinel-system
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: system
        # 热点规则
        param-flow-rule:
          nacos:
            server-addr: ${nacos.server-addr}
            namespace: ${nacos.namespace}
            data-id: ${spring.application.name}-sentinel-param
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: param-flow
```

---

## 九、常见坑点与最佳实践

| 坑点 | 现象 | 解决方案 |
|------|------|---------|
| 规则不持久化 | 服务重启后限流规则丢失 | 集成 Nacos 规则持久化（第七章） |
| 注解失效 | `@SentinelResource` 不生效 | Bean 必须通过 Spring 容器获取，不能 new |
| blockHandler 不执行 | 抛了限流异常但没降级 | blockHandler 方法签名须与原方法相同，并增加 `BlockException` 参数 |
| fallback 与 blockHandler 混淆 | 业务异常走了 blockHandler | blockHandler 处理限流/熔断，fallback 处理业务异常，各司其职 |
| 热点参数索引错误 | QPS 计算不准确 | 热点参数索引从 0 开始，与方法参数顺序对应 |
| Dashboard 无监控数据 | 控制台看不到流量 | 确认 `sentinel.transport.dashboard` 配置正确且端口可达 |

---

## 十、总结与延伸

**核心要点**：
1. Sentinel 三大核心能力：**流控（限 QPS/线程数）**、**熔断（慢调用/异常比例/异常数）**、**系统保护（CPU/RT/QPS）**
2. 流控三种模式：**直接**（当前资源）、**关联**（保护被关联资源）、**链路**（按调用链路区分来源）
3. 熔断状态机：**Closed → Open（触发阈值）→ Half-Open（统计窗口到期后探测）→ Closed（探测成功）**
4. **规则必须持久化到 Nacos** 等外部存储，否则服务重启后规则丢失
5. `@SentinelResource` 的 `blockHandler` 和 `fallback` 职责不同，不要混用

**延伸阅读**：
- [Sentinel 官方文档](https://sentinelguard.io/zh-cn/docs/introduction.html) — 完整规则类型与 API
- [Sentinel vs Hystrix vs Resilience4j](https://sentinelguard.io/zh-cn/blog/sentinel-vs-hystrix.html) — 限流熔断框架对比
- Sentinel 集群限流 — 单机限流无法满足整体 QPS 需求时的分布式限流方案
- [Nacos 配置中心](./2025-02-15-nacos-registry-config.md) — 规则持久化的基础设施
