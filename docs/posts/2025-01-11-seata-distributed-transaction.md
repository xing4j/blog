# 分布式事务：Seata 全面解析与生产实践

<div class="post-meta">📅 2025-01-11 &nbsp;·&nbsp; 🏷️ <span class="tag">Seata</span> <span class="tag">分布式事务</span> <span class="tag">微服务</span></div>

下单扣库存，两个服务，两个数据库。订单写成功，库存扣失败——钱收了，货没扣。这不是假设，是每个拆了库的团队迟早要面对的问题。本文从分布式事务的本质挑战出发，系统讲解 Seata 的 AT/TCC 两种模式，重点剖析 AT 模式的底层机制，并提供完整的 Spring Boot 集成方案和生产实践建议。

---

## 一、分布式事务的本质挑战

### 1.1 单体时代的幸福

单体应用下，一个本地事务覆盖所有操作：

```java
@Transactional
public void createOrder(OrderDTO dto) {
    orderMapper.insert(...);   // 订单
    stockMapper.deduct(...);   // 同一个库、同一个连接，ACID 天然保证
    payMapper.deduct(...);     // 余额
}
```

微服务拆库后，这种保证消失了：

```
订单服务 ──→ orderMapper.insert()  ──→  订单 DB（MySQL A）
    │
    └─ Feign ──→ 库存服务 ──→ stockMapper.deduct()  ──→  库存 DB（MySQL B）
```

两个数据库，两个本地事务，任何一步失败，另一步无法自动回滚。

### 1.2 BASE 理论与最终一致性

面向互联网的微服务选择 AP（可用性 + 分区容忍），放弃强一致性，代价是接受**最终一致性**。

**BASE 理论**是对 ACID 的妥协：
- **Basically Available**：基本可用，允许局部故障降级
- **Soft State**：软状态，允许数据有中间态（如"扣款处理中"）
- **Eventually Consistent**：最终一致，过一段时间数据收敛

---

## 二、主流分布式事务方案全景

| 方案 | 一致性 | 性能 | 侵入性 | 适用场景 |
|------|--------|------|--------|---------|
| **XA/2PC** | 强一致 | ⭐⭐ | 低 | 数据库内置，少量跨库 |
| **TCC** | 最终一致 | ⭐⭐⭐⭐ | 高 | 金融核心，需精确回滚 |
| **Saga** | 最终一致 | ⭐⭐⭐⭐ | 中 | 长流程，涉及外部系统 |
| **AT（Seata）** | 最终一致 | ⭐⭐⭐ | 低 | 通用 CRUD，快速接入 |
| **本地消息表** | 最终一致 | ⭐⭐⭐⭐ | 中 | 跨服务异步事件 |

### 2.1 XA/2PC 为什么不适合互联网场景

```
协调者 ──── Prepare ────▶  参与者A（持有锁，等待）
       ╰─── Prepare ────▶  参与者B（持有锁，等待）
                ↑ 网络超时 / 协调者宕机
               所有参与者永久等待，锁不释放
```

XA 的致命缺陷：同步阻塞 + 协调者单点故障。Seata AT 模式的核心改进是**一阶段直接提交，二阶段异步补偿**，消除了 2PC 的同步阻塞。

---

## 三、Seata 架构：TC / TM / RM

```
┌──────────────────────────────────────────────────────────┐
│                   Seata Server（TC）                      │
│            Transaction Coordinator - 全局事务协调者        │
│  职责：维护全局/分支事务状态，驱动提交或回滚                  │
└────────────────────────────┬─────────────────────────────┘
                             │ Netty RPC
           ┌─────────────────┴──────────────────┐
           ▼                                     ▼
┌──────────────────┐                  ┌──────────────────────┐
│  订单服务（TM）   │                  │   库存服务（RM）       │
│  Transaction     │ ── Feign+XID ──▶ │   Resource Manager   │
│  Manager         │                  │   管理分支事务资源      │
│  @GlobalTx 发起  │                  │                      │
└────────┬─────────┘                  └──────────┬───────────┘
         │                                       │
         ▼                                       ▼
    订单 DB（MySQL）                         库存 DB（MySQL）
```

