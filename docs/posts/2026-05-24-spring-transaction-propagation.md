# Spring 事务传播行为：7 种传播级别与底层实现原理

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
> - 👉 **SB-04 Spring 事务传播行为：7 种传播级别与底层实现（本文）**
> - [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](posts/2026-05-24-spring-boot-startup.md)
> - [SB-08 Spring Boot 自动装配原理深度解析](posts/2024-10-27-spring-boot-autoconfigure.md)
> - [SB-09 Spring Boot 配置体系详解](posts/2026-05-16-spring-boot-config-priority.md)
> - [SB-10 Spring Boot 条件装配：@Conditional 体系](posts/2026-05-24-spring-boot-conditional.md)
> - [SB-11 Spring 循环依赖：三级缓存的设计原理](posts/2026-05-24-spring-circular-dependency.md)
> - [SB-12 Filter、Interceptor、AOP 三者对比与选型](posts/2026-05-24-spring-filter-interceptor-aop.md)
> - [SB-13 Spring 事件驱动：ApplicationEvent 与监听器](posts/2026-05-24-spring-events.md)
> - [SB-14 Spring @Async 异步编程：原理与线程池配置](posts/2026-05-24-spring-async.md)
> - [SB-15 Spring 扩展点：BPP、BFPP 与 ImportSelector](posts/2026-05-24-spring-extension-points.md)
> - [SB-16 Spring Boot 全局异常处理与参数校验](posts/2026-05-24-spring-exception-handler.md)
> - [SB-17 Spring Boot 多数据源：动态路由与跨库事务](posts/2026-05-24-spring-boot-multi-datasource.md)
> - [SB-18 Spring Boot Actuator：健康检查与自定义端点](posts/2026-05-24-spring-boot-actuator.md)
> - [SB-19 Spring Boot 自定义 Starter：从设计到发布](posts/2026-05-24-spring-boot-custom-starter.md)
> - [SB-20 Spring Security 认证授权完整流程](posts/2024-12-23-spring-security-auth.md)
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](posts/2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](posts/2026-05-24-spring-boot-testing.md)

**深度等级**：⭐ 入门｜**阅读时长**：约 22 分钟｜**分类**：Spring 生态

---

## 导读

事务传播行为是 Spring 事务最容易被忽视却最容易踩坑的部分。很多人只记得 `REQUIRED`，但当业务中出现方法嵌套调用时，选错传播级别会导致事务范围不符合预期——要么事务范围过大导致性能问题，要么事务范围过小导致数据不一致。本文系统讲解 7 种传播级别的语义、底层实现原理，以及嵌套事务与保存点的工作机制。

---

## 一、为什么需要事务传播行为

考虑这个场景：

```java
// 外层方法，有事务
@Transactional
public void placeOrder(Order order) {
    orderDao.insert(order);          // 插入订单
    inventoryService.deduct(order);  // 扣减库存（另一个 @Transactional 方法）
    logService.log("order placed");  // 记录日志（另一个 @Transactional 方法）
}
```

当 `inventoryService.deduct()` 内部也标注了 `@Transactional`，两个问题随之而来：
1. `deduct()` 是加入外层事务，还是自己开一个新事务？
2. `deduct()` 抛异常，是只回滚自己，还是回滚整个 `placeOrder()`？

**事务传播行为（Transaction Propagation）**就是用来回答这两个问题的：当被调用方法执行时，如何处理当前是否已存在事务这件事。

---

## 二、7 种传播级别详解

### 2.1 REQUIRED（默认）

```
propagation = Propagation.REQUIRED
```

**语义**：如果当前有事务，加入；如果没有，新开一个。

```
场景 A：外层有事务
  外层 ----[TX1]-------------------------------->
  内层         --[加入 TX1]---------->

  结果：外层和内层共享同一事务 TX1
        任意一方抛异常 -> TX1 回滚（两者都回滚）

场景 B：外层无事务
  外层   （无事务）
  内层         --[新建 TX2]-->

  结果：内层独立执行 TX2
```

