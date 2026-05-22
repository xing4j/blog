# RocketMQ 延迟消息与事务消息实战

<div class="post-meta">📅 2025-06-12 &nbsp;·&nbsp; 🏷️ <span class="tag">RocketMQ</span></div>

RocketMQ 在普通消息基础上提供了两个强大的特性：延迟消息和事务消息。前者解决定时任务场景，后者解决分布式事务的最终一致性问题。本文深入分析原理并给出 Spring Boot 集成实战代码。

---

## 一、延迟消息原理

### 1.1 18个延迟级别

RocketMQ 不支持任意时间的延迟，而是预设了 **18 个固定延迟级别**：

```
delayLevel → 延迟时间
1  → 1s
2  → 5s
3  → 10s
4  → 30s
5  → 1min
6  → 2min
7  → 3min
8  → 4min
9  → 5min
10 → 6min
11 → 7min
12 → 8min
13 → 9min
14 → 10min
15 → 20min
16 → 30min
17 → 1h
18 → 2h
```

在 `broker.conf` 中可以自定义延迟级别：

```properties
# 自定义延迟级别（覆盖默认配置）
messageDelayLevel=1s 5s 10s 30s 1m 2m 3m 4m 5m 6m 7m 8m 9m 10m 20m 30m 1h 2h
```

### 1.2 延迟消息内部原理

```
Producer 发送延迟消息
         ↓
Broker 收到消息，检测到 delayLevel > 0
         ↓
将消息存入内部 Topic：SCHEDULE_TOPIC_XXXX
（Partition = delayLevel - 1）
         ↓
ScheduleMessageService 定时扫描
（每秒检查各延迟 Topic 的消息是否到期）
         ↓
到期后，将消息转存回原始 Topic
         ↓
Consumer 正常消费原始 Topic
```

```
时间轴：
t=0    消息到达 SCHEDULE_TOPIC_XXXX（Partition 2 = Level3 = 10s）
       保存原始 Topic 到消息属性
t=10s  ScheduleMessageService 扫描到期消息
t=10s  消息被投递到原始 Topic
t=10s  Consumer 开始消费
```

---

## 二、延迟消息实战

### 2.1 原生 API

```java
import org.apache.rocketmq.client.producer.DefaultMQProducer;
import org.apache.rocketmq.common.message.Message;

public class DelayProducerExample {
    
    public static void main(String[] args) throws Exception {
        DefaultMQProducer producer = new DefaultMQProducer("delay-producer-group");
        producer.setNamesrvAddr("localhost:9876");
        producer.start();
        
        // 发送30s后投递的消息（Level 4）
        Message msg = new Message(
            "OrderTopic",       // Topic
            "DelayTag",         // Tag
            "ORDER_001",        // Key（业务唯一ID，便于追踪）
            "订单超时提醒".getBytes(StandardCharsets.UTF_8)
        );
        msg.setDelayTimeLevel(4); // Level 4 = 30s
        
        SendResult result = producer.send(msg);
        System.out.println("发送结果：" + result.getSendStatus());
        System.out.println("MessageId：" + result.getMsgId());
        
        producer.shutdown();
    }
}
```

### 2.2 Spring Boot 集成（RocketMQ Spring Starter）

**pom.xml 依赖：**

```xml
<dependency>
    <groupId>org.apache.rocketmq</groupId>
    <artifactId>rocketmq-spring-boot-starter</artifactId>
    <version>2.2.3</version>
</dependency>
```

**application.yml 配置：**

```yaml
rocketmq:
  name-server: localhost:9876
  producer:
    group: my-producer-group
    send-message-timeout: 3000
    retry-times-when-send-failed: 2
  consumer:
    group: my-consumer-group
```

**发送延迟消息：**

```java
@Service
public class OrderService {
    
    @Autowired
    private RocketMQTemplate rocketMQTemplate;
    
    /**
     * 创建订单时，发送30分钟超时取消延迟消息
     */
    public void createOrder(Order order) {
        // 1. 创建订单
        orderRepository.save(order);
        
        // 2. 发送延迟消息（Level 16 = 30min）
        Message<String> message = MessageBuilder
            .withPayload(order.getOrderId())
            .setHeader("KEYS", order.getOrderId()) // 消息 Key，便于追踪
            .build();
        
        rocketMQTemplate.syncSend(
            "order-timeout-topic:TimeoutTag", // topic:tag
            message,
            3000,  // 超时时间ms
            16     // delayLevel = 30min
        );
        
        log.info("订单创建成功，已发送超时检查消息，orderId={}", order.getOrderId());
    }
}
```

**消费延迟消息：**

