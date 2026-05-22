# 接口幂等性设计的 5 种方案

<div class="post-meta">📅 2025-07-19 &nbsp;·&nbsp; 🏷️ <span class="tag">架构</span></div>

幂等性（Idempotency）指的是同一操作执行多次与执行一次的结果完全相同。在分布式系统中，网络重试、消息重复消费、用户重复点击等场景都要求接口具备幂等性。本文介绍 5 种主流方案，并给出对比和选型建议。

---

## 一、为什么需要幂等性

```
常见的重复请求场景：

1. 网络超时重试
   Client ──→ [超时] ──→ Client 重试
                          Server 已处理第一次请求 → 重复扣款！

2. MQ 消息重复消费
   Consumer 消费成功但提交 offset 前崩溃
   重启后重新消费同一条消息 → 重复创建订单！

3. 用户重复点击
   用户快速双击提交按钮 → 创建两笔订单！

4. 页面重复提交（F5 刷新）
   POST 请求被浏览器重新发送 → 重复数据！
```

---

## 二、方案一：Token 机制（防重令牌）

### 原理

```
Step 1: 客户端获取 Token
Client ──GET /api/token──→ Server
       ←─ token=UUID ────

Step 2: 客户端提交请求（携带 Token）
Client ──POST /api/order (token=UUID)──→ Server
       
Step 3: Server 端原子操作
       Redis DEL token（原子删除）
       ├── 删除成功 → 执行业务逻辑 → 返回成功
       └── 删除失败（token不存在）→ 返回"重复请求"
```

### 代码实现

```java
@RestController
public class TokenController {

    @Autowired
    private StringRedisTemplate redisTemplate;

    /**
     * 获取幂等 Token
     */
    @GetMapping("/api/token")
    public String getToken() {
        String token = UUID.randomUUID().toString().replace("-", "");
        // Token 存入 Redis，5分钟有效
        redisTemplate.opsForValue().set("idempotent:token:" + token, "1",
            Duration.ofMinutes(5));
        return token;
    }
}

@Service
public class OrderService {

    @Autowired
    private StringRedisTemplate redisTemplate;

    /**
     * 创建订单（幂等保护）
     */
    public OrderResult createOrder(String token, OrderDTO dto) {
        String key = "idempotent:token:" + token;

        // 原子操作：检查并删除 token
        // Lua 脚本保证原子性
        String script = "if redis.call('get', KEYS[1]) then " +
                        "  return redis.call('del', KEYS[1]) " +
                        "else " +
                        "  return 0 " +
                        "end";

        Long result = redisTemplate.execute(
            new DefaultRedisScript<>(script, Long.class),
            Collections.singletonList(key)
        );

        if (result == null || result == 0L) {
            throw new RepeatRequestException("重复请求，请勿重复提交");
        }

        // 执行业务逻辑
        return doCreateOrder(dto);
    }
}
```

---

## 三、方案二：数据库唯一约束

### 原理

利用数据库 **UNIQUE 索引**的天然幂等性：重复插入会抛出唯一约束异常，捕获异常即可。

```sql
-- 订单表设置业务唯一索引
CREATE TABLE orders (
    id         BIGINT PRIMARY KEY AUTO_INCREMENT,
    order_no   VARCHAR(64) NOT NULL COMMENT '订单号（业务唯一）',
    user_id    BIGINT      NOT NULL,
    amount     DECIMAL(10,2),
    created_at DATETIME,
    UNIQUE KEY uk_order_no (order_no)   -- 唯一索引
);
```

### 代码实现

```java
@Service
@Slf4j
public class OrderService {

    @Autowired
    private OrderMapper orderMapper;

    /**
     * 创建订单：利用唯一索引保证幂等
     * orderNo 由客户端生成（如：UUID 或 雪花ID）
     */
    public OrderResult createOrder(OrderDTO dto) {
        Order order = new Order();
        order.setOrderNo(dto.getOrderNo()); // 客户端传入的唯一订单号
        order.setUserId(dto.getUserId());
        order.setAmount(dto.getAmount());
        order.setCreatedAt(LocalDateTime.now());

        try {
            orderMapper.insert(order);
            return OrderResult.success(order.getId());
        } catch (DuplicateKeyException e) {
            // 唯一索引冲突：说明该订单已创建
            log.warn("订单已存在，orderNo={}", dto.getOrderNo());
            Order existing = orderMapper.findByOrderNo(dto.getOrderNo());
            return OrderResult.success(existing.getId()); // 返回已创建的订单ID
        }
    }
}
```