```java
// Spring Boot 3.2 + JDK 17 + Spring Data JPA
@Service
public class OrderService {
    @Transactional // REQUIRED（默认）
    public void createOrder(Order order) {
        orderRepo.save(order);
        inventoryService.deduct(order.getProductId(), order.getQty()); // 加入当前事务
    }
}

@Service
public class InventoryService {
    @Transactional // REQUIRED：加入 createOrder 的事务
    public void deduct(Long productId, int qty) {
        Inventory inv = inventoryRepo.findById(productId).orElseThrow();
        if (inv.getQty() < qty) throw new InsufficientStockException();
        inv.setQty(inv.getQty() - qty);
        inventoryRepo.save(inv);
        // 如果这里抛异常，整个 createOrder 的事务也会回滚
    }
}
```

### 2.2 REQUIRES_NEW

**语义**：无论当前是否有事务，都挂起当前事务，新开一个独立事务；自己提交/回滚不影响外层。

```
场景：外层有事务 TX1
  外层 ----[TX1]---- suspend ------------ resume ---->
  内层              --[新建 TX2]-->
                       TX2 独立提交/回滚，不影响 TX1
```

**典型用途**：记录操作日志——无论主业务是否成功，日志都要持久化。

```java
@Service
public class AuditLogService {
    @Transactional(propagation = Propagation.REQUIRES_NEW) // 独立事务
    public void log(String action, Long userId) {
        auditLogRepo.save(new AuditLog(action, userId, LocalDateTime.now()));
        // 即使外层主事务回滚，日志依然提交
    }
}
```

### 2.3 NESTED

**语义**：如果当前有事务，在其内部创建一个嵌套事务（通过保存点 Savepoint 实现）；嵌套事务回滚只回滚到保存点，不影响外层；如果没有外层事务，行为同 REQUIRED。

```
外层 ----[TX1]------------ Savepoint A ---------------- commit >
                                  |                          |
                   内层嵌套事务：[TX1 内部嵌套]               |
                                  内层回滚 -> 回滚到 Savepoint A
                                  外层不感知，继续提交
```

**NESTED vs REQUIRES_NEW 对比**：

| 维度 | NESTED | REQUIRES_NEW |
|------|--------|-------------|
| 是否共享外层连接 | ✅ 共享（同一连接，通过 Savepoint）| ❌ 独立连接 |
| 内层回滚影响外层 | 不影响（回滚到保存点）| 不影响 |
| 外层回滚影响内层 | ✅ 影响（外层回滚，保存点也消失）| ❌ 不影响（TX2 已独立提交）|
| 数据库支持要求 | 需要支持 Savepoint（MySQL InnoDB 支持）| 无特殊要求 |
| 性能 | 较好（复用连接）| 较差（新连接）|

### 2.4 SUPPORTS

**语义**：如果当前有事务，加入；如果没有，以非事务方式执行。

**适用场景**：只读查询——有事务时跟着走，没有时不开事务，减少事务开销。

```java
@Transactional(propagation = Propagation.SUPPORTS, readOnly = true)
public User findById(Long id) {
    return userRepo.findById(id).orElse(null);
}
```

### 2.5 NOT_SUPPORTED

**语义**：挂起当前事务，以非事务方式执行。适用于某些不支持事务的操作（如调用旧系统接口），防止事务干扰。

### 2.6 MANDATORY

**语义**：必须在现有事务中执行；如果当前没有事务，抛 `IllegalTransactionStateException`。用于强制调用方必须开启事务（内部保证数据一致性的 DAO 层方法）。

### 2.7 NEVER

**语义**：不允许在事务中执行；如果当前有事务，抛 `IllegalTransactionStateException`。与 MANDATORY 相反。

---

## 三、传播行为汇总对比

| 传播级别 | 当前有事务 | 当前无事务 | 典型使用场景 |
|---------|----------|----------|-----------|
| REQUIRED（默认）| 加入 | 新建 | 通用业务方法 |
| REQUIRES_NEW | 挂起并新建 | 新建 | 独立审计日志、消息通知 |
| NESTED | 嵌套（Savepoint）| 新建 | 批量操作中单条失败可重试 |
| SUPPORTS | 加入 | 非事务 | 只读查询 |
| NOT_SUPPORTED | 挂起 | 非事务 | 不支持事务的遗留操作 |
| MANDATORY | 加入 | 抛异常 | 强制调用方开启事务的内部 DAO |
| NEVER | 抛异常 | 非事务 | 明确禁止事务的操作 |

