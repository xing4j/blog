# Kafka KRaft 模式：去 ZooKeeper 实战

> 📚 **本文属于「Kafka 原理与生产实战」系列**
> - ✅ [K-01 Kafka 核心概念与快速上手](2026-05-24-kafka-quickstart.md)
> - ✅ [K-02 Kafka 整体架构深度解析](2026-05-24-kafka-architecture.md)
> - ✅ [K-03 Producer 原理与最佳实践](2026-05-24-kafka-producer.md)
> - ✅ [K-04 Consumer 原理与 Rebalance 治理](2026-05-24-kafka-consumer-rebalance.md)
> - ✅ [K-05 存储机制：Log 文件与索引详解](2026-05-24-kafka-storage.md)
> - ✅ [K-06 高可用：副本同步与 Leader 选举](2026-05-24-kafka-ha-replica.md)
> - ✅ [K-07 吞吐量调优实战](2026-05-24-kafka-throughput-tuning.md)
> - ✅ [K-08 消费延迟监控与 Lag 治理](2026-05-24-kafka-consumer-lag.md)
> - ✅ [K-09 事务消息与 Exactly-Once 语义](2026-05-24-kafka-exactly-once.md)
> - 👉 **K-10 KRaft 模式：去 ZooKeeper 实战（本文）**

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 28 分钟｜**分类**：中间件

---

## 导读

Kafka 4.0 已彻底移除 ZooKeeper，KRaft 模式成为唯一选择。本文深入 KRaft 的架构变化：Raft 协议如何替代 ZooKeeper、元数据分区如何工作、Controller 选举为何从秒级降至毫秒级，以及从 ZooKeeper 模式迁移到 KRaft 的完整操作步骤。无论你是在规划新集群还是评估升级路径，本文都能提供具体指导。

---

## 一、ZooKeeper 模式的历史负担

### 1.1 ZooKeeper 在 Kafka 中承担了什么

在 Kafka 3.3 之前，ZooKeeper 是 Kafka 的"外部大脑"：

```
ZooKeeper 存储的元数据：
  /brokers/ids/1          Broker 1 的注册信息
  /brokers/ids/2          Broker 2 的注册信息
  /brokers/topics/order-created/partitions/0/state    P0 的 Leader 是谁
  /controller             当前 Controller 是哪个 Broker
  /admin/reassign_partitions  分区重新分配任务
  /config/topics/order-created   Topic 配置
  ...（数百个 ZNode）
```

### 1.2 ZooKeeper 带来的痛点

| 痛点 | 具体表现 |
|------|---------|
| 运维复杂度高 | 需要额外部署和维护 3~5 个 ZooKeeper 节点 |
| 元数据瓶颈 | 大规模集群（10 万+ 分区）时，ZooKeeper 读写成为瓶颈 |
| Controller 选举慢 | 依赖 ZooKeeper Session 超时（默认 18s）感知故障，选举延迟秒级 |
| 扩展性受限 | Kafka 的分区上限受 ZooKeeper 存储能力约束，约 20 万分区 |
| 双系统一致性 | Kafka Broker 和 ZooKeeper 之间存在元数据同步延迟 |

---

## 二、KRaft 架构设计

### 2.1 核心思想：元数据也是 Kafka Log

KRaft 的核心创新：**将集群元数据存储在 Kafka 自身的一个内部 Topic `@metadata` 中**，由一组 Controller 节点通过 Raft 协议维护，完全去掉外部依赖。

```
KRaft 集群架构：

  ┌─────────────────────────────────────────────────────┐
  │                Controller Quorum (3 nodes)           │
  │  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
  │  │ Controller-1 │  │ Controller-2 │  │Controller-3│ │
  │  │  (Active)    │  │  (Follower)  │  │ (Follower) │ │
  │  │  Raft Leader │  │              │  │            │ │
  │  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘ │
  │         └─────────────────┴─────────────────┘        │
  │                   @metadata partition                │
  └────────────────────┬────────────────────────────────┘
                       │ 元数据同步（MetadataFetch）
          ┌────────────┼────────────┐
          ▼            ▼            ▼
       Broker 1     Broker 2    Broker 3
       （本地缓存元数据快照）
```

### 2.2 节点角色

KRaft 中每个节点可以配置为以下角色（通过 `process.roles` 参数）：

| 角色 | 说明 |
|------|------|
| `controller` | 参与 Raft 协议，管理集群元数据，不处理客户端消息 |
| `broker` | 处理 Producer/Consumer 请求，存储消息 |
| `broker,controller` | 同时承担两种角色（小型集群或测试环境使用）|

