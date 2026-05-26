# Kafka 事务消息与 Exactly-Once 语义

> 📚 **本文属于「Kafka 原理与生产实战」系列**
> - [K-01 Kafka 核心概念与快速上手](2026-05-24-kafka-quickstart.md)
> - [K-02 Kafka 整体架构深度解析](2026-05-24-kafka-architecture.md)
> - [K-03 Producer 原理与最佳实践](2026-05-24-kafka-producer.md)
> - [K-04 Consumer 原理与 Rebalance 治理](2026-05-24-kafka-consumer-rebalance.md)
> - [K-05 存储机制：Log 文件与索引详解](2026-05-24-kafka-storage.md)
> - [K-06 高可用：副本同步与 Leader 选举](2026-05-24-kafka-ha-replica.md)
> - [K-07 吞吐量调优实战](2026-05-24-kafka-throughput-tuning.md)
> - [K-08 消费延迟监控与 Lag 治理](2026-05-24-kafka-consumer-lag.md)
> - 👉 **K-09 事务消息与 Exactly-Once 语义（本文）**
> - [K-10 KRaft 模式：去 ZooKeeper 实战](2026-05-24-kafka-kraft.md)

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 30 分钟｜**分类**：中间件

---

## 导读

消息不丢（At-least-once）几乎每个团队都能做到，但消息不重复（Exactly-once）却是分布式系统中最难解决的问题之一。Kafka 从 0.11 版本开始提供原生的 Exactly-Once 语义，背后涉及幂等 Producer、事务 Producer、Transaction Coordinator 三层机制。本文深入剖析这套机制的实现原理，并与 RocketMQ 事务消息进行对比，帮你做出正确的技术选型。

---

## 一、消费语义回顾

### 1.1 三种消费语义

| 语义 | 含义 | 实现方式 | 使用场景 |
|------|------|---------|---------|
| At-most-once | 消息最多被处理一次，可能丢失 | 先提交 Offset，再处理 | 日志收集，允许少量丢失 |
| At-least-once | 消息至少被处理一次，可能重复 | 先处理，再提交 Offset | 多数业务场景 |
| Exactly-once | 消息精确被处理一次，不丢不重 | 事务机制 | 金融转账、库存扣减等 |

### 1.2 At-least-once 为什么会重复

```
① Consumer 拉取并处理 msg1 ~ msg100
② 提交 Offset 前，Consumer 宕机重启
③ 重启后从上次提交的 Offset（msg1）重新消费
④ msg1 ~ msg100 被重复处理
```

---

## 二、幂等 Producer（单 Partition Exactly-Once）

### 2.1 原理

幂等 Producer（Idempotent Producer）通过 `<PID, PartitionID, SequenceNumber>` 三元组识别重复消息：

```
Producer 启动时，向 Broker 申请唯一的 PID（Producer ID）

每条消息携带：
  PID:            Producer 的唯一 ID（重启后变更）
  PartitionID:    目标分区
  SequenceNumber: 分区级别的单调递增序列号

Broker 端维护：
  Map<(PID, PartitionID), maxSequenceNumber>
  收到消息时：
    若 SequenceNumber = maxSequenceNumber + 1 → 正常写入
    若 SequenceNumber ≤ maxSequenceNumber    → 重复消息，丢弃
    若 SequenceNumber > maxSequenceNumber + 1 → 消息乱序，拒绝并报错
```

### 2.2 局限性

幂等 Producer 仅保证：
- **单 Partition** 内的 Exactly-once（跨 Partition 无保证）
- **单 Session** 内的 Exactly-once（Producer 重启后 PID 变更，保证断裂）

```java
// JDK 17 + kafka-clients 3.7.0 —— 开启幂等 Producer（Kafka 3.0+ 默认开启）
Properties props = new Properties();
props.put("enable.idempotence", "true");  // 开启幂等性
// 自动设置：acks=all, retries=Integer.MAX_VALUE, max.in.flight.requests.per.connection=5
```

---

## 三、事务 Producer（跨 Partition Exactly-Once）

### 3.1 事务 Producer 的适用场景