```java
@Component
@RocketMQMessageListener(
    topic = "order-timeout-topic",
    selectorExpression = "TimeoutTag",
    consumerGroup = "order-timeout-consumer-group"
)
public class OrderTimeoutConsumer implements RocketMQListener<String> {
    
    @Autowired
    private OrderService orderService;
    
    @Override
    public void onMessage(String orderId) {
        log.info("收到订单超时检查消息，orderId={}", orderId);
        
        Order order = orderService.findById(orderId);
        if (order == null) {
            log.warn("订单不存在，可能已删除，orderId={}", orderId);
            return;
        }
        
        if (order.getStatus() == OrderStatus.PENDING) {
            // 订单仍未支付，执行取消
            orderService.cancelOrder(orderId, "超时自动取消");
            log.info("订单超时取消，orderId={}", orderId);
        } else {
            log.info("订单已完成支付，无需取消，orderId={}", orderId);
        }
    }
}
```

---

## 三、事务消息原理

### 3.1 两阶段提交流程

```
                    ┌─────────────────────────────────────────┐
                    │              事务消息流程                  │
                    └─────────────────────────────────────────┘
                    
Step 1: Producer 发送 Half Message（半消息）
Producer ──────────────────────────────→ Broker
        "我要发消息，但先别投递给Consumer"
        
Step 2: Broker 存储半消息，返回 ACK
Broker ─────────────────────────────────→ Producer
       "好的，半消息已收到"

Step 3: Producer 执行本地事务
Producer: 执行数据库操作（扣减库存/创建订单...）
        
Step 4: Producer 发送本地事务结果
Producer ──────────────────────────────→ Broker
         COMMIT（提交）或 ROLLBACK（回滚）
         
Step 5a: COMMIT → Broker 投递消息给 Consumer
Step 5b: ROLLBACK → Broker 删除半消息

Step 6: 如果 Producer 未响应（宕机/超时）
Broker ─────────────────────────────────→ Producer
       发起事务回查（checkLocalTransaction）
```

### 3.2 半消息存储机制

```
正常 Topic：
  TopicA/queue0
  TopicA/queue1

事务半消息存储在特殊 Topic：
  RMQ_SYS_TRANS_HALF_TOPIC/queue0  ← 半消息存这里

提交后，消息从半消息 Topic 转移到原始 Topic：
  TopicA/queue0  ← 消息真正可被消费
```

---

## 四、事务消息实战

### 4.1 原生 API 事务消息

```java
import org.apache.rocketmq.client.producer.TransactionMQProducer;
import org.apache.rocketmq.client.producer.TransactionListener;

public class TransactionProducerExample {

    public static void main(String[] args) throws Exception {
        TransactionMQProducer producer = new TransactionMQProducer("tx-producer-group");
        producer.setNamesrvAddr("localhost:9876");
        
        // 回查线程池（建议使用独立线程池）
        ExecutorService executorService = new ThreadPoolExecutor(
            2, 5, 100, TimeUnit.SECONDS,
            new ArrayBlockingQueue<>(2000),
            r -> new Thread(r, "check-thread")
        );
        producer.setExecutorService(executorService);
        
        // 设置事务监听器
        producer.setTransactionListener(new TransactionListener() {
            
            /**
             * 执行本地事务（Half Message 发送成功后回调）
             */
            @Override
            public LocalTransactionState executeLocalTransaction(Message msg, Object arg) {
                String orderId = new String(msg.getBody());
                log.info("执行本地事务，orderId={}", orderId);
                
                try {
                    // 执行数据库操作
                    orderDAO.insert(new Order(orderId));
                    inventoryDAO.decrease(orderId, 1);
                    return LocalTransactionState.COMMIT_MESSAGE; // 本地事务成功，提交
                } catch (Exception e) {
                    log.error("本地事务执行失败", e);
                    return LocalTransactionState.ROLLBACK_MESSAGE; // 本地事务失败，回滚
                }
            }
            
            /**
             * 事务回查（Broker 15s 后未收到确认，发起回查，最多回查15次）
             */
            @Override
            public LocalTransactionState checkLocalTransaction(MessageExt msg) {
                String orderId = new String(msg.getBody());
                log.info("事务回查，orderId={}", orderId);
                
                // 检查本地事务是否已执行
                Order order = orderDAO.findById(orderId);
                if (order != null) {
                    return LocalTransactionState.COMMIT_MESSAGE;
                } else {
                    return LocalTransactionState.UNKNOW; // 未知，继续等待回查
                }
            }
        });
        
        producer.start();
        
        // 发送事务消息
        Message msg = new Message("OrderTopic", "OrderTag", 
            "ORDER_001".getBytes(StandardCharsets.UTF_8));
        TransactionSendResult result = producer.sendMessageInTransaction(msg, null);
        System.out.println("发送结果：" + result.getLocalTransactionState());
        
        Thread.sleep(10000); // 等待回查
        producer.shutdown();
    }
}
```

### 4.2 Spring Boot 集成事务消息