---

## 四、底层实现：TransactionSynchronizationManager

Spring 事务的底层依赖 `TransactionSynchronizationManager`，它通过 `ThreadLocal` 将数据库连接绑定到当前线程：

```java
// 核心：当前线程绑定的资源（Connection 等）
private static final ThreadLocal<Map<Object, Object>> resources =
    new NamedThreadLocal<>("Transactional resources");

// 当前线程活跃的事务同步回调列表
private static final ThreadLocal<Set<TransactionSynchronization>> synchronizations =
    new NamedThreadLocal<>("Transaction synchronizations");
```

`AbstractPlatformTransactionManager.getTransaction()` 的核心逻辑：

```java
public final TransactionStatus getTransaction(@Nullable TransactionDefinition definition) {
    Object transaction = doGetTransaction();
    // 检查当前线程是否已有事务
    if (isExistingTransaction(transaction)) {
        // 有事务：根据传播行为决定加入/挂起/嵌套
        return handleExistingTransaction(definition, transaction);
    }
    // 无事务：根据传播行为决定新建/非事务执行/抛异常
    if (definition.getPropagationBehavior() == PROPAGATION_MANDATORY) {
        throw new IllegalTransactionStateException("No existing transaction found...");
    }
    if (definition.getPropagationBehavior() == PROPAGATION_REQUIRED ||
        definition.getPropagationBehavior() == PROPAGATION_REQUIRES_NEW ||
        definition.getPropagationBehavior() == PROPAGATION_NESTED) {
        return startTransaction(definition, transaction, ...);
    }
    // SUPPORTS / NOT_SUPPORTED / NEVER：以非事务方式执行
    return prepareTransactionStatus(definition, null, true, ...);
}
```

---

## 五、踩坑总结

❌ **REQUIRES_NEW 在同一个类内调用不生效，日志方法始终和主业务共享事务**

```java
@Service
public class OrderService {
    @Transactional
    public void createOrder(Order order) {
        orderDao.insert(order);
        this.logAction(order); // this 调用，AOP 代理未介入，REQUIRES_NEW 不生效！
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logAction(Order order) { ... }
}
```

✅ 原因：Spring 事务基于 AOP 代理实现，同类内 `this.xxx()` 调用绕过代理。解决方案：将 `logAction` 拆到独立的 Service Bean，或注入自身代理（`@Autowired private OrderService self`）。

❌ **使用 NESTED 但数据库不支持 Savepoint，运行时报错**

✅ MySQL InnoDB 支持 Savepoint，PostgreSQL 也支持；但部分 JDBC 驱动或连接池配置下可能不可用。使用前用 `DatabaseMetaData.supportsSavepoints()` 确认，不支持时降级用 REQUIRES_NEW。

---

## 六、文章小结

- 7 种传播行为本质是回答"当前方法执行时，如何处理已存在或不存在的事务"
- REQUIRED（默认）适合绝大多数业务场景；日志/通知场景用 REQUIRES_NEW 实现事务隔离
- NESTED 通过数据库 Savepoint 实现嵌套回滚，与 REQUIRES_NEW 的关键区别在于是否共享外层连接和外层回滚的影响
- 底层 `TransactionSynchronizationManager` 通过 `ThreadLocal` 绑定连接，传播行为在 `getTransaction()` 中实现
- 所有传播行为生效的前提：被调用方法必须通过 Spring 代理调用（非 this 直接调用）

---

## 七、思考题

1. `placeOrder()` 中调用 `logService.log()` 使用了 `REQUIRES_NEW`，如果 `placeOrder()` 事务最终回滚，已经用 REQUIRES_NEW 独立提交的日志记录会一起回滚吗？为什么？

2. 一个事务方法 A（REQUIRED）调用了事务方法 B（NESTED），B 正常执行，A 最后抛异常回滚，B 的数据会保留吗？

---

## 参考资料

> 1. [Spring 官方文档 - Transaction Propagation](https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html)
> 2. Spring Framework 源码：`AbstractPlatformTransactionManager`、`TransactionSynchronizationManager`（版本：6.1）
> 3. [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