**生产推荐**：3~5 个独立 Controller 节点 + N 个 Broker 节点，Controller 和 Broker 角色分离。

### 2.3 Raft 协议替代 ZooKeeper 选举

KRaft 使用 Raft 协议进行 Controller Leader 选举：

```
正常状态：
  Controller-1（Leader）定期向 Follower 发送 Heartbeat

Leader 故障：
  ① Follower 超过选举超时（默认 1~2s）未收到 Heartbeat
  ② 自增 term，向其他节点发送 RequestVote
  ③ 获得多数票（2/3）的节点成为新 Leader
  ④ 新 Leader 广播元数据变更到所有 Broker

选举延迟：毫秒级（< 500ms），远优于 ZooKeeper 模式的 5~30s
```

### 2.4 元数据分区与快照

`@metadata` 是一个单分区 Topic，Controller Quorum 通过 Raft 协议对其进行读写：

- **写入**：只有 Raft Leader（Active Controller）可以写入元数据变更
- **读取**：所有 Controller 和 Broker 都维护本地元数据快照
- **快照**：元数据 Log 积累到一定大小后，生成快照文件（`00000000000000000000.checkpoint`），避免无限增长

---

## 三、KRaft vs ZooKeeper 模式对比

| 维度 | ZooKeeper 模式 | KRaft 模式 |
|------|--------------|-----------|
| 外部依赖 | 需要额外部署 ZooKeeper 集群 | 无外部依赖 |
| Controller 选举延迟 | 5~30 秒 | < 500 毫秒 |
| 支持的最大分区数 | 约 20 万 | 理论上 100 万+ |
| 运维复杂度 | 高（两套系统）| 低（单套系统）|
| 元数据一致性 | 最终一致（存在同步延迟）| 强一致（Raft 保证）|
| 生产就绪时间 | — | Kafka 3.3（2022 年 10 月）|
| ZooKeeper 支持 | ✅ | ❌（4.0 已完全移除）|

---

## 四、新集群部署（KRaft 模式）

### 4.1 三节点 KRaft 集群配置

```properties
# controller-1/server.properties —— Controller 节点配置

# 节点 ID（每个节点唯一）
node.id=1

# 角色：独立 Controller 节点
process.roles=controller

# Controller Quorum 成员配置（格式：nodeId@host:port）
controller.quorum.voters=1@controller-1:9093,2@controller-2:9093,3@controller-3:9093

# Controller 监听地址
listeners=CONTROLLER://0.0.0.0:9093
controller.listener.names=CONTROLLER

# 元数据日志目录
log.dirs=/data/kafka-metadata
```

```properties
# broker-1/server.properties —— Broker 节点配置

node.id=4

# 角色：纯 Broker
process.roles=broker

# 告知 Broker Controller Quorum 的位置
controller.quorum.voters=1@controller-1:9093,2@controller-2:9093,3@controller-3:9093

# Broker 对外监听
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://broker-1:9092
inter.broker.listener.name=PLAINTEXT
controller.listener.names=CONTROLLER

log.dirs=/data/kafka-logs
```

### 4.2 初始化集群（格式化元数据目录）

```shell
# 生成唯一的 Cluster ID（每个集群只执行一次）
CLUSTER_ID=$(kafka-storage.sh random-uuid)
echo "Cluster ID: $CLUSTER_ID"

# 格式化所有节点的元数据目录（Controller 和 Broker 都需要执行）
# Controller 节点：
kafka-storage.sh format \
  --config /etc/kafka/controller.properties \
  --cluster-id $CLUSTER_ID

# Broker 节点：
kafka-storage.sh format \
  --config /etc/kafka/broker.properties \
  --cluster-id $CLUSTER_ID

# 启动所有节点（先启动 Controller，再启动 Broker）
kafka-server-start.sh /etc/kafka/controller.properties &
kafka-server-start.sh /etc/kafka/broker.properties &

# 验证集群状态
kafka-metadata-quorum.sh --bootstrap-server broker-1:9092 describe --status
```

### 4.3 Docker Compose 快速体验

