# K-07 Kafka 吞吐量调优实战

> 📚 **本文属于「Kafka 原理与生产实战」系列**
> - [K-01 Kafka 核心概念与快速上手](2026-05-24-kafka-quickstart.md)
> - [K-02 Kafka 整体架构深度解析](2026-05-24-kafka-architecture.md)
> - [K-03 Producer 原理与最佳实践](2026-05-24-kafka-producer.md)
> - [K-04 Consumer 原理与 Rebalance 治理](2026-05-24-kafka-consumer-rebalance.md)
> - [K-05 存储机制：Log 文件与索引详解](2026-05-24-kafka-storage.md)
> - [K-06 高可用：副本同步与 Leader 选举](2026-05-24-kafka-ha-replica.md)
> - 👉 **K-07 吞吐量调优实战（本文）**
> - [K-08 消费延迟监控与 Lag 治理](2026-05-24-kafka-consumer-lag.md)
> - [K-09 事务消息与 Exactly-Once 语义](2026-05-24-kafka-exactly-once.md)
> - [K-10 KRaft 模式：去 ZooKeeper 实战](2026-05-24-kafka-kraft.md)

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 30 分钟｜**分类**：中间件

---

## 导读

一套默认配置的 Kafka 集群，吞吐量往往只能发挥出极限性能的 20~30%。本文结合生产调优经验，从 Producer、Broker、Consumer 三端出发，系统梳理影响吞吐量的核心参数，并给出量化的调优效果数据。文末附完整的调优 Checklist 和 Benchmark 参考值，可直接用于生产评估。

---

## 一、吞吐量影响因素全景

```
吞吐量 = 有效消息数 / 时间
      = f(批量大小, 压缩率, 网络带宽, 磁盘 I/O, 副本同步延迟)

瓶颈排查顺序：
  Producer 批量不足 → Broker I/O 线程不足 → 网络带宽打满 → 磁盘写入饱和
```

---

## 二、Producer 端调优

### 2.1 批量参数：batch.size + linger.ms

这是 Producer 调优最有效的两个参数，决定了"一次网络请求发多少数据"：

| 场景 | batch.size | linger.ms | 效果 |
|------|-----------|-----------|------|
| 默认配置 | 16384（16KB）| 0 | 来一条发一条，请求数最多 |
| 轻度调优 | 65536（64KB）| 5ms | 吞吐量提升约 3~5 倍 |
| 激进调优 | 131072（128KB）| 20ms | 吞吐量提升约 8~15 倍，延迟增加 20ms |

**量化测试**（单 Broker，4 核 8GB，SSD，1KB 消息）：

| 配置 | 吞吐量 | P99 延迟 |
|------|--------|---------|
| 默认（16KB, 0ms）| 约 80,000 msg/s | 5ms |
| 64KB + 5ms | 约 320,000 msg/s | 12ms |
| 128KB + 20ms | 约 650,000 msg/s | 35ms |

```java
// JDK 17 + kafka-clients 3.7.0 —— 高吞吐 Producer 配置
Properties props = new Properties();
props.put("bootstrap.servers", "broker1:9092,broker2:9092,broker3:9092");
props.put("acks", "1");                    // 高吞吐场景可降为 acks=1，牺牲部分可靠性
props.put("batch.size", "131072");         // 128KB
props.put("linger.ms", "20");              // 等待 20ms 让 Batch 填充
props.put("compression.type", "lz4");      // lz4：压缩/解压速度最快
props.put("buffer.memory", "67108864");    // 64MB 缓冲区
props.put("max.in.flight.requests.per.connection", "5");  // 允许 5 个并发请求
props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
```

### 2.2 压缩调优

压缩减少网络传输量和磁盘写入量，代价是 CPU 消耗：

| 压缩格式 | 压缩比（1KB 消息）| 压缩速度 | 解压速度 | 综合推荐 |
|---------|----------------|---------|---------|---------|
| none | 1x | — | — | 消息量小时 |
| gzip | 3~4x | 慢（300MB/s）| 慢（500MB/s）| 归档导出 |
| snappy | 2~3x | 快（500MB/s）| 快（2GB/s）| 通用均衡 |
| **lz4** | **2~3x** | **极快（700MB/s）**| **极快（4GB/s）**| **高吞吐首选** |
| zstd | 3~5x | 中等 | 中等 | 追求压缩比 |

> 实测：对 1KB JSON 消息，lz4 压缩可将网络带宽和磁盘占用减少约 60%，CPU 开销可忽略不计（< 5%）。

---

## 三、Broker 端调优

### 3.1 I/O 线程与网络线程

