# RabbitMQ vs Kafka vs RocketMQ 选型对比

<div class="post-meta">📅 2024-11-10 &nbsp;·&nbsp; 🏷️ <span class="tag">消息队列</span></div>

消息队列是现代分布式系统的核心基础设施，本文从架构、性能、可靠性和功能四个维度对三大主流 MQ 进行全面对比，帮助你在不同场景下做出正确选型。

---

## 一、整体架构对比

### RabbitMQ 架构

```
Producer → Exchange → Queue → Consumer
              |
         (Binding Key)
         direct / fanout / topic / headers
```

RabbitMQ 基于 AMQP 协议，核心模型是 **Exchange + Queue**。Producer 将消息发送到 Exchange，Exchange 根据路由规则将消息分发到一个或多个 Queue，Consumer 从 Queue 消费消息。

### Kafka 架构

```
Producer → Topic (Partition 0) → Consumer Group A
                (Partition 1) → Consumer Group B
                (Partition 2)

每个 Partition 对应多个 Replica（Leader + Follower）
Leader 负责读写，Follower 同步数据
```

Kafka 是一个分布式流处理平台，以 **Topic + Partition** 为核心模型，每条消息持久化到磁盘，消费者通过 offset 控制消费进度。

### RocketMQ 架构

```
Producer → NameServer (路由中心)
                ↓
           Broker Cluster
           (Master + Slave)
                ↓
           Consumer Group
```

RocketMQ 参考 Kafka 设计，引入 **NameServer** 替代 ZooKeeper，Broker 分为 Master 和 Slave，Consumer 支持 Push 和 Pull 两种模式。

---

## 二、核心特性全面对比

| 特性 | RabbitMQ | Kafka | RocketMQ |
|------|----------|-------|----------|
| **开发语言** | Erlang | Scala/Java | Java |
| **协议** | AMQP、STOMP | 自定义 TCP | 自定义协议 |
| **单机吞吐** | 万级 | 百万级 | 十万级 |
| **消息延迟** | 微秒级 | 毫秒级 | 毫秒级 |
| **消息顺序** | 不保证（单队列可保证） | Partition 内有序 | 全局/分区有序 |
| **消息可靠性** | 高（ACK + 持久化） | 高（副本机制） | 高（同步双写） |
| **消息堆积** | 较弱 | 极强（TB 级） | 强 |
| **延迟消息** | 插件支持 | 不支持 | 原生支持（18级） |
| **事务消息** | 不支持 | 支持 | 支持 |
| **死信队列** | 支持 | 不支持 | 支持 |
| **消息回溯** | 不支持 | 支持（按 offset） | 支持（按时间） |
| **消费模式** | Push | Pull | Push + Pull |
| **集群方案** | 镜像队列/Quorum | 原生分布式 | 主从/Dledger |
| **运维复杂度** | 低 | 高（依赖 ZooKeeper） | 中 |
| **社区活跃度** | 高 | 极高 | 高（阿里系） |
| **商业支持** | Pivotal/VMware | Confluent | 阿里云 |

---

## 三、性能对比详细分析

### 3.1 吞吐量

```
吞吐量排名（从高到低）：
Kafka (百万级/s) > RocketMQ (十万级/s) > RabbitMQ (万级/s)

原因分析：
- Kafka：顺序写磁盘 + 零拷贝 + 批量发送
- RocketMQ：顺序写 CommitLog + 零拷贝
- RabbitMQ：内存优先，磁盘 I/O 成为瓶颈
```

### 3.2 延迟

```
延迟排名（从低到高）：
RabbitMQ (μs级) < RocketMQ (ms级) < Kafka (ms~s级)

Kafka 延迟高的原因：批量发送机制（linger.ms）
```

### 3.3 消息堆积能力

```
堆积能力（从强到弱）：
Kafka (磁盘TB级) ≈ RocketMQ (磁盘TB级) >> RabbitMQ (内存受限)

RabbitMQ 大量堆积时性能急剧下降
```

---

## 四、可靠性机制对比

### RabbitMQ 可靠性

