# Kafka 核心概念与快速上手

> 📚 **本文属于「Kafka 原理与生产实战」系列**
> - 👉 **K-01 Kafka 核心概念与快速上手（本文）**
> - [K-02 Kafka 整体架构深度解析](2026-05-24-kafka-architecture.md)
> - [K-03 Producer 原理与最佳实践](2026-05-24-kafka-producer.md)
> - [K-04 Consumer 原理与 Rebalance 治理](2026-05-24-kafka-consumer-rebalance.md)
> - [K-05 存储机制：Log 文件与索引详解](2026-05-24-kafka-storage.md)
> - [K-06 高可用：副本同步与 Leader 选举](2026-05-24-kafka-ha-replica.md)
> - [K-07 吞吐量调优实战](2026-05-24-kafka-throughput-tuning.md)
> - [K-08 消费延迟监控与 Lag 治理](2026-05-24-kafka-consumer-lag.md)
> - [K-09 事务消息与 Exactly-Once 语义](2026-05-24-kafka-exactly-once.md)
> - [K-10 KRaft 模式：去 ZooKeeper 实战](2026-05-24-kafka-kraft.md)

**深度等级**：⭐ 入门｜**阅读时长**：约 15 分钟｜**分类**：中间件

---

## 导读

在微服务架构中，服务间异步解耦几乎是标配需求。本文带你从零认识 Kafka：它是什么、解决什么问题、7 个核心概念如何理解，并通过完整 Java 示例完成第一次消息收发。读完本文，你将建立起 Kafka 的基本认知框架，为后续深入学习打下基础。

---

## 一、为什么需要 Kafka

### 1.1 同步调用的三大痛点

订单服务完成后需要通知库存服务、积分服务、短信服务，如果全部同步调用：

- **强耦合**：任意下游宕机，主链路立即失败
- **性能拖累**：主流程要等所有下游返回才能响应用户
- **流量无法削峰**：秒杀 10 万 QPS 直接打穿下游数据库

引入 Kafka 后，订单服务只管写一条消息，下游各自异步消费，彻底解耦：

```
订单服务 ──写消息──► Kafka Topic
                        ├──► 库存服务（异步消费）
                        ├──► 积分服务（异步消费）
                        └──► 短信服务（异步消费）
```

### 1.2 Kafka 的核心定位

Kafka 由 LinkedIn 于 2011 年开源，现归属 Apache 基金会，定位是**高吞吐、持久化、可回溯的分布式消息流平台**。单集群吞吐量可达百万级 TPS，消息默认落盘保存，支持按时间或 Offset 回溯消费——这是它区别于 RabbitMQ、RocketMQ 的最大特点。

> 与其他消息队列的横向对比参见：[消息队列选型：Kafka vs RocketMQ vs RabbitMQ](2024-11-10-mq-comparison.md)

---

## 二、7 个核心概念

理解 Kafka 只需掌握这 7 个术语，它们构成了整个体系的骨架：

```
Producer → Topic（Partition 0/1/2） → Broker 集群
                                           ↓ 持久化
Consumer Group → Consumer ←─ 按 Offset 拉取
```

### 2.1 Topic（主题）

Topic 是消息的**逻辑分类**，类似数据库中的表名。一个系统可以有多个 Topic：

- `order-created`：订单创建事件
- `order-paid`：订单支付事件
- `inventory-reduced`：库存扣减事件

### 2.2 Partition（分区）

每个 Topic 由若干个 Partition 组成，Partition 是 Kafka **并行度和吞吐量**的核心设计。

```
Topic: order-created（3 个分区）
  ├── Partition 0: [msg0][msg3][msg6]...
  ├── Partition 1: [msg1][msg4][msg7]...
  └── Partition 2: [msg2][msg5][msg8]...
```

**关键特性**：分区内消息**严格有序**，分区间**无序**。分区可以分散在不同 Broker 上，实现负载均衡和水平扩展。

### 2.3 Offset（偏移量）

每条消息在 Partition 内有唯一递增的编号，称为 Offset。消费者通过记录 Offset 标记"消费到哪里了"，支持**消息回溯**（重新消费某个时间点之后的消息）。