- **TC（Transaction Coordinator）**：Seata Server，全局事务"大脑"，保存状态、协调提交/回滚
- **TM（Transaction Manager）**：`@GlobalTransactional` 所在服务，控制全局事务的开始/提交/回滚
- **RM（Resource Manager）**：参与全局事务的每个微服务，向 TC 注册分支事务，执行本地提交或回滚

---

## 四、AT 模式深度剖析

### 4.1 一阶段：直接提交 + 保存快照

AT 模式通过**代理数据源**自动拦截 SQL，一阶段不等待全局事务结束直接提交本地事务：

```
原始 SQL：UPDATE stock SET quantity = quantity - 1 WHERE product_id = 100

AT 代理执行顺序：
1. SELECT * FROM stock WHERE product_id = 100         → 保存 before image
2. UPDATE stock SET quantity = quantity - 1 WHERE ...   → 执行业务 SQL
3. SELECT * FROM stock WHERE product_id = 100         → 保存 after image
4. 将 before/after image 序列化写入 undo_log（同一本地事务）
5. 本地事务提交（释放本地锁，其他本地事务可见）
```

每个参与分布式事务的业务数据库都需要创建 `undo_log` 表：

```sql
CREATE TABLE `undo_log` (
    `id`            BIGINT(20)    NOT NULL AUTO_INCREMENT,
    `branch_id`     BIGINT(20)    NOT NULL COMMENT '分支事务ID',
    `xid`           VARCHAR(128)  NOT NULL COMMENT '全局事务ID',
    `context`       VARCHAR(128)  NOT NULL COMMENT '序列化类型（jackson/kryo）',
    `rollback_info` LONGBLOB      NOT NULL COMMENT 'before/after image JSON',
    `log_status`    INT(11)       NOT NULL COMMENT '0:normal 1:defense（防悬挂）',
    `log_created`   DATETIME(6)   NOT NULL,
    `log_modified`  DATETIME(6)   NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `ux_undo_log` (`xid`, `branch_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
```

### 4.2 二阶段：异步提交或基于快照回滚

**全局提交（正常路径）**：仅做异步删除 undo_log，不影响主链路 RT。

**全局回滚（异常路径）**：

```java
// 回滚 SQL 自动生成
// 业务 SQL：UPDATE stock SET quantity = 9 WHERE product_id = 100
// before image：{ product_id: 100, quantity: 10 }
// after image： { product_id: 100, quantity: 9  }
// 回滚 SQL：UPDATE stock SET quantity = 10 WHERE product_id = 100 AND quantity = 9
//                                                              ↑ 校验 after image，防脏回滚
```

### 4.3 全局锁：防止脏写

一阶段提交后，全局事务还没结束。若另一本地事务修改同一行，全局回滚时会用 before image 覆盖该修改——这就是**脏写**。

Seata 通过**全局行锁（存储在 TC）**解决：

```
AT 一阶段提交时         → 向 TC 申请全局行锁（持有至全局事务结束）
其他 AT 事务修改同一行  → 检测到全局锁 → 重试等待（默认 30 次 × 10ms）
全局事务结束            → 释放全局锁
```

### 4.4 隔离级别

AT 默认**读未提交**。需要读已提交时：

```java
@GlobalLock
@Transactional
public StockVO queryForCriticalRead(Long productId) {
    // SELECT ... FOR UPDATE 触发全局锁检查
    return stockMapper.selectForUpdate(productId);
}
```
---

## 五、TCC 模式实战

### 5.1 TCC 三阶段设计

TCC 是**业务层面的 2PC**，以代码侵入换高性能（无全局行锁）：

```
Try     → 预留资源（冻结库存，不直接扣减）
Confirm → 确认执行（使用冻结资源）
Cancel  → 取消执行（释放冻结资源）
```

数据库设计需增加冻结字段：

```sql
-- 增加 frozen_quantity 字段
ALTER TABLE stock ADD COLUMN frozen_quantity INT NOT NULL DEFAULT 0 COMMENT '冻结数量';
-- Try：    quantity -= n,  frozen_quantity += n
-- Confirm：frozen_quantity -= n
-- Cancel： quantity += n,  frozen_quantity -= n
```

### 5.2 TCC 接口实现

```java
@LocalTCC
public interface StockTCCService {

