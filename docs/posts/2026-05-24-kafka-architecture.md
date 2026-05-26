# K-02 Kafka 整体架构深度解析

> 📚 **本文属于「Kafka 原理与生产实战」系列**
> - [K-01 Kafka 核心概念与快速上手](posts/2026-05-24-kafka-quickstart.md)
> - 👉 **K-02 Kafka 整体架构深度解析（本文）**
> - [K-03 Producer 原理与最佳实践](posts/2026-05-24-kafka-producer.md)
> - [K-04 Consumer 原理与 Rebalance 治理](posts/2026-05-24-kafka-consumer-rebalance.md)
> - [K-05 存储机制：Log 文件与索引详解](posts/2026-05-24-kafka-storage.md)
> - [K-06 高可用：副本同步与 Leader 选举](posts/2026-05-24-kafka-ha-replica.md)
> - [K-07 吞吐量调优实战](posts/2026-05-24-kafka-throughput-tuning.md)
> - [K-08 消费延迟监控与 Lag 治理](posts/2026-05-24-kafka-consumer-lag.md)
> - [K-09 事务消息与 Exactly-Once 语义](posts/2026-05-24-kafka-exactly-once.md)
> - [K-10 KRaft 模式：去 ZooKeeper 实战](posts/2026-05-24-kafka-kraft.md)

**深度等级**：⭐ 入门｜**阅读时长**：约 18 分钟｜**分类**：中间件

---

## 导读

知道怎么用 Kafka 之后，下一个问题是：消息是如何在集群中流转的？Controller 是什么角色？副本怎么保证高可用？本文用一张全局架构图拆解 Kafka 集群的各个组件，帮你建立完整的架构认知，为后续深入 Producer、Consumer 和存储打下基础。

---

## 一、整体架构图

```
┌─────────────────────────────────────────────────────────────┐
│                        Kafka Cluster                        │
│                                                             │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐             │
│  │ Broker 1 │    │ Broker 2 │    │ Broker 3 │             │
│  │          │    │          │    │          │             │
│  │ Topic-A  │    │ Topic-A  │    │ Topic-A  │             │
│  │  P0(L)   │    │  P1(L)   │    │  P2(L)   │             │
│  │  P1(F)   │    │  P2(F)   │    │  P0(F)   │             │
│  │  P2(F)   │    │  P0(F)   │    │  P1(F)   │             │
│  └────┬─────┘    └────┬─────┘    └────┬─────┘             │
│       │               │               │                    │
│       └───────────────┴───────────────┘                    │
│                       │  Controller (active Broker)         │
└───────────────────────┼─────────────────────────────────────┘
                        │
          ┌─────────────┼──────────────┐
          │             │              │
     Producer      ZooKeeper/     Consumer Group
                   KRaft 元数据
```

**说明**：P0(L) 表示 Partition 0 的 Leader 副本，P1(F) 表示 Partition 1 的 Follower 副本。

---

## 二、核心组件详解

### 2.1 Broker 集群

Broker 是 Kafka 的服务节点，职责包括：

- 接收 Producer 写入的消息，持久化到本地磁盘
- 响应 Consumer 的拉取请求
- 维护 Topic/Partition 的副本

生产环境推荐 **3 个或以上** Broker 节点，原因：
- 支持 `replication-factor=3`（业界标准），容忍 1 个节点故障
- Controller 选举和 ISR（In-Sync Replicas，同步副本集合）机制需要多数节点存活

### 2.2 Topic 与 Partition 的物理分布

一个 Topic 的多个 Partition 会**均匀分散**在各个 Broker 上，避免单点热点：

```
Topic: order-created（3 分区，3 副本，3 个 Broker）

Broker 1: P0-Leader,  P1-Follower, P2-Follower
Broker 2: P1-Leader,  P2-Follower, P0-Follower
Broker 3: P2-Leader,  P0-Follower, P1-Follower
```

这种分布策略确保了：即使 Broker 1 宕机，P0 的 Follower 副本（在 Broker 2 或 3 上）可以晋升为新 Leader，继续提供服务。

### 2.3 副本机制：AR / ISR / OSR

每个 Partition 有若干副本，副本集合按同步状态分为三类：

| 缩写 | 全称 | 含义 |
|------|------|------|
| AR | Assigned Replicas | 该 Partition 被分配的所有副本 |
| ISR | In-Sync Replicas | 与 Leader 保持同步的副本集合 |
| OSR | Out-of-Sync Replicas | 落后于 Leader 太多、暂时移出同步集合的副本 |

关系：`AR = ISR + OSR`

**ISR 的动态维护**：Follower 副本通过向 Leader 发送 Fetch 请求拉取消息。如果某个 Follower 超过 `replica.lag.time.max.ms`（默认 30 秒）没有发起 Fetch，或落后消息数超过阈值，Leader 会将其从 ISR 中踢出，加入 OSR；待 Follower 追上进度后，再重新加入 ISR。

### 2.4 Controller

Controller 是集群的"大脑"，本质上是某个 Broker 扮演的特殊角色，职责包括：

- 监听 Broker 上下线，触发 Leader 重新选举
- 维护集群元数据（Topic、Partition、副本分配等）
- 将元数据变更同步到其他 Broker

