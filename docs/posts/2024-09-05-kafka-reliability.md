# Kafka 消息丢失与重复消费的解决方案

<div class="post-meta">📅 2024-09-05 &nbsp;·&nbsp; 🏷️ <span class="tag">Kafka</span></div>

Kafka 在追求高吞吐的同时，需要在三个环节防范消息丢失，同时处理重复消费带来的幂等问题。本文逐一分析三个环节的丢失原因，并给出完整的解决方案。

---

## 一、消息丢失的三个环节

```
Producer -------> Broker Cluster -------> Consumer
   ^                   ^                   ^
 [环节1]             [环节2]             [环节3]
发送未确认          副本未同步          消费前崩溃
```

| 环节 | 丢失原因 | 解决方案 |
|------|---------|---------|
| Producer → Broker | 发送失败未重试，网络抖动 | acks=all + retries + 幂等 |
| Broker 内部 | Leader 宕机，Follower 未同步完 | min.insync.replicas + unclean.leader.election=false |
| Consumer | 自动提交 offset，处理前崩溃 | 手动提交 offset |

---

## 二、环节1：Producer 端防丢失

### 2.1 acks 参数详解

```java
Properties props = new Properties();
props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092");
props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());

// acks 配置（核心）
// acks=0：不等待确认，吞吐最高，丢失风险最大
// acks=1：Leader 写入即确认，平衡方案
// acks=all (-1)：所有 ISR 副本确认，最安全
props.put(ProducerConfig.ACKS_CONFIG, "all");

// 重试配置
props.put(ProducerConfig.RETRIES_CONFIG, Integer.MAX_VALUE);
props.put(ProducerConfig.RETRY_BACKOFF_MS_CONFIG, 300);

// 请求超时
props.put(ProducerConfig.REQUEST_TIMEOUT_MS_CONFIG, 30000);
props.put(ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG, 120000);
```

| acks 值 | 含义 | 丢失风险 | 吞吐影响 |
|---------|------|---------|---------|
| 0 | 不等待确认 | 最高 | 最小 |
| 1 | Leader 确认 | 中（Leader 宕机即丢） | 较小 |
| all/-1 | 所有 ISR 确认 | 最低 | 较大 |

### 2.2 幂等 Producer（Idempotent Producer）

```java
// 开启幂等，Broker 自动去重
props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
// 开启幂等后自动设置：acks=all, retries=MAX, max.in.flight.requests.per.connection=5

KafkaProducer<String, String> producer = new KafkaProducer<>(props);

// 发送时携带回调
producer.send(new ProducerRecord<>("my-topic", key, value), (metadata, exception) -> {
    if (exception != null) {
        // 发送失败处理
        log.error("消息发送失败，topic={}, key={}", metadata.topic(), key, exception);
        // 可写入本地补偿表，后续重试
    } else {
        log.info("发送成功，offset={}, partition={}", metadata.offset(), metadata.partition());
    }
});
```

**幂等原理：**
- Producer 启动时分配唯一 PID（Producer ID）
- 每条消息携带 (PID, PartitionID, SequenceNumber)
- Broker 对每个 (PID, Partition) 维护最新 SeqNum
- 重复消息（SeqNum 相同）直接丢弃

### 2.3 事务 Producer

```java
// 事务Producer：跨分区原子写入
props.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, "my-transactional-id");
props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);

KafkaProducer<String, String> producer = new KafkaProducer<>(props);
producer.initTransactions();

try {
    producer.beginTransaction();
    producer.send(new ProducerRecord<>("topic-a", "key1", "value1"));
    producer.send(new ProducerRecord<>("topic-b", "key2", "value2"));
    producer.commitTransaction();
} catch (ProducerFencedException | OutOfOrderSequenceException e) {
    producer.close(); // 不可恢复，关闭
} catch (KafkaException e) {
    producer.abortTransaction(); // 中止事务
}
```

---

## 三、环节2：Broker 端防丢失

### 3.1 副本同步机制