```
Partition 0: [offset=0][offset=1][offset=2][offset=3]...
                                              ↑
                                    消费者当前消费到这里
```

### 2.4 Broker

Kafka 服务节点称为 Broker。生产环境通常 3 个以上 Broker 组成集群，提供高可用和负载分担。

### 2.5 Producer（生产者）

向 Topic 写入消息的客户端。Producer 可以指定消息发往哪个 Partition，也可以由 Kafka 按策略自动分配（轮询 / 哈希 Key / Sticky）。

### 2.6 Consumer（消费者）

从 Topic 拉取消息的客户端。Kafka 采用 **Pull 模型**（消费者主动拉取），而非 RabbitMQ 的 Push 模型，这让消费者可以按自己的节奏处理消息，不会被压垮。

### 2.7 Consumer Group（消费组）

消费者的逻辑分组，是 Kafka 实现水平扩展的关键设计：

- **同一 Group 内**：每个 Partition 只被组内一个消费者消费（点对点）
- **不同 Group 间**：相互独立，同一消息被各 Group 独立消费（广播）

```
Topic: order-created（3 分区）

Group A（订单处理组）：             Group B（数据分析组）：
  Consumer-1 → Partition 0           Consumer-1 → Partition 0
  Consumer-2 → Partition 1                      → Partition 1
  Consumer-3 → Partition 2                      → Partition 2
```

---

## 三、快速上手：Docker 部署 + Java 示例

### 3.1 Docker Compose 单机部署

```yaml
# docker-compose.yml  Kafka 3.7（KRaft 模式，无需 ZooKeeper）
version: '3.8'
services:
  kafka:
    image: apache/kafka:3.7.0
    container_name: kafka
    ports:
      - "9092:9092"
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
```

```shell
# 启动
docker-compose up -d

# 创建 Topic（3 分区，1 副本）
docker exec kafka /opt/kafka/bin/kafka-topics.sh \
  --create \
  --topic order-created \
  --partitions 3 \
  --replication-factor 1 \
  --bootstrap-server localhost:9092

# 验证
docker exec kafka /opt/kafka/bin/kafka-topics.sh \
  --describe --topic order-created --bootstrap-server localhost:9092
```

### 3.2 Maven 依赖

```xml
<!-- kafka-clients 3.7.0，适用 JDK 11+ -->
<dependency>
    <groupId>org.apache.kafka</groupId>
    <artifactId>kafka-clients</artifactId>
    <version>3.7.0</version>
</dependency>
```

### 3.3 生产者示例

```java
// JDK 17 + kafka-clients 3.7.0
import org.apache.kafka.clients.producer.*;
import java.util.Properties;
import java.util.concurrent.ExecutionException;

public class OrderProducer {

    public static void main(String[] args) throws ExecutionException, InterruptedException {
        Properties props = new Properties();
        props.put("bootstrap.servers", "localhost:9092");  // Broker 地址
        props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        props.put("acks", "all");    // 等待所有副本写入才确认，可靠性最高
        props.put("retries", 3);     // 发送失败自动重试 3 次

        try (KafkaProducer<String, String> producer = new KafkaProducer<>(props)) {
            for (int i = 1; i <= 5; i++) {
                String orderId = "ORDER-" + i;
                String payload = String.format("{\"orderId\":\"%s\",\"amount\":100}", orderId);

                // key=orderId：相同 key 的消息路由到同一分区，保证同一订单的事件有序
                ProducerRecord<String, String> record =
                    new ProducerRecord<>("order-created", orderId, payload);

                RecordMetadata meta = producer.send(record).get();  // 同步发送，等待结果
                System.out.printf("发送成功 → partition=%d, offset=%d%n",
                    meta.partition(), meta.offset());
            }
        }
    }
}
```

### 3.4 消费者示例