---

## 四、方案三：Redis 防重（分布式去重）

### 原理

```
首次请求：
  key = "request:" + MD5(userId + bizType + bizId)
  SET key "1" NX EX 86400  → 成功 → 处理请求 → 返回结果

重复请求：
  SET key "1" NX EX 86400  → 失败（key已存在）→ 返回"重复请求"
```

### 代码实现

```java
@Component
public class RedisIdempotentFilter {

    @Autowired
    private StringRedisTemplate redisTemplate;

    /**
     * 幂等性检查（基于业务唯一键）
     * @param bizKey 业务唯一键（如：userId+orderId的组合）
     * @param expireSeconds 防重有效期（秒）
     * @return true 首次请求，false 重复请求
     */
    public boolean tryAcquire(String bizKey, long expireSeconds) {
        String key = "idempotent:" + DigestUtils.md5DigestAsHex(bizKey.getBytes());
        Boolean success = redisTemplate.opsForValue()
            .setIfAbsent(key, "1", Duration.ofSeconds(expireSeconds));
        return Boolean.TRUE.equals(success);
    }
}

@Service
public class PaymentService {

    @Autowired
    private RedisIdempotentFilter idempotentFilter;

    public PayResult pay(PayDTO dto) {
        // 业务唯一键：userId + orderId + payChannel
        String bizKey = dto.getUserId() + ":" + dto.getOrderId() + ":" + dto.getChannel();

        if (!idempotentFilter.tryAcquire(bizKey, 3600)) {
            // 重复请求，查询并返回已有结果
            return payRepository.findByOrderId(dto.getOrderId());
        }

        // 执行支付逻辑
        return doPayment(dto);
    }
}
```

### 注意：处理失败后的回滚

```java
public PayResult pay(PayDTO dto) {
    String bizKey = dto.getUserId() + ":" + dto.getOrderId();
    
    if (!idempotentFilter.tryAcquire(bizKey, 3600)) {
        return payRepository.findByOrderId(dto.getOrderId());
    }
    
    try {
        return doPayment(dto);
    } catch (Exception e) {
        // 支付失败，删除Redis key，允许重试
        idempotentFilter.release(bizKey);
        throw e;
    }
}
```

---

## 五、方案四：乐观锁（CAS）

### 原理

通过版本号（version）控制并发修改，每次更新时 version+1，如果 version 已被修改则拒绝。

```
初始状态：version=1, status=PENDING
首次支付：UPDATE SET status=PAID, version=2 WHERE id=? AND version=1  → 成功（影响1行）
重复支付：UPDATE SET status=PAID, version=2 WHERE id=? AND version=1  → 失败（影响0行，version已是2）
```

### 代码实现

```java
// Order 实体类
@Data
@Version // MyBatis-Plus 乐观锁注解
public class Order {
    private Long id;
    private String status;
    @Version  // 版本字段
    private Integer version;
}
```

```java
@Service
public class OrderPayService {

    @Autowired
    private OrderMapper orderMapper;

    /**
     * 支付订单：使用乐观锁防止重复支付
     */
    @Transactional
    public boolean payOrder(Long orderId, Long userId) {
        Order order = orderMapper.selectById(orderId);

        if (order == null) {
            throw new OrderNotFoundException("订单不存在");
        }
        if (!OrderStatus.PENDING.equals(order.getStatus())) {
            return false; // 订单已支付或已取消
        }
        if (!order.getUserId().equals(userId)) {
            throw new UnauthorizedException("无权操作此订单");
        }

        // 乐观锁更新：带 version 条件
        int rows = orderMapper.updateStatusWithVersion(
            orderId,
            OrderStatus.PAID,
            order.getVersion()  // 使用查询到的版本号
        );

        if (rows == 0) {
            // version 已被其他请求修改，说明已支付
            throw new RepeatPayException("订单已支付，请勿重复提交");
        }

        return true;
    }
}
```