跨多个 Partition（或多个 Topic）的原子性写入：

```
场景：Kafka Streams 处理任务
  读取 Topic-A 的消息 → 处理 → 写入 Topic-B
  同时提交 Consumer Offset（写入 __consumer_offsets）

原子性要求：
  ① Topic-B 的消息写入
  ② Consumer Offset 的提交
  这两步必须原子完成，否则要么重复处理，要么丢数据
```

### 3.2 核心组件：Transaction Coordinator

Transaction Coordinator（事务协调器）是 Broker 内的一个组件，每个事务 Producer 对应一个固定的 Coordinator（由 `transactional.id` hash 决定）。

事务状态存储在内部 Topic `__transaction_state`（50 个分区）中。

### 3.3 事务消息两阶段提交流程

```
① 事务初始化
   Producer → Coordinator: initTransactions(transactional.id)
   Coordinator → Producer: 返回 PID + producerEpoch

② 开启事务
   Producer: beginTransaction()（本地标记，无网络请求）

③ 发送消息（多 Partition）
   Producer → Broker-A: 发送 msg 到 TopicB-P0（标记为事务消息）
   Producer → Coordinator: AddPartitionsToTxn（登记参与事务的分区）
   Producer → Broker-B: 发送 msg 到 TopicB-P1（标记为事务消息）

④ 提交 Offset（可选，Kafka Streams 场景）
   Producer → Coordinator: sendOffsetsToTransaction(offsets, groupId)
   Coordinator → GroupCoordinator: 写入 offset 到 __consumer_offsets（标记为事务消息）

⑤ 提交事务
   Producer → Coordinator: commitTransaction()
   Coordinator 向所有参与分区的 Broker 发送 WriteTxnMarkers（COMMIT 标记）
   各 Broker 写入 COMMIT 标记后，事务消息对 Consumer 可见

⑥ （或）回滚事务
   Producer → Coordinator: abortTransaction()
   Coordinator 向所有参与 Broker 发送 WriteTxnMarkers（ABORT 标记）
   各 Broker 写入 ABORT 标记，事务消息对 Consumer 永不可见
```

### 3.4 代码示例

```java
// JDK 17 + kafka-clients 3.7.0 —— 事务 Producer 完整示例
public class TransactionalProducerDemo {

    public static void main(String[] args) {
        Properties props = new Properties();
        props.put("bootstrap.servers", "localhost:9092");
        props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        props.put("transactional.id", "order-service-tx-1");  // 全局唯一的事务 ID
        props.put("acks", "all");  // 事务 Producer 强制要求 acks=all

        KafkaProducer<String, String> producer = new KafkaProducer<>(props);
        producer.initTransactions();  // 初始化事务，向 Coordinator 注册

        try {
            producer.beginTransaction();  // 开启事务

            // 原子性地向多个 Topic/Partition 写入
            producer.send(new ProducerRecord<>("inventory-reduced", "ORDER-1", "{\"sku\":\"A001\",\"qty\":1}"));
            producer.send(new ProducerRecord<>("order-confirmed", "ORDER-1", "{\"status\":\"confirmed\"}"));
            producer.send(new ProducerRecord<>("notification-queue", "ORDER-1", "{\"type\":\"sms\",\"msg\":\"订单确认\"}"));

            producer.commitTransaction();  // 提交事务：以上三条消息原子可见

        } catch (ProducerFencedException e) {
            // 相同 transactional.id 的新 Producer 启动，旧 Producer 被 Fence，不可恢复
            producer.close();
        } catch (KafkaException e) {
            producer.abortTransaction();   // 回滚：以上三条消息对 Consumer 不可见
        } finally {
            producer.close();
        }
    }
}
```

### 3.5 Consumer 端：隔离级别

事务消息对 Consumer 是否可见，取决于 `isolation.level` 配置：

| isolation.level | 行为 |
|----------------|------|
| `read_uncommitted`（默认）| 可见所有消息，包括未提交事务的消息 |
| `read_committed` | 只可见已提交事务的消息（以及非事务消息）|