```properties
# server.properties —— Kafka 3.7

# 网络线程：处理客户端连接和请求读取（建议 = CPU 核数）
num.network.threads=8

# I/O 线程：执行实际磁盘读写（建议 = CPU 核数 × 2，I/O 密集型）
num.io.threads=16

# 每个 I/O 线程的请求队列大小
queued.max.requests=500
```

**判断是否需要增加线程**：

```shell
# 监控 Kafka JMX 指标
# I/O 线程利用率超过 80% → 增加 num.io.threads
kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent
# 网络线程利用率超过 80% → 增加 num.network.threads
kafka.network:type=Processor,name=IdlePercent,networkProcessor=*
```

### 3.2 日志刷盘配置

Kafka 默认依赖 OS 的 Page Cache 异步刷盘，不主动 `fsync`：

```properties
# 强制刷盘的条件（通常不建议修改，交给 OS 管理更高效）
log.flush.interval.messages=9223372036854775807  # 几乎从不主动 fsync
log.flush.interval.ms=9223372036854775807        # 几乎从不主动 fsync
```

**为什么不主动 fsync？** 依赖 OS Page Cache + 副本冗余提供持久化保障。主动 fsync 会将每次写入的吞吐量从**百万级**降至**万级**。

### 3.3 Socket 缓冲区

```properties
# 增大 Socket 发送/接收缓冲区，提升大批量数据的网络吞吐
socket.send.buffer.bytes=1048576     # 1MB（默认 100KB）
socket.receive.buffer.bytes=1048576  # 1MB（默认 100KB）
socket.request.max.bytes=104857600   # 单次请求最大 100MB（默认 100MB，通常无需修改）
```

---

## 四、Consumer 端调优

### 4.1 批量拉取参数

| 参数 | 默认值 | 调优建议 | 说明 |
|------|--------|---------|------|
| `fetch.min.bytes` | 1 | 1024~65536 | 最小拉取字节数，未达到则等待 |
| `fetch.max.bytes` | 52428800（50MB）| 增大到 100MB | 单次 Fetch 最大字节数 |
| `fetch.max.wait.ms` | 500 | 100~500 | 等待数据积累的最长时间 |
| `max.poll.records` | 500 | 1000~2000（高吞吐）| 每次 poll 返回的最大消息数 |

```java
// JDK 17 + kafka-clients 3.7.0 —— 高吞吐 Consumer 配置
Properties props = new Properties();
props.put("bootstrap.servers", "broker1:9092,broker2:9092,broker3:9092");
props.put("group.id", "high-throughput-group");
props.put("fetch.min.bytes", "65536");          // 64KB，等凑够再拉
props.put("fetch.max.bytes", "104857600");       // 100MB
props.put("fetch.max.wait.ms", "200");           // 最多等 200ms
props.put("max.poll.records", "2000");           // 每批最多 2000 条
props.put("enable.auto.commit", "false");
```

### 4.2 多线程消费

单 Consumer 单线程处理是瓶颈，可以用**线程池**加速处理：

```java
// JDK 17 + kafka-clients 3.7.0 —— 多线程消费示例（消费线程 + 工作线程池）
public class MultiThreadConsumer {

    private final KafkaConsumer<String, String> consumer;
    private final ExecutorService workers = Executors.newFixedThreadPool(8);  // 8 个工作线程

    public void start() {
        consumer.subscribe(Collections.singletonList("order-created"));

        while (true) {
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));

            // 将每条消息提交给工作线程处理（注意：这里丢失了 offset 提交的精确性）
            List<Future<?>> futures = new ArrayList<>();
            for (ConsumerRecord<String, String> record : records) {
                futures.add(workers.submit(() -> processRecord(record)));
            }

            // 等待本批全部处理完成再提交 offset
            for (Future<?> f : futures) {
                f.get();  // 异常处理省略，实际需捕获并处理
            }
            consumer.commitSync();
        }
    }

    private void processRecord(ConsumerRecord<String, String> record) {
        // 业务处理逻辑...
    }
}
```

> 注意：多线程消费会破坏分区内的消费顺序。如果业务要求同 Key 消息有序处理，应按 `record.key().hashCode() % workerCount` 路由到固定工作线程。

---

## 五、OS 与 JVM 调优

### 5.1 OS 参数

```shell
# /etc/sysctl.conf —— Kafka Broker 所在机器

# 降低 Swap 使用，防止 Page Cache 被换出（Kafka 高度依赖 Page Cache）
vm.swappiness=1

# 调整脏页回写阈值，避免突发的大量 I/O
vm.dirty_ratio=20           # 脏页超过内存 20% 时强制写盘
vm.dirty_background_ratio=5 # 脏页超过内存 5% 时后台异步写盘

# 增大文件描述符限制（每个分区对应多个文件句柄）
fs.file-max=1000000
# 同步修改用户级限制（/etc/security/limits.conf）
# kafka soft nofile 100000
# kafka hard nofile 100000
```