```yaml
# docker-compose.yml —— KRaft 3 节点集群
version: '3.8'

services:
  kafka-1:
    image: apache/kafka:3.7.0
    hostname: kafka-1
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller      # 小集群合并角色
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka-1:9093,2@kafka-2:9093,3@kafka-3:9093
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka-1:9092
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
      KAFKA_DEFAULT_REPLICATION_FACTOR: 3

  kafka-2:
    image: apache/kafka:3.7.0
    hostname: kafka-2
    environment:
      KAFKA_NODE_ID: 2
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka-1:9093,2@kafka-2:9093,3@kafka-3:9093
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka-2:9092
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
      KAFKA_DEFAULT_REPLICATION_FACTOR: 3

  kafka-3:
    image: apache/kafka:3.7.0
    hostname: kafka-3
    environment:
      KAFKA_NODE_ID: 3
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka-1:9093,2@kafka-2:9093,3@kafka-3:9093
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka-3:9092
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
      KAFKA_DEFAULT_REPLICATION_FACTOR: 3
```

---

## 五、ZooKeeper 模式迁移到 KRaft

Kafka 3.x 提供官方迁移工具，支持不停服迁移（Rolling Migration）：

### 5.1 迁移前提条件

- Kafka 版本 ≥ 3.5（Rolling Migration 在 3.5 生产就绪）
- 当前 ZooKeeper 模式集群健康（无分区不可用）
- 已备份 ZooKeeper 元数据

### 5.2 迁移步骤概览

```
① 部署独立的 KRaft Controller 节点（不停现有 ZK + Broker）

② 将现有 Broker 升级为"桥接模式"（同时连接 ZK 和 KRaft Controller）
   server.properties 中添加：
   controller.quorum.voters=1@kc-1:9093,...

③ 执行元数据迁移
   kafka-features.sh enable --feature metadata.version=3.5-IV0

④ 验证元数据已同步到 KRaft Controller
   kafka-metadata-quorum.sh describe --status

⑤ 逐步将 Broker 切换为纯 KRaft 模式（滚动重启）

⑥ 关闭 ZooKeeper 集群
```

> ⚠️ **注意**：Kafka 4.0 已彻底移除 ZooKeeper 代码，无法直接从 ZK 模式的 Kafka 3.x 升级到 4.0，必须先迁移到 KRaft 模式的 3.x，再升级到 4.0。

---

## 六、踩坑总结

❌ **新集群忘记格式化元数据目录就直接启动，导致节点无法加入 Quorum**  
✅ KRaft 模式启动前必须执行 `kafka-storage.sh format`，所有节点（Controller 和 Broker）使用**同一个 Cluster ID**格式化，格式化失败或 ID 不一致会导致节点拒绝启动。

❌ **Controller Quorum 节点数设为偶数（如 2 或 4），导致脑裂风险**  
✅ Raft 协议要求多数节点（> N/2）存活才能正常工作，偶数节点无法获得多数票的优势。生产环境必须使用**奇数个 Controller 节点**（通常 3 个，大型集群 5 个），3 节点可容忍 1 个故障，5 节点可容忍 2 个故障。

---

## 七、小结

- KRaft 通过 Raft 协议将集群元数据管理内化到 Kafka 自身，彻底消除 ZooKeeper 依赖
- Controller 选举延迟从秒级降至毫秒级，支持的分区规模从 20 万扩展到理论 100 万+
- 新集群直接使用 KRaft，旧集群可通过滚动迁移平滑升级（Kafka 3.5+ 生产可用）
- Kafka 4.0 已完全移除 ZooKeeper，从 ZK 模式直接升级 4.0 必须先完成 KRaft 迁移
- Controller Quorum 必须使用奇数节点，生产标准配置为 3 个独立 Controller 节点

---

## 八、思考题

1. KRaft 模式中，`@metadata` 分区只有 1 个，如果这个"分区"的 Leader 宕机（即 Active Controller 宕机），会发生什么？集群是否还能继续处理 Producer/Consumer 请求？

2. Raft 协议要求多数节点存活，那么 3 个 Controller 节点的集群，如果 2 个同时宕机（只剩 1 个），集群会进入什么状态？如何恢复？

---

## 参考资料

> 1. [Apache Kafka 官方文档 3.7 - KRaft Mode](https://kafka.apache.org/37/documentation/#kraft)
> 2. [KIP-500: Replace ZooKeeper with a Self-Managed Metadata Quorum](https://cwiki.apache.org/confluence/display/KAFKA/KIP-500)
> 3. [KIP-833: Mark KRaft as Production Ready](https://cwiki.apache.org/confluence/display/KAFKA/KIP-833)
> 4. [Apache Kafka 4.0 Release Notes](https://kafka.apache.org/blog/kafka-4-0-release-announcement)
> 5. [K-02 Kafka 整体架构深度解析](2026-05-24-kafka-architecture.md)