```java
// JDK 17 + kafka-clients 3.7.0 —— Consumer 配置事务隔离级别
props.put("isolation.level", "read_committed");  // 只消费已提交事务的消息
```

---

## 四、Kafka 事务 vs RocketMQ 事务消息

两种框架实现事务消息的思路有本质区别：

| 维度 | Kafka 事务 | RocketMQ 事务消息 |
|------|-----------|----------------|
| **核心目标** | Kafka 内部多 Partition 原子写入（流处理场景）| 本地事务与消息发送的原子性（业务场景）|
| **实现机制** | 两阶段提交，Coordinator 协调 | Half 消息 + 本地事务 + 回查机制 |
| **适用场景** | Kafka Streams 处理链路的 EOS | 订单支付后发消息、扣库存后发通知 |
| **跨系统事务** | ❌ 不支持（仅限 Kafka 内部）| ✅ 支持（本地 DB + MQ 的原子性）|
| **性能开销** | 中等（约降低 40% 吞吐量）| 中等（半消息 + 回查增加 RTT）|
| **消息回查** | ❌ 不需要 | ✅ Broker 定时回查本地事务状态 |

**选型建议**：
- Kafka Streams 流处理，且需要端到端 EOS → Kafka 事务
- 业务系统中本地 DB 操作与 MQ 发送需要保持原子性 → RocketMQ 事务消息（或本地消息表方案）
- 多数业务场景 → At-least-once + 业务幂等，性价比最高

> RocketMQ 事务消息详解参见：[RocketMQ 延迟消息与事务消息原理](2025-06-12-rocketmq-delay-transaction.md)

---

## 五、踩坑总结

❌ **用同一个 `transactional.id` 启动多个 Producer 实例**  
✅ `transactional.id` 标识一个逻辑 Producer，相同 ID 启动新实例时，Coordinator 会对旧实例发送 `Fence` 信号，旧实例后续操作全部失败。生产中每个部署实例应有唯一的 `transactional.id`（如加入 hostname 后缀），或确保同一时刻只有一个实例在运行。

❌ **Consumer 设置 `isolation.level=read_uncommitted`（默认），消费到了事务回滚的消息**  
✅ 如果业务依赖事务保证，Consumer 端必须显式配置 `isolation.level=read_committed`。默认值 `read_uncommitted` 会读取所有消息，包括最终被回滚的事务消息，导致业务处理了不该处理的数据。

---

## 六、文章小结

- 幂等 Producer 通过 `<PID, PartitionID, SequenceNumber>` 去重，仅保证单 Partition、单 Session 的 Exactly-once
- 事务 Producer + Transaction Coordinator 通过两阶段提交实现跨 Partition 原子写入
- Consumer 端需显式配置 `isolation.level=read_committed` 才能过滤未提交事务的消息
- Kafka 事务针对流处理场景（Kafka 内部），RocketMQ 事务针对本地事务与 MQ 发送的原子性（业务场景）
- 多数业务选 At-least-once + 业务幂等即可，Exactly-once 的吞吐量代价约 40%，使用前需权衡

---

## 七、思考题

1. `transactional.id` 相同的新旧 Producer 实例并存时，`ProducerFencedException` 具体在哪一步抛出？Coordinator 是如何实现 Fencing 的？

2. Kafka 事务的两阶段提交中，如果 Coordinator 在第五步（发送 WriteTxnMarkers）时宕机，事务处于什么状态？Kafka 如何保证最终一致性？

---

## 参考资料

> 1. [Apache Kafka 官方文档 3.7 - Transactions](https://kafka.apache.org/37/documentation/#transactions)
> 2. [KIP-98: Exactly Once Delivery and Transactional Messaging](https://cwiki.apache.org/confluence/display/KAFKA/KIP-98+-+Exactly+Once+Delivery+and+Transactional+Messaging)
> 3. [Transactions in Apache Kafka](https://www.confluent.io/blog/transactions-apache-kafka/) — Confluent Blog
> 4. [RocketMQ 延迟消息与事务消息原理](2025-06-12-rocketmq-delay-transaction.md)
> 5. [K-03 Producer 原理与最佳实践](2026-05-24-kafka-producer.md)
