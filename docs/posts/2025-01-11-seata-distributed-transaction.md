# 分布式事务：Seata AT 模式原理与实践

<div class="post-meta">📅 2025-01-11 &nbsp;·&nbsp; 🏷️ <span class="tag">Seata</span> <span class="tag">分布式事务</span></div>

分布式事务是微服务架构下最棘手的问题之一。本文对比主流方案并深入讲解 Seata AT 模式的原理与 Spring Boot 集成实践。

---

## 一、分布式事务方案对比

| 方案 | 原理 | 优点 | 缺点 | 适用场景 |
|------|------|------|------|---------|
| **2PC** | 协调者+参与者，两阶段提交 | 强一致性 | 阻塞、单点故障 | 数据库内置 |
| **TCC** | Try-Confirm-Cancel 业务补偿 | 高性能、无锁 | 业务侵入性强 | 金融核心 |
| **Saga** | 长事务拆分，失败正向补偿 | 无阻塞 | 最终一致 | 长流程业务 |
| **AT** | 自动生成回滚 SQL | 侵入性低 | 需undo_log表 | 通用业务（Seata首选）|

---

## 二、Seata AT 模式原理

### 三大角色

```
TC（Transaction Coordinator）：Seata Server，全局事务协调者
TM（Transaction Manager）：发起全局事务的服务（@GlobalTransactional 所在服务）
RM（Resource Manager）：管理分支事务的服务（各微服务）
```

### 执行流程

```
TM                    TC                    RM1(订单库)         RM2(库存库)
 │                     │                        │                    │
 │── @GlobalTransactional ──→ Begin ──→         │                    │
 │                     │← XID ─────────         │                    │
 │                     │                        │                    │
 │── 调用订单服务 ─────────────────────────────→│                    │
 │                     │                  RM注册分支               │
 │                     │← Branch Register ┤                    │
 │                     │                  │记录 before/after image│
 │                     │                  │写入 undo_log          │
 │                     │                  │执行本地事务            │
 │                     │← Branch Report   │                    │
 │                     │                        │                    │
 │── 调用库存服务 ────────────────────────────────────────────→  │
 │                     │                        │     (同上流程)    │
 │                     │                        │                    │
 │── Commit/Rollback ─→│                        │                    │
 │                     │── Branch Commit/Rollback→                   │
```

### undo_log 表（每个业务库都需要）

```sql
CREATE TABLE `undo_log` (
    `branch_id`     BIGINT       NOT NULL COMMENT '分支事务ID',
    `xid`           VARCHAR(128) NOT NULL COMMENT '全局事务ID',
    `context`       VARCHAR(128) NOT NULL COMMENT '序列化类型',
    `rollback_info` LONGBLOB     NOT NULL COMMENT '回滚数据',
    `log_status`    INT(11)      NOT NULL COMMENT '0:normal,1:defense',
    `log_created`   DATETIME(6)  NOT NULL,
    `log_modified`  DATETIME(6)  NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `ux_undo_log` (`xid`, `branch_id`)
) ENGINE = InnoDB;
```

---

## 三、Spring Boot 集成实战

### 1. 依赖配置

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-seata</artifactId>
</dependency>
```

### 2. application.yml

```yaml
seata:
  enabled: true
  application-id: order-service
  tx-service-group: my_tx_group
  service:
    vgroup-mapping:
      my_tx_group: default
  registry:
    type: nacos
    nacos:
      server-addr: 127.0.0.1:8848
      namespace: seata
  config:
    type: nacos
    nacos:
      server-addr: 127.0.0.1:8848
```

### 3. 业务代码（TM 端）

```java
@Service
public class OrderService {

    @Autowired private OrderMapper orderMapper;
    @Autowired private StockFeignClient stockFeignClient;

    /**
     * @GlobalTransactional 开启全局事务
     * rollbackFor 包含所有异常类型
     */
    @GlobalTransactional(name = "create-order", rollbackFor = Exception.class)
    public void createOrder(OrderDTO dto) {
        // 1. 创建订单（本地事务，AT 模式自动管理）
        Order order = new Order();
        order.setUserId(dto.getUserId());
        order.setAmount(dto.getAmount());
        orderMapper.insert(order);

        // 2. 扣减库存（远程调用，Seata 自动传递 XID）
        stockFeignClient.deduct(dto.getProductId(), dto.getQuantity());

        // 3. 模拟异常，验证全局回滚
        if (dto.getAmount().compareTo(BigDecimal.ZERO) < 0) {
            throw new BizException("金额不能为负数");
        }
    }
}
```

### 4. Feign 传递 XID（拦截器）

```java
@Component
public class SeataFeignInterceptor implements RequestInterceptor {
    @Override
    public void apply(RequestTemplate template) {
        // 将全局事务 XID 通过 HTTP Header 传递给下游
        String xid = RootContext.getXID();
        if (StringUtils.hasText(xid)) {
            template.header(RootContext.KEY_XID, xid);
        }
    }
}
```

---

## 四、全局锁与脏写问题

### 问题：AT 模式一阶段提交后，二阶段回滚前存在短暂数据可见性

```
T1（全局事务）：写 → 一阶段提交 → [回滚阶段，T2可能读到中间态]
T2（本地事务）：                     读 → 读到未提交的"最终"态 ← 脏读！
```

**解决**：
- 读操作加 `@GlobalLock` 注解，读取前检查全局锁
- 或对读操作使用 `SELECT ... FOR UPDATE` 触发全局锁检查

---

## 五、AT vs TCC 选型

| 场景 | 推荐 |
|------|------|
| 通用 CRUD 业务，SQL 简单 | **AT 模式**（低侵入） |
| 金融核心，要求精确回滚 | **TCC 模式**（业务侵入换强一致）|
| 涉及第三方接口无法回滚 | **Saga 模式**（正向补偿）|
| 同一数据库内多表 | 本地事务即可，无需 Seata |

---

## 总结

- Seata AT 通过**自动生成 undo_log** 实现非侵入式分布式事务
- 全局事务由 `@GlobalTransactional`（TM）发起，TC 协调各 RM 提交或回滚
- 需注意：每个参与事务的库都需创建 `undo_log` 表，且 AT 模式存在短暂脏读窗口
