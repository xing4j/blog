# Spring 事件驱动：ApplicationEvent、监听器与 @TransactionalEventListener

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
> - 👉 **SB-13 Spring 事件驱动：ApplicationEvent 与监听器（本文）**
> - [SB-14 Spring @Async 异步编程：原理与线程池配置](posts/2026-05-24-spring-async.md)
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

下订单后要发短信、发邮件、扣积分——如果都写在 `placeOrder()` 里，一个方法几百行，任何一步出错还可能影响主流程。Spring 事件驱动让主流程只负责发布事件，其他逻辑各自监听处理，实现业务解耦。本文讲解 Spring 事件机制的完整实现，重点介绍 `@TransactionalEventListener` 如何解决"事务提交后才执行"的实际需求。

---

## 一、发布-订阅模式在 Spring 中的实现

```
Event Publisher                     Event Listener(s)
(ApplicationEventPublisher)         (ApplicationListener)
         |                                   |
         | publishEvent(event)               |
         v                                   |
ApplicationEventMulticaster ------> onApplicationEvent(event)
```

核心组件：
- `ApplicationEvent`：事件基类，承载事件数据
- `ApplicationEventPublisher`：发布接口，`ApplicationContext` 已实现此接口
- `ApplicationEventMulticaster`：事件多播器，负责找到匹配的监听器并分发
- `ApplicationListener<E>`：监听器接口，泛型指定监听的事件类型

---

## 二、三种实现方式

### 方式一：实现 ApplicationListener 接口（传统方式）

```java
// Spring Boot 3.2 + JDK 17
// 1. 定义事件
public class OrderCreatedEvent extends ApplicationEvent {
    private final Order order;

    public OrderCreatedEvent(Object source, Order order) {
        super(source);
        this.order = order;
    }

    public Order getOrder() { return order; }
}

// 2. 发布事件
@Service
public class OrderService {
    @Autowired
    private ApplicationEventPublisher eventPublisher;

    @Transactional
    public void placeOrder(OrderRequest request) {
        Order order = orderRepo.save(new Order(request));
        // 发布事件，解耦后续操作
        eventPublisher.publishEvent(new OrderCreatedEvent(this, order));
    }
}

// 3. 监听事件
@Component
public class OrderNotificationListener implements ApplicationListener<OrderCreatedEvent> {
    @Override
    public void onApplicationEvent(OrderCreatedEvent event) {
        Order order = event.getOrder();
        smsService.send(order.getUserPhone(), "您的订单 " + order.getId() + " 已创建");
    }
}
```

### 方式二：@EventListener 注解（推荐）

更简洁，不需要实现接口，方法参数即为事件类型：

```java
@Component
public class OrderEventHandler {

    // 监听订单创建事件
    @EventListener
    public void onOrderCreated(OrderCreatedEvent event) {
        emailService.sendOrderConfirmation(event.getOrder());
    }

    // 同时监听多个事件类型
    @EventListener(classes = {OrderCreatedEvent.class, OrderPaidEvent.class})
    public void onOrderChange(ApplicationEvent event) {
        auditService.record(event);
    }

    // 条件过滤：只处理金额 > 1000 的订单事件
    @EventListener(condition = "#event.order.amount > 1000")
    public void onLargeOrder(OrderCreatedEvent event) {
        vipService.notifyVipTeam(event.getOrder());
    }
}
```

### 方式三：异步监听（@Async + @EventListener）

默认情况下，事件监听是同步的（在发布方的线程中执行）。加 `@Async` 改为异步：

```java
@Component
public class AsyncOrderEventHandler {

    @Async("taskExecutor") // 指定线程池，避免用默认 SimpleAsyncTaskExecutor
    @EventListener
    public void onOrderCreated(OrderCreatedEvent event) {
        // 在独立线程中执行，不阻塞主流程
        reportService.generateOrderReport(event.getOrder());
    }
}
```

---

## 三、@TransactionalEventListener：事务提交后才执行

### 3.1 为什么需要它

`@EventListener` 是同步的，在 `publishEvent()` 调用时立即执行监听器。但如果监听器中需要查询刚保存的数据，而此时事务还未提交，数据库中还没有该记录：

```java
@Transactional
public void placeOrder(OrderRequest request) {
    Order order = orderRepo.save(order); // 事务未提交，数据未落库
    eventPublisher.publishEvent(new OrderCreatedEvent(this, order));
    // 如果监听器同步执行并立即查 DB，会查不到！
}
```

### 3.2 @TransactionalEventListener 的语义

```java
@Component
public class OrderInventoryListener {

    // 默认 AFTER_COMMIT：事务提交后才执行
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onOrderCommitted(OrderCreatedEvent event) {
        // 此时事务已提交，DB 中已有数据
        inventoryService.reserve(event.getOrder());
    }
}
```

四种 `TransactionPhase`：

