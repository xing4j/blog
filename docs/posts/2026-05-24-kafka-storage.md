# K-05 Kafka 存储机制：Log 文件与索引详解

> 📚 **本文属于「Kafka 原理与生产实战」系列**
> - [K-01 Kafka 核心概念与快速上手](posts/2026-05-24-kafka-quickstart.md)
> - [K-02 Kafka 整体架构深度解析](posts/2026-05-24-kafka-architecture.md)
> - [K-03 Producer 原理与最佳实践](posts/2026-05-24-kafka-producer.md)
> - [K-04 Consumer 原理与 Rebalance 治理](posts/2026-05-24-kafka-consumer-rebalance.md)
> - 👉 **K-05 存储机制：Log 文件与索引详解（本文）**
> - [K-06 高可用：副本同步与 Leader 选举](posts/2026-05-24-kafka-ha-replica.md)
> - [K-07 吞吐量调优实战](posts/2026-05-24-kafka-throughput-tuning.md)
> - [K-08 消费延迟监控与 Lag 治理](posts/2026-05-24-kafka-consumer-lag.md)
> - [K-09 事务消息与 Exactly-Once 语义](posts/2026-05-24-kafka-exactly-once.md)
> - [K-10 KRaft 模式：去 ZooKeeper 实战](posts/2026-05-24-kafka-kraft.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 22 分钟｜**分类**：中间件

---

## 导读

Kafka 号称"磁盘比内存还快"，背后依赖的是精心设计的存储结构。本文深入 Kafka 的物理存储层：Log 文件如何分段、稀疏索引如何定位消息、消息格式的演进、零拷贝如何让 I/O 性能翻倍，以及数据清理的两种策略。理解存储机制，是做好 Kafka 调优和容量规划的前提。

---

## 一、分区目录结构

每个 Partition 在 Broker 磁盘上对应一个目录，目录名格式为 `<topic>-<partition>`：

```
/kafka/data/
+-- order-created-0/          # Topic: order-created, Partition: 0
    +-- 00000000000000000000.log      # 数据文件（消息本体）
    +-- 00000000000000000000.index    # 偏移量索引（Offset -> 物理位置）
    +-- 00000000000000000000.timeindex # 时间戳索引（时间 -> Offset）
    +-- 00000000000000512000.log      # 第二个 Segment（从 offset=512000 开始）
    +-- 00000000000000512000.index
    +-- 00000000000000512000.timeindex
    +-- leader-epoch-checkpoint       # Leader Epoch 记录文件
```

文件名即该 Segment 的**起始 Offset**，固定 20 位数字，不足补零。

---

## 二、LogSegment 分段策略

Partition 的数据不是存在一个大文件里，而是分成若干 **LogSegment（日志段）**。分段的目的：

- 便于数据清理（直接删整个 Segment 文件，比逐条删除快得多）
- 限制单文件大小，避免文件系统性能下降

**触发新建 Segment 的条件**（满足任一）：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `log.segment.bytes` | 1GB | 当前 Segment 大小超过 1GB |
| `log.roll.ms` / `log.roll.hours` | 7 天 | Segment 存活时间超过 7 天 |
| 索引文件满 | 由 `log.index.size.max.bytes` 控制 | 索引文件空间不足 |

---

## 三、消息格式（RecordBatch）

Kafka 的消息以 **RecordBatch（消息批次）** 为单位写入 `.log` 文件，而非逐条写入。一个 RecordBatch 包含若干条 Record：

```
RecordBatch:
  baseOffset          int64    # 批次第一条消息的 Offset
  batchLength         int32    # 批次字节长度
  magic               int8     # 消息格式版本号（当前为 2）
  crc                 int32    # CRC32 校验码
  attributes          int16    # 压缩类型、时间戳类型等
  lastOffsetDelta     int32    # 批次内最后一条消息的 Offset 增量
  firstTimestamp      int64    # 批次第一条消息的时间戳
  maxTimestamp        int64    # 批次最大时间戳
  producerId          int64    # 幂等性 Producer ID
  producerEpoch       int16    # Producer Epoch（事务用）
  baseSequence        int32    # 批次起始序列号（幂等性用）
  records:            []Record # 消息列表
    Record:
      attributes      int8
      timestampDelta  varint   # 相对 firstTimestamp 的增量（节省空间）
      offsetDelta     varint   # 相对 baseOffset 的增量
      key             bytes
      value           bytes
      headers         []Header
```

**为什么批次内用增量存储 Offset 和时间戳？**  
`varint`（可变长编码）对小整数极为紧凑，批次内的 Offset 增量通常为 0、1、2...，用 `varint` 仅需 1~2 字节，而绝对值需要 8 字节，大幅节省磁盘空间。

---

## 四、稀疏索引与消息查找

`.index` 文件存储的是**稀疏索引**（而非每条消息都索引）：每隔约 `log.index.interval.bytes`（默认 4KB）建立一条索引。

```
.index 文件示例：
  [offset=0,     position=0     ]
  [offset=256,   position=32768 ]
  [offset=512,   position=65536 ]
  [offset=768,   position=98304 ]
  ...
```

**查找 offset=400 的消息，步骤如下**：

```
① 在 .index 文件中二分查找 ≤ 400 的最大索引项 -> [offset=256, position=32768]
② 从 .log 文件的 position=32768 开始顺序扫描
③ 逐条比较 Offset，找到 offset=400 的消息
```

稀疏索引的优势：`.index` 文件极小，可以完全加载到内存（页缓存），二分查找极快，随后的磁盘顺序扫描也很快（通常只扫描几 KB）。

**时间戳索引（.timeindex）** 的查找方式类似，只是以时间戳替代 Offset 作为查找键，用于按时间回溯消费（`auto.offset.reset=timestamp`）。

---

## 五、零拷贝（Zero-Copy）

Kafka Consumer 拉取消息时，传统 I/O 链路需要 **4 次拷贝**：

```
传统 I/O：
磁盘 -> 内核缓冲区（Page Cache）
      -> 用户空间缓冲区（read）
      -> 内核 Socket 缓冲区（write）
      -> 网络适配器（发送）
```

Kafka 使用 `sendfile()` 系统调用实现零拷贝，减少到 **2 次拷贝**：

```
Zero-Copy（sendfile）：
磁盘 -> 内核缓冲区（Page Cache）
      -> 网络适配器（直接 DMA 传输，跳过用户空间）
```

**效果**：零拷贝可将网络传输吞吐量提升约 **50~200%**，同时大幅降低 CPU 使用率。这也是 Kafka Consumer 吞吐量能媲美生产者的核心原因之一。

> 注意：开启消息压缩后，Broker 需要解压再重新压缩（格式转换时），零拷贝会失效。建议 Producer 和 Consumer 使用相同的压缩格式，Broker 直接透传，维持零拷贝路径。

---

## 六、数据清理策略

Kafka 的消息不会永久保存，通过两种策略控制磁盘用量：

### 6.1 删除策略（Delete）

默认策略，按时间或大小淘汰旧 Segment：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `log.retention.hours` | 168（7 天）| Segment 超过此时间后标记删除 |
| `log.retention.bytes` | -1（不限制）| Partition 总大小超过此值时删除最旧 Segment |

删除以 Segment 为单位，不会删除单条消息。当一个 Segment 中最新消息的时间戳超过保留时间，整个 Segment 才会被删除。

### 6.2 压实策略（Compact）

Log Compaction（日志压实）：保留每个 Key 的**最新一条**消息，删除同 Key 的历史消息。

```
压实前：
  key=A, v=1
  key=B, v=2
  key=A, v=3   <- A 的最新值
  key=C, v=4
  key=B, v=5   <- B 的最新值

压实后：
  key=A, v=3
  key=C, v=4
  key=B, v=5
```

**适用场景**：`__consumer_offsets` 内部 Topic（保留每个 Consumer Group 的最新 Offset）、数据库 Change Data Capture（CDC）场景（只关心每条记录的最新状态）。

---

## 七、踩坑总结

❌ **误以为 Kafka 数据存储在内存，磁盘 I/O 是瓶颈**  
✅ Kafka 依赖操作系统的 **Page Cache**（文件系统缓存）而非 JVM 堆内存。Broker 的写入是顺序写磁盘，顺序写的速度可达随机读的 100 倍以上（机械盘场景更明显）。生产环境应为 Kafka Broker 分配大量物理内存（建议 64GB+），让 OS 有足够空间维持热数据的 Page Cache，减少实际磁盘 I/O。

❌ **Producer 和 Consumer 使用不同压缩格式，导致 Broker 解压重压缩，性能下降**  
✅ 确保 Producer 端 `compression.type` 与 Consumer 端解压格式一致，同时 Broker 端 Topic 配置 `compression.type=producer`（跟随 Producer 设置），Broker 不做格式转换，维持零拷贝路径。

---

## 八、文章小结

- Partition 数据以 LogSegment 分段存储，文件名即起始 Offset，触发分段的阈值是 1GB 或 7 天
- 稀疏索引让 `.index` 文件极小可缓存，结合二分查找 + 顺序扫描实现 O(log n) 的消息定位
- RecordBatch 批量存储配合 `varint` 增量编码，在高吞吐写入场景下节省大量磁盘和带宽
- `sendfile()` 零拷贝是 Consumer 高吞吐读取的核心机制，压缩格式不一致会破坏此路径
- 删除策略适用于日志/事件流；压实策略适用于需要保留最新状态的 Key-Value 场景

---

## 九、思考题

1. Kafka 顺序写磁盘的吞吐量高，那为什么还需要 Page Cache？如果 Broker 内存充足，所有读写都命中 Page Cache，会有什么效果？

2. Log Compaction 执行过程中，Consumer 能正常消费吗？Compaction 期间的消息顺序如何保证？

---

## 参考资料

> 1. [Apache Kafka 官方文档 3.7 - Log Compaction](https://kafka.apache.org/37/documentation/#compaction)
> 2. *Kafka: The Definitive Guide, 2nd Edition* — 第 5 章 Kafka Internals
> 3. [Linux sendfile() man page](https://man7.org/linux/man-pages/man2/sendfile.2.html)
> 4. [K-07 Kafka 吞吐量调优实战](posts/2026-05-24-kafka-throughput-tuning.md)