```
                    ISR（In-Sync Replicas）
Leader ------- Replica-1 (已同步)
    +--------- Replica-2 (已同步)
    +--------- Replica-3 (落后 > replica.lag.time.max.ms，已踢出 ISR)
```

```properties
# Broker 配置
# 最少 ISR 副本数（低于此数拒绝写入）
min.insync.replicas=2

# 禁止非 ISR 副本成为 Leader（防止数据丢失）
unclean.leader.election.enable=false

# 副本落后超过此时间被踢出 ISR
replica.lag.time.max.ms=10000

# 数据刷盘策略（建议依赖副本而非强制刷盘）
# log.flush.interval.messages=1  # 每条强制刷盘（性能极差，不推荐）
log.flush.scheduler.interval.ms=3000
```

### 3.2 Topic 创建最佳实践

```bash
# 创建 Topic：3个副本，min.insync.replicas=2
kafka-topics.sh --create \
  --bootstrap-server localhost:9092 \
  --topic my-important-topic \
  --partitions 6 \
  --replication-factor 3 \
  --config min.insync.replicas=2 \
  --config unclean.leader.election.enable=false
```

---

## 四、环节3：Consumer 端防丢失

### 4.1 自动提交的问题

```java
// 危险！自动提交可能导致消息丢失
props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, true);
props.put(ConsumerConfig.AUTO_COMMIT_INTERVAL_MS_CONFIG, 5000);

// 问题场景：
// t=0: poll() 返回 offset 100~110 的消息
// t=3s: 正在处理 offset=105 的消息
// t=5s: 自动提交 offset=110（已提交）
// t=5.1s: Consumer 崩溃
// t=6s: 重启后从 offset=110 开始消费
// 结果：offset 106~110 的消息永久丢失！
```

### 4.2 手动提交 offset

```java
props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false); // 关闭自动提交

KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props);
consumer.subscribe(Collections.singletonList("my-topic"));

while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    
    for (ConsumerRecord<String, String> record : records) {
        try {
            // 处理消息
            processMessage(record.value());
        } catch (Exception e) {
            log.error("消息处理失败，offset={}", record.offset(), e);
            // 根据业务决定：跳过/重试/写死信队列
        }
    }
    
    // 所有消息处理完成后，手动提交
    try {
        consumer.commitSync(); // 同步提交（更安全）
    } catch (CommitFailedException e) {
        log.error("提交 offset 失败", e);
    }
}
```

### 4.3 精确提交（按分区）

```java
// 记录每个分区已处理的最大 offset
Map<TopicPartition, OffsetAndMetadata> offsets = new HashMap<>();

for (ConsumerRecord<String, String> record : records) {
    processMessage(record.value());
    offsets.put(
        new TopicPartition(record.topic(), record.partition()),
        new OffsetAndMetadata(record.offset() + 1) // 提交下一个待消费的 offset
    );
}

consumer.commitSync(offsets); // 精确提交
```

---

## 五、三种消费语义

| 语义 | 描述 | 实现方式 | 可能结果 |
|------|------|---------|---------|
| **At Most Once** | 最多消费一次 | 消费前提交 offset | 可能丢消息 |
| **At Least Once** | 至少消费一次 | 消费后提交 offset | 可能重复消费 |
| **Exactly Once** | 恰好消费一次 | 事务 + 幂等 Consumer | 不丢不重 |

### 5.1 At Least Once（最常用）

```java
// 消费后提交，可能重复但不丢失
while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    for (ConsumerRecord<String, String> record : records) {
        processMessage(record.value()); // 先处理
    }
    consumer.commitSync(); // 后提交（崩溃重启后会重复消费）
}
```

### 5.2 Exactly Once（完整方案）