```java
@Service
public class OrderTransactionService {
    
    @Autowired
    private RocketMQTemplate rocketMQTemplate;
    
    /**
     * 下单接口：通过事务消息保证订单创建与消息发送的原子性
     */
    public void placeOrder(OrderDTO orderDTO) {
        Message<OrderDTO> message = MessageBuilder
            .withPayload(orderDTO)
            .setHeader(RocketMQHeaders.KEYS, orderDTO.getOrderId())
            .build();
        
        // 发送事务消息
        TransactionSendResult result = rocketMQTemplate.sendMessageInTransaction(
            "order-topic",
            message,
            orderDTO  // arg，传递给 executeLocalTransaction
        );
        
        if (result.getLocalTransactionState() != LocalTransactionState.COMMIT_MESSAGE) {
            throw new RuntimeException("下单失败，事务未提交");
        }
    }
}

/**
 * 事务监听器
 */
@Component
@RocketMQTransactionListener
public class OrderTransactionListener implements RocketMQLocalTransactionListener {
    
    @Autowired
    private OrderRepository orderRepository;
    
    @Autowired
    private TransactionLogRepository txLogRepository;
    
    @Override
    @Transactional
    public RocketMQLocalTransactionState executeLocalTransaction(
            Message msg, Object arg) {
        OrderDTO orderDTO = (OrderDTO) arg;
        try {
            // 1. 创建订单
            Order order = Order.from(orderDTO);
            orderRepository.save(order);
            
            // 2. 记录事务日志（用于回查）
            TransactionLog log = new TransactionLog(
                orderDTO.getOrderId(), 
                TransactionStatus.COMMITTED
            );
            txLogRepository.save(log);
            
            return RocketMQLocalTransactionState.COMMIT;
        } catch (Exception e) {
            log.error("本地事务执行失败，orderId={}", orderDTO.getOrderId(), e);
            return RocketMQLocalTransactionState.ROLLBACK;
        }
    }
    
    @Override
    public RocketMQLocalTransactionState checkLocalTransaction(Message msg) {
        String orderId = (String) msg.getHeaders().get(RocketMQHeaders.KEYS);
        
        TransactionLog txLog = txLogRepository.findByOrderId(orderId);
        if (txLog == null) {
            return RocketMQLocalTransactionState.UNKNOWN; // 继续等待
        }
        
        return txLog.getStatus() == TransactionStatus.COMMITTED
            ? RocketMQLocalTransactionState.COMMIT
            : RocketMQLocalTransactionState.ROLLBACK;
    }
}
```

---

## 五、对比与选型

| 特性 | 延迟消息 | 事务消息 |
|------|---------|---------|
| **用途** | 定时任务/超时处理 | 分布式事务一致性 |
| **原理** | 内部延迟 Topic 中转 | 两阶段提交+回查 |
| **精确度** | 固定18级，秒级误差 | 实时发送 |
| **回查机制** | 无 | 有（最多15次） |
| **适用场景** | 订单超时、定时提醒 | 跨服务数据一致性 |
| **代码复杂度** | 低 | 中 |

---

## 六、注意事项

| 注意点 | 说明 |
|--------|------|
| 延迟精度 | 延迟消息存在约 1s 的误差，不适合精确毫秒级场景 |
| 事务回查 | 回查接口必须实现，且必须是幂等的 |
| 半消息上限 | 单个消息体不超过 4MB |
| 回滚不删库 | 事务 ROLLBACK 不会删除已写入数据库的数据 |
| 事务回查次数 | 默认最多 15 次，超过后丢弃（需人工介入） |
| Broker 配置 | 事务消息需要 Broker 开启事务功能（默认开启） |

---

## 七、总结与延伸

**核心要点**：
- **延迟消息**：通过内置 SCHEDULE_TOPIC_XXXX 中转实现，精度约 1s，适合订单超时、定时提醒等场景；RocketMQ 5.x 支持基于 TimerWheel 的任意时间精度延迟
- **事务消息**：两阶段提交（Half Message + Commit/Rollback）+ Broker 主动回查机制，解决本地事务和消息发送的原子性问题
- 事务监听器的 `executeLocalTransaction` 和 `checkLocalTransaction` 必须是**幂等**操作，避免重复执行导致数据错误
- 事务回查上限默认 15 次，超出后消息丢弃——生产必须监控 `RMQ_SYS_TRANS_HALF_TOPIC` 的残留消息并建立告警

**延伸阅读方向**：
- RocketMQ 5.x 新特性：Pop 消费模式（无状态消费）、任意时间延迟消息的 TimerWheel 实现原理
- 分布式事务选型：事务消息（最终一致性）vs Seata TCC（强一致性）vs SAGA（长事务）的对比与取舍
- 消息幂等与事务消息配合：如何在消费端实现 Exactly Once 语义，避免重复消费带来的业务副作用
- 阿里云消息服务 RocketMQ 版：云托管的自动运维、弹性扩缩容，以及与本地部署的功能差异