| Phase | 执行时机 |
|-------|---------|
| `AFTER_COMMIT`（默认）| 事务**成功提交**后执行 |
| `AFTER_ROLLBACK` | 事务**回滚**后执行 |
| `AFTER_COMPLETION` | 事务完成（无论提交或回滚）后执行 |
| `BEFORE_COMMIT` | 事务**提交之前**执行（仍在事务内）|

### 3.3 实现原理

`@TransactionalEventListener` 基于 `TransactionSynchronizationManager`，在发布事件时不立即执行，而是注册一个 `TransactionSynchronization` 回调：

```java
// TransactionalEventListenerFactory 生成的适配器简化逻辑
public void onApplicationEvent(ApplicationEvent event) {
    if (TransactionSynchronizationManager.isSynchronizationActive()) {
        // 有活跃事务：注册回调，等事务完成后执行
        TransactionSynchronizationManager.registerSynchronization(
            new TransactionSynchronizationEventAdapter(listener, event, phase)
        );
    } else {
        // 没有事务：根据 fallbackExecution 决定是否直接执行
        if (this.annotation.fallbackExecution()) {
            listener.processEvent(event);
        }
    }
}
```

---

## 四、完整实战：订单创建后的多步骤解耦

```java
// Spring Boot 3.2 + JDK 17
// 主流程：只负责创建订单，其余全部通过事件驱动
@Service
public class OrderService {
    @Autowired
    private ApplicationEventPublisher eventPublisher;

    @Transactional
    public Order placeOrder(OrderRequest request) {
        Order order = orderRepo.save(buildOrder(request));
        // 发布事件（此时事务未提交）
        eventPublisher.publishEvent(new OrderCreatedEvent(this, order));
        return order;
    }
}

// 库存锁定：事务提交后执行，避免查不到数据
@Component
public class InventoryListener {
    @TransactionalEventListener
    public void reserveInventory(OrderCreatedEvent event) {
        inventoryService.lock(event.getOrder().getItems());
    }
}

// 发送通知：异步 + 事务提交后，不阻塞主流程
@Component
public class NotificationListener {
    @Async("notificationExecutor")
    @TransactionalEventListener
    public void sendNotification(OrderCreatedEvent event) {
        notificationService.sendSms(event.getOrder());
        notificationService.sendEmail(event.getOrder());
    }
}

// 积分奖励：事务提交后异步处理
@Component
public class PointsListener {
    @Async
    @TransactionalEventListener
    public void awardPoints(OrderCreatedEvent event) {
        pointsService.award(event.getOrder().getUserId(),
            calculatePoints(event.getOrder()));
    }
}
```

---

## 五、踩坑总结

❌ **`@TransactionalEventListener` 监听器中开启新事务（`@Transactional(propagation = REQUIRES_NEW)`），但事务不生效**

✅ `AFTER_COMMIT` 阶段事务同步已完成，此时调用带 `@Transactional` 的方法，Spring 事务管理器认为没有活跃同步，不会开启新事务。解决方案：在监听器方法上加 `@Transactional(propagation = REQUIRES_NEW)`，同时确保该监听器通过 Spring 代理调用（不能是 `this.xxx()`）。或者将事务操作委托到另一个 Spring Bean 方法中。

❌ **发布事件的方法没有 `@Transactional`，`@TransactionalEventListener` 监听器永远不执行**

✅ 当没有活跃事务时，`@TransactionalEventListener` 默认**不执行**（`fallbackExecution = false`）。设置 `@TransactionalEventListener(fallbackExecution = true)` 可在无事务时降级为立即执行，或改用普通 `@EventListener`。

---

## 六、文章小结

- Spring 事件机制基于观察者模式，`ApplicationEventMulticaster` 负责将事件分发给所有匹配的监听器
- `@EventListener` 是最简洁的声明式监听方式，支持条件过滤（`condition` SpEL）和多事件类型
- 异步监听：`@Async` + `@EventListener` 组合，推荐显式指定线程池而非默认 `SimpleAsyncTaskExecutor`
- `@TransactionalEventListener` 通过 `TransactionSynchronization` 回调实现"事务提交后执行"，默认阶段为 `AFTER_COMMIT`
- 没有活跃事务时，`@TransactionalEventListener` 默认静默不执行，可通过 `fallbackExecution = true` 覆盖

---

## 七、思考题

1. 如果 `@TransactionalEventListener` 监听器（`AFTER_COMMIT`）中执行了数据库操作，但该操作抛出异常，会影响已提交的主事务吗？如何处理该异常？

2. 同一个事件有多个 `@EventListener` 监听器，执行顺序由什么决定？如何保证 A 先于 B 执行？

---

## 参考资料

> 1. [Spring 官方文档 - Application Events and Listeners](https://docs.spring.io/spring-framework/reference/core/beans/context-introduction.html#context-functionality-events)
> 2. Spring Framework 源码：`ApplicationEventMulticaster`、`TransactionalEventListenerFactory`（版本：6.1）
> 3. [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> 4. [SB-14 Spring @Async 异步编程：原理与线程池配置](posts/2026-05-24-spring-async.md)
