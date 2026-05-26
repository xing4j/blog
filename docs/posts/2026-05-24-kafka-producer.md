# K-03 Kafka Producer 原理与最佳实践

> 📚 **本文属于「Kafka 原理与生产实战」系列**
> - [K-01 Kafka 核心概念与快速上手](posts/2026-05-24-kafka-quickstart.md)
> - [K-02 Kafka 整体架构深度解析](posts/2026-05-24-kafka-architecture.md)
> - 👉 **K-03 Producer 原理与最佳实践（本文）**
> - [K-04 Consumer 原理与 Rebalance 治理](posts/2026-05-24-kafka-consumer-rebalance.md)
> - [K-05 存储机制：Log 文件与索引详解](posts/2026-05-24-kafka-storage.md)
> - [K-06 高可用：副本同步与 Leader 选举](posts/2026-05-24-kafka-ha-replica.md)
> - [K-07 吞吐量调优实战](posts/2026-05-24-kafka-throughput-tuning.md)
> - [K-08 消费延迟监控与 Lag 治理](posts/2026-05-24-kafka-consumer-lag.md)
> - [K-09 事务消息与 Exactly-Once 语义](posts/2026-05-24-kafka-exactly-once.md)
> - [K-10 KRaft 模式：去 ZooKeeper 实战](posts/2026-05-24-kafka-kraft.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 25 分钟｜**分类**：中间件

---

## 导读

你可能已经能用 `producer.send()` 发消息，但你知道一条消息从调用到真正落盘经历了哪些步骤吗？`acks`、`batch.size`、`linger.ms` 这些参数该怎么配？本文深入 Producer 内部发送流程，讲清楚分区策略、批量发送机制、可靠性配置和幂等性原理，帮你写出生产级别的 Producer 代码。

---

## 一、Producer 内部发送流程

调用 `producer.send(record)` 之后，消息并不会立即发送到 Broker，而是经过以下几个关键步骤：

```
producer.send(record)
      ↓
① 序列化（Serializer）：Key/Value → byte[]
      ↓
② 分区计算（Partitioner）：确定消息发往哪个 Partition
      ↓
③ 写入 RecordAccumulator（内存缓冲区）
      ↓  （达到 batch.size 或等待超过 linger.ms）
④ Sender 线程从缓冲区取出 Batch
      ↓
⑤ NetworkClient 通过网络发送到目标 Broker
      ↓
⑥ Broker 返回 ACK → 触发 Callback 或 Future 完成
```

### 1.1 RecordAccumulator（消息累加器）

RecordAccumulator 是一个按 `TopicPartition` 分组的双端队列，每个队列维护若干 `ProducerBatch`。

```java
// 内部结构（简化）
Map<TopicPartition, Deque<ProducerBatch>> batches;
```

消息写入 RecordAccumulator 后，主线程立即返回（异步发送），实际网络 I/O 由**独立的 Sender 线程**负责，从而实现高吞吐。

### 1.2 Sender 线程的工作逻辑

Sender 线程持续轮询 RecordAccumulator，满足以下任一条件时将 Batch 发出：

- Batch 大小达到 `batch.size`（默认 16KB）
- 等待时间超过 `linger.ms`（默认 0ms，即来一条发一条）
- `buffer.memory`（默认 32MB）已满，阻塞 `max.block.ms` 后强制发送

**关键权衡**：
- `linger.ms=0`：延迟最低，吞吐量较低（每条消息单独发送）
- `linger.ms=5~20ms`：稍微增加延迟，批量发送显著提升吞吐量

---

## 二、分区策略

### 2.1 四种内置策略

| 策略 | 触发条件 | 行为 | 适用场景 |
|------|---------|------|---------|
| 指定分区 | `new ProducerRecord(topic, partition, key, value)` | 直接写入指定分区 | 特定业务需要固定分区 |
| Key Hash | 有 Key，未指定分区 | `hash(key) % numPartitions` | 同 Key 的消息有序（如同一订单的事件） |
| Sticky（默认） | 无 Key，无指定分区 | 黏性地填满一个 Batch 再换下一个分区 | 提高批量效率，Kafka 2.4+ 默认 |
| 轮询（旧版） | 无 Key，Kafka 2.4 以前 | 逐条轮询各分区 | 已不推荐 |

### 2.2 为什么 Sticky 策略优于轮询

轮询策略下，每条消息分配不同分区，导致每个 Batch 很难填满，网络请求数多，吞吐量低。Sticky 策略优先填满一个分区的 Batch 后再切换，减少请求数，生产测试中吞吐量提升约 **30~50%**。

```java
// JDK 17 + kafka-clients 3.7.0 —— 自定义分区策略示例
import org.apache.kafka.clients.producer.Partitioner;
import org.apache.kafka.common.Cluster;
import java.util.Map;

// 按业务 Key 前缀路由：VIP 用户消息优先路由到 Partition 0
public class VipPartitioner implements Partitioner {

    @Override
    public int partition(String topic, Object key, byte[] keyBytes,
                         Object value, byte[] valueBytes, Cluster cluster) {
        int numPartitions = cluster.partitionCountForTopic(topic);
        if (key != null && key.toString().startsWith("VIP-")) {
            return 0;  // VIP 消息固定发往 Partition 0
        }
        // 其他消息均匀分布
        return (key == null ? 0 : Math.abs(key.hashCode())) % numPartitions;
    }

    @Override
    public void close() {}

    @Override
    public void configure(Map<String, ?> configs) {}
}
```

---

## 三、可靠性配置：acks 与 retries

### 3.1 acks 参数详解

`acks` 控制 Producer 在什么条件下认为消息"发送成功"：

| acks 值 | 含义 | 消息丢失风险 | 吞吐量影响 |
|---------|------|------------|----------|
| `0` | 发出即成功，不等 Broker 确认 | 极高（网络故障直接丢失）| 最高 |
| `1` | Leader 写入本地 Log 即确认 | 中等（Leader 宕机且 Follower 未同步则丢失）| 较高 |
| `-1`/`all` | ISR 中所有副本写入才确认 | 极低（ISR 全部故障才丢失）| 较低 |

**生产建议**：业务消息统一使用 `acks=all`（或等价的 `acks=-1`），配合 `min.insync.replicas=2`（Broker 端配置，要求至少 2 个 ISR 副本确认）。

### 3.2 retries 与幂等性

网络抖动可能导致消息发送超时，Producer 会自动重试。但重试可能造成**消息重复**：

```
Producer 发送 msg1 → Broker 已写入 → ACK 在网络中丢失
Producer 超时，重试 → Broker 再次写入 msg1 → 消息重复！
```

**解决方案：幂等 Producer（Idempotent Producer）**

```java
// JDK 17 + kafka-clients 3.7.0 —— 开启幂等性
Properties props = new Properties();
props.put("bootstrap.servers", "localhost:9092");
props.put("acks", "all");
props.put("enable.idempotence", "true");  // 开启幂等性（Kafka 3.0+ 默认开启）
// 开启幂等性后，retries 自动设为 Integer.MAX_VALUE，max.in.flight.requests.per.connection 自动设为 5
```

**幂等性原理**：Broker 为每个 Producer 分配唯一的 `PID`（Producer ID），每条消息携带 `<PID, PartitionID, SequenceNumber>`，Broker 通过 Sequence Number 去重，相同序列号的消息只写入一次。

> 注意：幂等性仅保证**单 Partition、单 Session** 内的 Exactly-Once，跨 Partition 的事务语义需使用事务 Producer，详见 [K-09 事务消息](posts/2026-05-24-kafka-exactly-once.md)。

---

## 四、生产者性能调优

### 4.1 核心参数

| 参数 | 默认值 | 调优建议 | 说明 |
|------|--------|---------|------|
| `batch.size` | 16384（16KB）| 32768~131072（32~128KB）| Batch 越大，批量效果越好，但内存占用增加 |
| `linger.ms` | 0 | 5~20ms | 等待时间，给消息积累的窗口，配合 batch.size 使用 |
| `compression.type` | `none` | `lz4` 或 `snappy` | 压缩可减少 50~80% 传输数据量，lz4 压缩/解压速度最快 |
| `buffer.memory` | 33554432（32MB）| 根据并发量调整 | 缓冲区总大小，生产者线程多时适当增大 |
| `max.block.ms` | 60000（60s）| 保持默认 | 缓冲区满时阻塞时长，超时抛出异常 |

### 4.2 异步发送与 Callback

生产环境应使用**异步发送 + Callback**，而非同步 `get()`：

```java
// JDK 17 + kafka-clients 3.7.0 —— 推荐的异步发送写法
public class AsyncProducerDemo {

    private static final Logger log = LoggerFactory.getLogger(AsyncProducerDemo.class);

    public static void sendAsync(KafkaProducer<String, String> producer,
                                  String topic, String key, String value) {
        ProducerRecord<String, String> record = new ProducerRecord<>(topic, key, value);

        producer.send(record, (metadata, exception) -> {
            if (exception != null) {
                // 发送失败：记录日志，可投入死信队列或报警
                log.error("消息发送失败: topic={}, key={}, error={}",
                    topic, key, exception.getMessage(), exception);
            } else {
                // 发送成功：可用于监控埋点
                log.debug("消息发送成功: partition={}, offset={}",
                    metadata.partition(), metadata.offset());
            }
        });
    }
}
```

**同步 vs 异步的性能差距**：

- 同步发送（`send().get()`）：约 1000~3000 QPS（受网络 RTT 限制）
- 异步发送：可达 50000~200000 QPS（Sender 线程批量发送，不阻塞业务线程）

### 4.3 压缩策略选型

| 压缩格式 | CPU 开销 | 压缩比 | 解压速度 | 推荐场景 |
|---------|---------|--------|---------|---------|
| `none` | 无 | 1x | 无 | 消息量小，不关注带宽 |
| `gzip` | 高 | 最好（约 60~70% 压缩）| 慢 | 批量导出、归档场景 |
| `snappy` | 低 | 一般（约 40~50% 压缩）| 快 | 通用业务，均衡选择 |
| `lz4` | 极低 | 一般（约 40~60% 压缩）| 极快 | **高吞吐首选** |
| `zstd` | 中 | 较好（约 55~65% 压缩）| 中 | Kafka 2.1+，追求压缩比时使用 |

---

## 五、踩坑总结

❌ **同步发送用于高并发场景**

```java
// 错误：每次 send 都阻塞等待，吞吐量极低
RecordMetadata meta = producer.send(record).get();
```

✅ 使用异步发送 + Callback，批量场景下可在所有消息发送完后调用 `flush()` 等待完成：

```java
producer.send(record, callback);  // 异步，不阻塞
// 全部发送后统一等待
producer.flush();
```

❌ **未配置 `min.insync.replicas` 就以为 `acks=all` 绝对安全**  
✅ 如果 ISR 中只剩 1 个副本（Leader 自身），`acks=all` 退化成 `acks=1`。必须在 Broker 端配置 `min.insync.replicas=2`（Topic 级或 Broker 级），当 ISR 数量低于该值时拒绝写入，Producer 会收到 `NotEnoughReplicasException`，而非默默接受单副本写入。

---

## 六、文章小结

- Producer 的发送链路是：序列化 → 分区计算 → RecordAccumulator 缓冲 → Sender 线程批量发送
- `batch.size` + `linger.ms` 共同控制批量发送的时机，是吞吐量调优的核心参数
- `acks=all` + `min.insync.replicas=2` + `enable.idempotence=true` 是生产级别的可靠性三件套
- 幂等 Producer 通过 `<PID, SequenceNumber>` 机制防止单分区消息重复，但不覆盖跨 Partition 场景
- 高吞吐场景优先选用 `lz4` 压缩 + 异步发送，可将吞吐量提升数十倍

---

## 七、思考题

1. `max.in.flight.requests.per.connection` 设为大于 1 时，开启幂等性还能保证消息顺序吗？Kafka 是如何解决这个问题的？

2. 生产者 `buffer.memory` 满了、`max.block.ms` 超时后会抛出什么异常？业务代码应该如何处理这种情况？

---

## 参考资料

> 1. [Apache Kafka 官方文档 3.7 - Producer Configs](https://kafka.apache.org/37/documentation/#producerconfigs)
> 2. *Kafka: The Definitive Guide, 2nd Edition* — 第 3 章 Kafka Producers
> 3. [KIP-679: Producer will enable the strongest delivery guarantee by default](https://cwiki.apache.org/confluence/display/KAFKA/KIP-679)
> 4. [Kafka 消息可靠性：生产者、Broker、消费者三端保障](posts/2024-09-05-kafka-reliability.md)