**Controller 选举**：通过在 ZooKeeper 上抢占临时节点（`/controller`）实现，先抢到的 Broker 成为 Controller；ZooKeeper 模式下，Broker 故障后其临时节点消失，其他 Broker 重新竞争。KRaft 模式下改用 Raft 协议选举，详见 [K-10 KRaft 模式](posts/2026-05-24-kafka-kraft.md)。

### 2.5 ZooKeeper 的历史角色（3.x 之前）

在 Kafka 3.x 之前，ZooKeeper（分布式协调服务）承担了大量职责：

- 存储 Broker 注册信息
- 维护 Topic/Partition 元数据
- Controller 选举
- Consumer Group 的 Offset 存储（早期版本）

**问题**：ZooKeeper 成为性能和运维瓶颈，大规模集群（数千分区）下 ZooKeeper 节点读写压力极大。Kafka 3.3 开始 KRaft 模式成为生产可用，4.0 彻底移除 ZooKeeper 依赖。

---

## 三、消息写入全流程

从 Producer 发出一条消息，到消费者读取，经历以下步骤：

```
① Producer 发送消息
      ↓
② 根据 Partition 策略（Key Hash / 轮询）确定目标 Partition
      ↓
③ 找到该 Partition 的 Leader Broker
      ↓
④ Leader 将消息写入本地 Log 文件（顺序写磁盘）
      ↓
⑤ Follower 主动 Fetch 消息，写入本地 Log
      ↓
⑥ 当 ISR 中所有副本确认写入，Leader 更新 HW（High Watermark）
      ↓
⑦ Producer 收到 ACK（acks=all 时需等到步骤⑥）
      ↓
⑧ Consumer poll 时，只能读取 HW 以下的消息（已提交消息）
```

**为什么 Consumer 只能读 HW 以下的消息？** 保证消费者不会读到尚未被所有 ISR 副本确认的消息，避免 Broker 故障后消息"消失"导致消费不一致。

---

## 四、__consumer_offsets 内部 Topic

Kafka 用一个内部 Topic `__consumer_offsets` 存储所有 Consumer Group 的消费进度（Offset），默认 50 个分区。

Consumer 每次 `commitSync()` 或 `commitAsync()` 时，实际上是向这个 Topic 写入一条 KV 消息：

```
Key:   <group.id, topic, partition>
Value: <offset, timestamp, metadata>
```

这种设计将 Offset 存储的可靠性委托给 Kafka 自身，相比早期存 ZooKeeper，性能更好，扩展性更强。

---

## 五、Kafka 集群元数据流转

```
                  ┌──────────────────┐
                  │   Controller     │
                  │  (active Broker) │
                  └────────┬─────────┘
         元数据广播         │          元数据广播
        ┌──────────────────┤─────────────────────┐
        ▼                  ▼                     ▼
   Broker 1           Broker 2              Broker 3
   (缓存元数据)        (缓存元数据)           (缓存元数据)
        ▲                  ▲
        │  metadata fetch  │
   Producer/Consumer ──────┘
```

Producer 和 Consumer 在启动时会向任意 Broker 发起 `Metadata` 请求，获取所有 Topic 的分区 Leader 信息，随后直接与对应 Leader Broker 通信。元数据会在客户端本地缓存，定期刷新（`metadata.max.age.ms`，默认 5 分钟）。

---

## 六、踩坑总结

❌ **误区：所有消息都经过 Controller 转发**  
✅ Controller 只负责元数据管理和 Leader 选举，不参与消息的读写链路。Producer 和 Consumer 直接与对应 Partition 的 Leader Broker 通信，Controller 宕机期间消息读写不受影响（但 Leader 选举会暂停）。

❌ **误区：副本数越多越安全，越多越好**  
✅ 副本数增加会线性增大写放大（每条消息需要写入 N 个副本）和网络带宽消耗。生产环境 `replication-factor=3` 是黄金标准：可容忍 1 个节点故障，写放大可控。超过 3 个副本的收益边际递减，成本却线性上升。

---

## 七、文章小结

- Kafka 集群由多个 Broker 组成，Topic 的 Partition 均匀分散在各 Broker 上，既负载均衡又高可用
- AR/ISR/OSR 三类副本集合动态维护同步状态，ISR 是消息提交和 Leader 选举的核心依据
- Controller 是集群元数据的管理中心，负责 Broker 上下线监听和 Leader 选举，不参与消息读写
- Consumer 只能读取 HW 以下的已提交消息，保证副本故障时消费端不出现数据不一致
- `__consumer_offsets` 内部 Topic 让 Offset 存储具备与业务消息相同的持久化和高可用保障

---

## 八、思考题

1. Broker 1 突然宕机，P0 的 Leader 在 Broker 1 上，此时系统如何恢复？整个过程中消息读写会中断多久？

2. 为什么 Kafka 不让 Consumer 直接读取 Follower 副本的消息（跳过 HW 限制）？这样做的收益和风险各是什么？

---

## 参考资料

> 1. [Apache Kafka 官方文档 3.7 - Design](https://kafka.apache.org/37/documentation/#design)
> 2. *Kafka: The Definitive Guide, 2nd Edition* — 第 5 章 Kafka Internals
> 3. [KIP-500: Replace ZooKeeper with a Self-Managed Metadata Quorum](https://cwiki.apache.org/confluence/display/KAFKA/KIP-500)
> 4. [K-06 高可用：副本同步与 Leader 选举](posts/2026-05-24-kafka-ha-replica.md)