```java
// 生产者确认（Publisher Confirm）
channel.confirmSelect();
channel.basicPublish(exchange, routingKey, props, message.getBytes());
if (channel.waitForConfirms()) {
    System.out.println("消息发送成功");
} else {
    System.out.println("消息发送失败，需重试");
}

// 消费者手动ACK
channel.basicConsume(queue, false, (tag, delivery) -> {
    try {
        process(delivery.getBody());
        channel.basicAck(delivery.getEnvelope().getDeliveryTag(), false);
    } catch (Exception e) {
        channel.basicNack(delivery.getEnvelope().getDeliveryTag(), false, true);
    }
}, tag -> {});
```

### Kafka 可靠性

```java
// 生产者配置
Properties props = new Properties();
props.put("acks", "all");          // 等待所有副本确认
props.put("retries", 3);           // 重试次数
props.put("enable.idempotence", "true"); // 开启幂等

// 消费者手动提交 offset
consumer.subscribe(Collections.singletonList("my-topic"));
while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    for (ConsumerRecord<String, String> record : records) {
        process(record.value());
    }
    consumer.commitSync(); // 同步提交 offset
}
```

### RocketMQ 可靠性

```java
// 同步发送（最可靠）
DefaultMQProducer producer = new DefaultMQProducer("producer-group");
producer.setNamesrvAddr("localhost:9876");
producer.start();

Message msg = new Message("TopicTest", "TagA", "Hello".getBytes());
SendResult sendResult = producer.send(msg); // 同步等待 Broker 确认
System.out.println(sendResult.getSendStatus()); // SEND_OK

// Broker 同步双写配置
brokerRole=SYNC_MASTER
flushDiskType=SYNC_FLUSH
```

---

## 五、功能特性对比

### 5.1 路由灵活性

| 路由类型 | RabbitMQ | Kafka | RocketMQ |
|---------|----------|-------|----------|
| 广播 | fanout exchange | Consumer Group 隔离 | broadcast 模式 |
| 点对点 | direct exchange | 单 Consumer Group | 默认集群模式 |
| 主题匹配 | topic exchange（`*`/`#`） | 不支持 | Tag 过滤 / SQL92 |
| Header 匹配 | headers exchange | 不支持 | 不支持 |

### 5.2 延迟消息

```java
// RocketMQ 原生延迟消息（18个延迟级别）
// 1s 5s 10s 30s 1m 2m 3m 4m 5m 6m 7m 8m 9m 10m 20m 30m 1h 2h
Message msg = new Message("TopicTest", "TagA", "延迟消息".getBytes());
msg.setDelayTimeLevel(3); // 第3级 = 10s 后投递
producer.send(msg);

// RabbitMQ 延迟消息（需要插件 rabbitmq-delayed-message-exchange）
Map<String, Object> args = new HashMap<>();
args.put("x-delayed-type", "direct");
channel.exchangeDeclare("delayed-exchange", "x-delayed-message", true, false, args);

Map<String, Object> headers = new HashMap<>();
headers.put("x-delay", 10000); // 延迟 10s
AMQP.BasicProperties props = new AMQP.BasicProperties.Builder()
    .headers(headers).build();
channel.basicPublish("delayed-exchange", "routing-key", props, "延迟消息".getBytes());
```

### 5.3 事务消息（RocketMQ）

```java
TransactionMQProducer producer = new TransactionMQProducer("tx-producer-group");
producer.setTransactionListener(new TransactionListener() {
    @Override
    public LocalTransactionState executeLocalTransaction(Message msg, Object arg) {
        try {
            // 执行本地事务（如数据库操作）
            orderService.createOrder(arg);
            return LocalTransactionState.COMMIT_MESSAGE;
        } catch (Exception e) {
            return LocalTransactionState.ROLLBACK_MESSAGE;
        }
    }

    @Override
    public LocalTransactionState checkLocalTransaction(MessageExt msg) {
        // 事务回查：检查本地事务状态
        boolean committed = orderService.isOrderCreated(msg.getTransactionId());
        return committed ? LocalTransactionState.COMMIT_MESSAGE
                        : LocalTransactionState.ROLLBACK_MESSAGE;
    }
});
```