```java
// 方案一：Kafka Streams（内置 Exactly Once）
StreamsConfig config = new StreamsConfig();
config.put(StreamsConfig.PROCESSING_GUARANTEE_CONFIG, StreamsConfig.EXACTLY_ONCE_V2);

// 方案二：Producer 事务 + Consumer 读已提交
// Consumer 端只读取已提交的事务消息
props.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");

// 方案三：消费+写库原子操作（Transactional Outbox Pattern）
@Transactional
public void consumeAndSave(ConsumerRecord<String, String> record) {
    // 检查是否已处理（幂等）
    if (processedMessageRepo.existsByMessageId(record.key())) {
        return; // 已处理，跳过
    }
    // 业务处理
    orderService.createOrder(record.value());
    // 记录已处理
    processedMessageRepo.save(new ProcessedMessage(record.key(), record.offset()));
    // 手动提交 offset（在事务提交后）
}
```

---

## 六、重复消费的幂等处理

```java
@Service
public class OrderMessageConsumer {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    @Autowired
    private OrderService orderService;
    
    /**
     * 使用 Redis 实现消费幂等
     * key: message-id 或 业务唯一ID
     */
    public void handleMessage(ConsumerRecord<String, String> record) {
        String messageId = record.key(); // 使用消息 key 作为唯一ID
        String lockKey = "kafka:consumed:" + messageId;
        
        // SET NX EX：原子操作，防并发重复处理
        Boolean isNew = redisTemplate.opsForValue()
            .setIfAbsent(lockKey, "1", Duration.ofHours(24));
        
        if (Boolean.FALSE.equals(isNew)) {
            log.warn("重复消息，跳过处理，messageId={}", messageId);
            return;
        }
        
        try {
            orderService.createOrder(record.value());
        } catch (Exception e) {
            // 处理失败，删除 Redis key，允许重试
            redisTemplate.delete(lockKey);
            throw e;
        }
    }
}
```

---

## 七、完整可靠性配置清单

### Producer 配置

```properties
# 必须配置
acks=all
enable.idempotence=true
retries=2147483647
max.in.flight.requests.per.connection=5

# 建议配置
delivery.timeout.ms=120000
request.timeout.ms=30000
linger.ms=5
batch.size=16384
```

### Broker 配置

```properties
# 必须配置
min.insync.replicas=2
unclean.leader.election.enable=false
default.replication.factor=3

# 建议配置
log.retention.hours=168
log.segment.bytes=1073741824
```

### Consumer 配置

```properties
# 必须配置
enable.auto.commit=false
isolation.level=read_committed

# 建议配置
max.poll.records=500
session.timeout.ms=30000
heartbeat.interval.ms=10000
max.poll.interval.ms=300000
```

---

## 八、常见问题排查

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| 消息积压 | Consumer 处理慢 | 增加 Partition 数和 Consumer 数 |
| 重复消费 | Rebalance 触发再均衡 | 消费端幂等，增大 `max.poll.interval.ms` |
| 消息丢失 | acks=1 + Leader 宕机 | 改为 acks=all |
| Offset 提交失败 | Consumer 超时被踢出 | 增大 `session.timeout.ms` |
| 消费延迟 | `linger.ms` 过大 | 调小 Producer 端 `linger.ms` |

---

## 九、总结与延伸

**核心要点**：
- Kafka 消息可靠性是 Producer、Broker、Consumer 三端协同的结果，任何一端配置不当都会导致消息丢失或重复
- **不丢消息**：Producer acks=all + retries、Broker min.insync.replicas=2 + unclean.leader.election=false、Consumer 手动提交 offset
- **不重消费**：消费端必须实现业务幂等，Redis SET NX 或数据库唯一约束是最常用方案
- Exactly Once 语义实现代价高，生产环境多数场景 At Least Once + 幂等即可满足
- 参数调优重点：`max.poll.interval.ms` 决定消费超时，设得太小会频繁 Rebalance；设得太大会延迟故障检测

**延伸阅读方向**：
- Kafka Streams：在流式计算管道中实现 Exactly Once 语义的完整方案
- Kafka Connect：数据管道 Connector 的容错机制与 offset 存储策略
- Confluent Schema Registry：配合 Avro/Protobuf 实现消息格式版本管理，防止 Schema 不兼容导致消费失败
- Pulsar vs Kafka：存储计算分离架构对消息可靠性和扩展性的影响对比