```xml
<!-- OrderMapper.xml -->
<update id="updateStatusWithVersion">
    UPDATE orders
    SET status = #{newStatus},
        version = version + 1,
        updated_at = NOW()
    WHERE id = #{orderId}
      AND version = #{version}
      AND status = 'PENDING'
</update>
```

---

## 六、方案五：状态机（有限状态机）

### 原理

```
状态流转图：

CREATED ──支付──→ PAID ──发货──→ SHIPPED ──签收──→ COMPLETED
   ↓                                                    
CANCELLED（超时/主动取消）

状态约束：
- PAID → PAID（重复支付）：不允许，直接返回"已支付"
- CANCELLED → PAID（先取消后支付）：不允许
```

### 代码实现

```java
public enum OrderStatus {
    CREATED, PAID, SHIPPED, COMPLETED, CANCELLED;

    // 定义允许的状态转换
    private static final Map<OrderStatus, Set<OrderStatus>> TRANSITIONS = Map.of(
        CREATED, Set.of(PAID, CANCELLED),
        PAID, Set.of(SHIPPED, CANCELLED),
        SHIPPED, Set.of(COMPLETED),
        COMPLETED, Set.of(),
        CANCELLED, Set.of()
    );

    public boolean canTransitionTo(OrderStatus target) {
        return TRANSITIONS.getOrDefault(this, Set.of()).contains(target);
    }
}

@Service
public class OrderStateMachineService {

    @Transactional
    public void transition(Long orderId, OrderStatus targetStatus) {
        // 加行锁（FOR UPDATE）防并发
        Order order = orderMapper.selectForUpdate(orderId);

        if (!order.getStatus().canTransitionTo(targetStatus)) {
            throw new InvalidStatusTransitionException(
                String.format("订单[%s]状态[%s]不能转换为[%s]",
                    orderId, order.getStatus(), targetStatus)
            );
        }

        // 执行状态转换
        order.setStatus(targetStatus);
        order.setUpdatedAt(LocalDateTime.now());
        orderMapper.updateById(order);
    }
}
```

---

## 七、五种方案对比

| 方案 | 实现难度 | 性能 | 适用场景 | 缺点 |
|------|---------|------|---------|------|
| Token 令牌 | 中 | 高（Redis）| 前端防重复提交 | 需要额外获取 Token 接口 |
| 数据库唯一约束 | 低 | 中 | 数据插入类场景 | 依赖数据库，高并发有锁竞争 |
| Redis 防重 | 低 | 高 | 通用防重 | Redis 故障时降级策略复杂 |
| 乐观锁 | 中 | 高 | 更新类操作 | 冲突多时重试开销大 |
| 状态机 | 高 | 中 | 复杂业务流转 | 设计复杂，需维护状态转换图 |

---

## 八、选型建议

```
业务场景决策树：

数据插入场景（创建订单/记录）？
├── 是 → 数据库唯一约束（最简单可靠）

数据更新场景（支付/状态变更）？
├── 是 → 业务状态复杂？
│         ├── 是 → 状态机
│         └── 否 → 乐观锁

前端表单防重复提交？
└── Token 令牌

通用消息消费/RPC调用防重？
└── Redis 防重（基于业务唯一键）
```

---

## 九、总结与延伸

**核心要点**：
- 幂等性是一种**设计约定**，不是单一技术——相同请求执行多次等同于执行一次
- 5 种方案各有适用场景：Token 防前端重复提交、唯一约束防数据重复插入、Redis 防重通用、乐观锁防并发修改、状态机管理复杂业务流转
- 幂等处理的核心是**唯一业务标识**的设计：由客户端生成（UUID/雪花ID）是最可靠的方案，服务端不应假设请求的唯一性
- 处理失败后的**幂等 key 回收策略**至关重要：失败应删除 key 允许重试，成功后保留 key 防重复——否则重试无法执行或成功无法去重

**延伸阅读方向**：
- 幂等注解 + AOP：封装通用 `@Idempotent` 注解，通过切面统一处理，减少业务代码侵入
- 网关层幂等：在 API Gateway（APISIX/Kong）实现请求级别去重，业务服务无感知
- 分布式事务中的幂等：Seata TCC 补偿操作、事务消息消费端都需要幂等，两者的实现差异
- gRPC 幂等语义：HTTP 方法（GET/PUT 天然幂等，POST 不幂等）与 gRPC 的幂等设计约定对比