---

## 六、适用场景分析

| 场景 | 推荐 | 原因 |
|------|------|------|
| 低延迟、复杂路由 | RabbitMQ | 微秒级延迟，灵活的 Exchange 路由 |
| 大数据/日志采集 | Kafka | 百万级吞吐，消息回放，流处理生态 |
| 电商交易/订单 | RocketMQ | 事务消息、延迟消息、顺序消息原生支持 |
| 实时流计算 | Kafka | 与 Flink/Spark Streaming 无缝集成 |
| 微服务解耦 | RabbitMQ / RocketMQ | 功能完善，易于运维 |
| 秒杀/削峰填谷 | RocketMQ / Kafka | 强堆积能力 |
| IoT 消息 | RabbitMQ | 支持 MQTT 协议 |
| 金融/强一致性 | RocketMQ | 事务消息 + 同步双写 |

---

## 七、选型决策树

```
需要超高吞吐（>10万/s）？
    ├── 是 → 需要流处理生态（Flink/Spark）？
    │         ├── 是 → Kafka
    │         └── 否 → 需要延迟/事务消息？
    │                   ├── 是 → RocketMQ
    │                   └── 否 → Kafka / RocketMQ
    └── 否 → 需要复杂路由（topic/fanout/headers）？
              ├── 是 → RabbitMQ
              └── 否 → 团队是Java系？
                        ├── 是 → RocketMQ
                        └── 否 → RabbitMQ
```

---

## 八、快速对比总结

| 维度 | RabbitMQ | Kafka | RocketMQ |
|------|----------|-------|----------|
| **首选场景** | 复杂路由、低延迟 | 大数据、日志 | 电商、金融 |
| **吞吐量** | ⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| **延迟** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| **可靠性** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **功能丰富** | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **运维难度** | 低 | 高 | 中 |
| **国内社区** | 一般 | 活跃 | 非常活跃 |

---

## 九、常见坑点与最佳实践

1. **RabbitMQ 内存告警导致阻塞**：消息积压超过内存阈值（默认 40%）时触发 flow control，生产者被阻塞——必须配置死信队列（DLX）+ TTL，并监控队列深度
2. **Kafka Rebalance 风暴**：Consumer 频繁 Rebalance 导致大量重复消费——增大 `max.poll.interval.ms`，减少 `max.poll.records`，或使用静态组成员（`group.instance.id`）
3. **Kafka 分区数难扩展**：分区数增加后 key hash 分布改变，消息顺序性被破坏——提前按"峰值TPS ÷ 单分区吞吐"规划分区数
4. **RocketMQ NameServer 单点**：生产环境至少部署 2 个 NameServer，客户端轮询连接，单个故障不影响路由查询
5. **死信队列无人处理**：消费失败消息进入 DLQ 后若无监控重发机制，业务数据将永久丢失——必须监控 DLQ 告警并建立人工重发流程

---

## 十、总结与延伸

**核心要点**：
- **RabbitMQ**：路由灵活，延迟最低（微秒级），适合复杂路由和低延迟场景；消息堆积能力弱是主要短板
- **Kafka**：吞吐极高（百万/s），持久化消息支持回放，是大数据和日志收集的首选；功能相对简单
- **RocketMQ**：功能最全（延迟消息、事务消息、顺序消息），国内生态最好，适合电商/金融核心链路
- 选型核心：**场景驱动而非技术驱动**，不是"哪个最好"而是"哪个最适合当前业务需求"

**延伸阅读方向**：
- Apache Pulsar：存算分离架构的新一代消息队列，兼顾 Kafka 的吞吐和 RabbitMQ 的功能特性
- 消息队列监控：Kafka Manager/AKHQ、RocketMQ Dashboard、RabbitMQ Management UI 的核心监控指标
- 消息追踪链路：SkyWalking 与消息队列集成，实现跨服务的端到端消息追踪
- 云原生消息服务：阿里云 ONS、腾讯云 CMQ 与自建 MQ 的成本和运维对比