    @TwoPhaseBusinessAction(name = "deductStock", commitMethod = "confirm", rollbackMethod = "cancel")
    boolean tryDeduct(
        BusinessActionContext context,
        @BusinessActionContextParameter(paramName = "productId") Long productId,
        @BusinessActionContextParameter(paramName = "quantity") int quantity
    );

    boolean confirm(BusinessActionContext context);

    boolean cancel(BusinessActionContext context);
}

@Service
public class StockTCCServiceImpl implements StockTCCService {

    @Autowired
    private StockMapper stockMapper;

    @Override
    @Transactional
    public boolean tryDeduct(BusinessActionContext ctx, Long productId, int quantity) {
        Stock stock = stockMapper.selectByProductId(productId);
        if (stock.getQuantity() < quantity) {
            return false;
        }
        stockMapper.freeze(productId, quantity); // 冻结（预扣）
        return true;
    }

    @Override
    @Transactional
    public boolean confirm(BusinessActionContext ctx) {
        Long productId = Long.parseLong(ctx.getActionContext("productId").toString());
        int quantity   = Integer.parseInt(ctx.getActionContext("quantity").toString());
        stockMapper.confirmDeduct(productId, quantity); // 消耗冻结库存
        return true;
    }

    @Override
    @Transactional
    public boolean cancel(BusinessActionContext ctx) {
        Long productId = Long.parseLong(ctx.getActionContext("productId").toString());
        int quantity   = Integer.parseInt(ctx.getActionContext("quantity").toString());

        // 防空回滚：Try 未执行时冻结量为 0，直接返回成功
        Stock stock = stockMapper.selectByProductId(productId);
        if (stock == null || stock.getFrozenQuantity() < quantity) {
            return true;
        }
        stockMapper.unfreeze(productId, quantity); // 释放冻结
        return true;
    }
}
```

### 5.3 TCC 三大经典问题

| 问题 | 触发场景 | 解决方案 |
|------|----------|---------|
| **空回滚** | Try 因网络超时未执行，Cancel 被触发 | Cancel 中判断冻结状态，未冻结则直接成功 |
| **幂等性** | Confirm/Cancel 因超时被重复调用 | 用 xid+branchId 作唯一 key，幂等表防重 |
| **悬挂** | Cancel 先于 Try 到达（网络乱序） | Try 中检查是否已执行 Cancel，若已 Cancel 直接返回失败 |

---

## 六、Spring Boot 集成实战

### 6.1 依赖引入

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-seata</artifactId>
</dependency>
```

### 6.2 application.yml 配置

```yaml
seata:
  enabled: true
  application-id: ${spring.application.name}
  tx-service-group: my_tx_group
  registry:
    type: nacos
    nacos:
      server-addr: ${nacos.server-addr}
      namespace: ${nacos.namespace}
      group: SEATA_GROUP
      application: seata-server
  config:
    type: nacos
    nacos:
      server-addr: ${nacos.server-addr}
      namespace: ${nacos.namespace}
      group: SEATA_GROUP
      data-id: seataServer.properties
  data-source-proxy-mode: AT
```

### 6.3 业务代码

```java
@Service
@RequiredArgsConstructor
public class OrderApplicationService {

    private final OrderRepository    orderRepository;
    private final StockFeignClient   stockFeignClient;
    private final PaymentFeignClient paymentFeignClient;

    @GlobalTransactional(name = "create-order-tx", rollbackFor = Exception.class, timeoutMills = 30000)
    public OrderVO createOrder(CreateOrderCommand cmd) {
        Order order = Order.create(cmd);
        orderRepository.save(order);

        Result<Void> stockResult = stockFeignClient.deduct(cmd.getProductId(), cmd.getQuantity());
        if (!stockResult.isSuccess()) {
            throw new BizException(ErrorCode.STOCK_INSUFFICIENT);
        }

        paymentFeignClient.deduct(cmd.getUserId(), cmd.getAmount());
        return OrderVO.from(order);
    }
}
```