```java
// JDK 17 + kafka-clients 3.7.0
import org.apache.kafka.clients.consumer.*;
import java.time.Duration;
import java.util.Collections;
import java.util.Properties;

public class OrderConsumer {

    public static void main(String[] args) {
        Properties props = new Properties();
        props.put("bootstrap.servers", "localhost:9092");
        props.put("group.id", "order-processing-group");  // 消费组 ID，同组消费者共同消费
        props.put("key.deserializer", "org.apache.kafka.common.serialization.StringDeserializer");
        props.put("value.deserializer", "org.apache.kafka.common.serialization.StringDeserializer");
        props.put("auto.offset.reset", "earliest");  // 首次消费从最早消息开始
        props.put("enable.auto.commit", "false");    // 关闭自动提交，手动控制避免消息丢失

        try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props)) {
            consumer.subscribe(Collections.singletonList("order-created"));

            while (true) {
                ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));

                for (ConsumerRecord<String, String> record : records) {
                    System.out.printf("收到消息 → partition=%d, offset=%d, key=%s%n",
                        record.partition(), record.offset(), record.key());
                    // 处理业务逻辑...
                }

                // 业务处理完成后再提交 offset，保证 at-least-once 语义
                if (!records.isEmpty()) {
                    consumer.commitSync();
                }
            }
        }
    }
}
```

---

## 四、Kafka vs 主流消息队列对比

| 特性 | Kafka | RabbitMQ | RocketMQ |
|------|-------|----------|----------|
| 吞吐量 | 百万级 TPS | 万级 TPS | 十万级 TPS |
| 消息回溯 | ✅ 支持（按 Offset/时间）| ❌ 不支持 | ⚠️ 有限支持 |
| 消费模型 | Pull（拉取）| Push（推送）| Push + Pull |
| 顺序消息 | 分区内有序 | 单队列有序 | 全局/分区有序 |
| 延迟消息 | ❌ 不原生支持 | ✅ 支持 | ✅ 原生支持（18 级）|
| 事务消息 | ✅ 支持 | ✅ 支持 | ✅ 支持 |
| 典型场景 | 日志收集、流处理、大数据 | 业务解耦、任务队列 | 金融交易、订单系统 |

---

## 五、踩坑总结

❌ **误区：分区数越多吞吐量越高**  
✅ 分区数过多会增加 Broker 的文件句柄数和 Controller 的元数据管理开销，每个分区在 Leader 切换时也有额外延迟。建议初始设置 3~12 个分区，根据实际吞吐量按需扩分区，而不是一开始就设置上百个。

❌ **误区：Consumer Group 内加消费者实例就能线性提升消费速度**  
✅ 消费者数量超过分区数后，多余的消费者会处于完全空闲状态（一个分区同一时刻只能被同组内一个消费者消费）。扩消费速度的正确姿势：**先扩分区数，再扩消费者数**，且两者保持对齐。

---

## 六、文章小结

- **Topic + Partition** 是 Kafka 的核心数据模型：Topic 是逻辑分类，Partition 是物理并行单元
- **Offset** 让消费者完全控制消费进度，实现消息回溯，是 Kafka 区别于传统队列的核心能力
- **Consumer Group** 实现消费横向扩展：同组点对点，不同组独立消费（广播）
- 生产者 `acks=all` + 手动提交 Offset 是保证消息不丢的基础配置组合
- Pull 模型让消费者按自己节奏处理，不会因 Broker 推送过快而被压垮

---

## 七、思考题

1. 一个 Consumer Group 有 5 个消费者，Topic 只有 3 个分区，哪 2 个消费者是空闲的？反过来，3 个消费者消费 5 个分区，分区是如何分配的？

2. Kafka 为什么选择"拉取（Pull）"而非"推送（Push）"消费模型？这个设计在哪些场景下会成为瓶颈？

---

## 参考资料

> 1. [Apache Kafka 官方文档 3.7](https://kafka.apache.org/37/documentation.html)
> 2. *Kafka: The Definitive Guide, 2nd Edition* — Neha Narkhede 等著，O'Reilly
> 3. [消息队列选型：Kafka vs RocketMQ vs RabbitMQ](2024-11-10-mq-comparison.md)
> 4. [Kafka 消息可靠性：生产者、Broker、消费者三端保障](2024-09-05-kafka-reliability.md)