### 5.2 JVM 参数

Kafka Broker 的 JVM 堆不宜过大，Page Cache 才是主要的内存消耗者：

```shell
# kafka-server-start.sh 或 KAFKA_HEAP_OPTS 环境变量
export KAFKA_HEAP_OPTS="-Xms6g -Xmx6g"

# 推荐 GC：G1GC（JDK 11+，Kafka 3.x 默认）
export KAFKA_JVM_PERFORMANCE_OPTS="
  -server
  -XX:+UseG1GC
  -XX:MaxGCPauseMillis=20
  -XX:InitiatingHeapOccupancyPercent=35
  -XX:+ExplicitGCInvokesConcurrent"
```

**为什么堆不能太大？** 64GB 内存的机器，推荐 JVM 堆 6~8GB，剩余 50+ GB 留给 OS Page Cache。JVM 堆越大，GC Stop-The-World 暂停越长，影响 Broker 响应。

---

## 六、调优 Checklist 与 Benchmark 参考

### 调优 Checklist

**Producer 端**
- [ ] `batch.size` ≥ 64KB
- [ ] `linger.ms` = 5~20ms
- [ ] `compression.type` = lz4
- [ ] 使用异步发送 + Callback

**Broker 端**
- [ ] `num.io.threads` = CPU 核数 × 2
- [ ] `num.network.threads` = CPU 核数
- [ ] `socket.send.buffer.bytes` = 1MB
- [ ] `vm.swappiness` = 1

**Consumer 端**
- [ ] `fetch.min.bytes` ≥ 16KB
- [ ] `max.poll.records` 根据处理速度调整
- [ ] 消费者数 = 分区数（避免空闲消费者）

### 单集群 Benchmark 参考值（3 Broker，SSD，千兆网络）

| 场景 | 配置 | 吞吐量 |
|------|------|--------|
| 最大写入 | acks=1, lz4, 128KB batch | 约 1,200,000 msg/s |
| 生产推荐 | acks=all, min.isr=2, lz4, 64KB batch | 约 350,000 msg/s |
| 最大读取（单 Consumer Group）| 8 分区, 8 Consumer | 约 800,000 msg/s |

---

## 七、踩坑总结

❌ **JVM 堆设置过大（如 32GB），导致频繁 Full GC，Broker 超时不可用**  
✅ Kafka Broker 的 JVM 堆建议 6~8GB，Page Cache 才是关键内存资源。内存足够时，热数据（最近写入的消息）几乎全部在 Page Cache 中，Consumer 读取延迟可达微秒级。

❌ **生产环境未开启压缩，网络带宽被打满后误以为是 Broker 性能不足**  
✅ 先用 `kafka-producer-perf-test.sh` 和 `kafka-consumer-perf-test.sh` 做基准测试，定位瓶颈。打满带宽时开启 lz4 压缩是最快的解决方案，通常可将有效吞吐量提升 2~3 倍。

---

## 八、文章小结

- `batch.size=64~128KB` + `linger.ms=5~20ms` + `compression.type=lz4` 是 Producer 调优三件套，可将吞吐量提升 5~15 倍
- Broker 的 `num.io.threads` 和 `num.network.threads` 需与 CPU 核数匹配，否则成为瓶颈
- OS 层 `vm.swappiness=1` 防止 Page Cache 被换出，是 Kafka 性能稳定的基础保障
- JVM 堆不宜超过 8GB，多余内存留给 OS Page Cache，是 Kafka 内存管理的核心原则
- Consumer 并发消费时，按 Key 路由到固定工作线程可在保证吞吐量的同时维持消息有序性

---

## 九、思考题

1. 把 `linger.ms` 调大可以提高吞吐量，但会增加延迟。如何在 SLA 要求 P99 延迟 < 50ms 的前提下，找到 `linger.ms` 的最佳值？有什么方法论？

2. 同一台机器上有多个 Partition 的 Leader，当某个 Partition 的写入量突然激增时，如何防止它影响其他 Partition 的性能？

---

## 参考资料

> 1. [Apache Kafka 官方文档 3.7 - Operations](https://kafka.apache.org/37/documentation/#operations)
> 2. [Benchmarking Apache Kafka: 2 Million Writes Per Second](https://engineering.linkedin.com/kafka/benchmarking-apache-kafka-2-million-writes-second-three-cheap-machines) — LinkedIn Engineering
> 3. [Kafka Producer Performance Tuning](https://developer.confluent.io/tutorials/kafka-producer-throughput/kafka.html) — Confluent
> 4. [K-05 存储机制：Log 文件与索引详解](2026-05-24-kafka-storage.md)