### 6.4 异步线程中 XID 丢失（高频坑）

```java
@GlobalTransactional
public void createOrder(CreateOrderCommand cmd) {
    // 错误：新线程中 XID 丢失，库存操作不在全局事务内
    CompletableFuture.runAsync(() -> stockFeignClient.deduct(...));

    // 正确：手动传递 XID 到子线程
    String xid = RootContext.getXID();
    CompletableFuture.runAsync(() -> {
        RootContext.bind(xid);
        try {
            stockFeignClient.deduct(...);
        } finally {
            RootContext.unbind();
        }
    });
}
```

---

## 七、常见坑点与最佳实践

### 7.1 undo_log 表无限膨胀

```yaml
seata:
  server:
    undo:
      log-save-days: 1         # 异常积压的 undo_log 保留 1 天
      log-delete-period: 86400 # 每天清理
```

### 7.2 全局锁竞争导致超时

根本解法：**缩短全局事务的跨越范围**，把不需要强一致的操作移出 `@GlobalTransactional`，改用消息队列异步处理。

```yaml
seata:
  client:
    rm:
      lock:
        retry-times: 30
        retry-interval: 10
        retry-policy-branch-rollback-on-conflict: true
```

### 7.3 大字段表的回滚性能

AT 模式对每个写操作都会 `SELECT *` 生成 before image。若表含大字段（TEXT/BLOB）：
1. UPDATE 语句指定精确字段，避免 `SELECT *`
2. 将大字段迁移到独立表，主表只保留索引列

### 7.4 @Transactional 嵌套

```java
// 正确：@GlobalTransactional 在最外层，内层 @Transactional 自动加入全局事务
@GlobalTransactional
public void outer() {
    innerService.doSomething(); // REQUIRES（默认传播），加入全局事务
}

// 错误：REQUIRES_NEW 开独立本地事务，全局回滚时已提交，无法撤销
```

---

## 八、AT vs TCC 选型指南

| 维度 | AT 模式 | TCC 模式 |
|------|---------|---------|
| 业务侵入性 | 低，只加注解 | 高，实现三个方法 |
| 适用 SQL | 标准 INSERT/UPDATE/DELETE | 任意，含无 SQL 的第三方调用 |
| 性能 | 中（有全局锁开销） | 高（一阶段冻结即释放本地锁） |
| 默认隔离级别 | 读未提交 | 业务自定义 |
| 开发复杂度 | 低 | 高（空回滚/幂等/悬挂） |
| 适用场景 | 通用 CRUD，80% 的场景 | 金融核心，涉及外部接口 |

**决策原则**：
- **优先 AT**：代码零侵入，适合大多数场景
- **用 TCC**：涉及第三方支付接口，或需要自定义回滚逻辑
- **用 Saga**：跨多个外部系统的长流程（电商履约：下单→发货→通知→退款）
- **用消息队列**：对最终一致性容忍度高、可以异步的场景（如积分发放）

---

## 九、总结与延伸

**核心要点**：
1. Seata AT 的本质：**改良版 2PC**，一阶段直接提交消除阻塞，二阶段用 undo_log before image 回滚
2. **全局锁**是 AT 防脏写的关键机制，也是性能瓶颈，高并发下需控制事务范围
3. TCC 以**业务侵入**换取更高性能和更灵活的回滚逻辑，需处理空回滚/幂等/悬挂三大经典问题
4. **XID 传递**是分布式事务的血管，跨线程时必须手动绑定，不能遗漏

**延伸阅读**：
- [Apache Seata 官方文档](https://seata.apache.org/zh-cn/docs/overview/what-is-seata) — AT/TCC/Saga/XA 四种模式详解
- [Seata DataSourceProxy 源码](https://github.com/apache/incubator-seata) — 理解 AT 模式数据源代理机制
- [Outbox 模式](https://microservices.io/patterns/data/transactional-outbox.html) — 用本地消息表替代分布式事务的更轻量方案
- [Saga 模式](https://microservices.io/patterns/data/saga.html) — 长流程补偿，适合跨多个外部系统的业务
