# K-06 Kafka 高可用：副本同步与 Leader 选举

> 📚 **本文属于「Kafka 原理与生产实战」系列**
> - [K-01 Kafka 核心概念与快速上手](posts/2026-05-24-kafka-quickstart.md)
> - [K-02 Kafka 整体架构深度解析](posts/2026-05-24-kafka-architecture.md)
> - [K-03 Producer 原理与最佳实践](posts/2026-05-24-kafka-producer.md)
> - [K-04 Consumer 原理与 Rebalance 治理](posts/2026-05-24-kafka-consumer-rebalance.md)
> - [K-05 存储机制：Log 文件与索引详解](posts/2026-05-24-kafka-storage.md)
> - 👉 **K-06 高可用：副本同步与 Leader 选举（本文）**
> - [K-07 吞吐量调优实战](posts/2026-05-24-kafka-throughput-tuning.md)
> - [K-08 消费延迟监控与 Lag 治理](posts/2026-05-24-kafka-consumer-lag.md)
> - [K-09 事务消息与 Exactly-Once 语义](posts/2026-05-24-kafka-exactly-once.md)
> - [K-10 KRaft 模式：去 ZooKeeper 实战](posts/2026-05-24-kafka-kraft.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 22 分钟｜**分类**：中间件

---

## 导读

Kafka 的高可用依靠副本机制实现，但副本同步中藏着几个极易踩坑的概念：HW 与 LEO 如何协同？ISR 收缩时消息可靠性如何变化？Broker 宕机后 Leader 选举的完整流程是什么？本文逐一拆解这些机制，帮你在设计高可用方案时做出正确决策。

---

## 一、HW 与 LEO：副本同步的两把尺

### 1.1 概念定义

- **LEO（Log End Offset）**：副本本地已写入的最新消息的下一个 Offset，即"写到哪里了"
- **HW（High Watermark，高水位）**：ISR 中所有副本都已同步的最大 Offset，即"提交到哪里了"

Consumer 只能读取 HW 以下的消息（已提交消息），HW 以上的消息对 Consumer 不可见。

### 1.2 副本同步流程

假设 Partition 有 3 个副本（1 个 Leader + 2 个 Follower），接收一条消息的同步流程：

```
时间轴 ->

Leader:
  写入消息 msg1      LEO=1, HW=0
  Follower-A Fetch->  返回 msg1
  Follower-B Fetch->  返回 msg1
  收到两个 Follower 的 ACK（LEO 更新到 1）
  更新 HW=1          LEO=1, HW=1（消息可被 Consumer 消费）

Follower-A:
  发 Fetch 请求     LEO=0
  收到 msg1，写入   LEO=1
  下次 Fetch 带上   LEO=1（通知 Leader 自己已同步）

Follower-B:
  同上              LEO=1
```

**HW 的更新时机**：Leader 在收到 Follower 的 Fetch 请求时，根据请求中携带的 Follower LEO，更新各 Follower 的 remote LEO，取所有 ISR 副本 remote LEO 的**最小值**作为新的 HW。

### 1.3 HW 更新的一个经典问题

由于 HW 的更新存在一轮延迟（Follower 需要额外一次 Fetch 才能感知 HW 变化），在某些极端情况（如 Follower 重启后立即成为 Leader）可能导致消息截断。Kafka 通过引入 **Leader Epoch** 机制解决此问题——每次 Leader 切换时 Epoch 递增，Follower 根据 Epoch 判断是否需要截断日志。

---

## 二、ISR 的动态维护

### 2.1 加入和退出 ISR 的条件

**退出 ISR（进入 OSR）**：Follower 超过 `replica.lag.time.max.ms`（默认 30s）未向 Leader 发送 Fetch 请求，或长时间落后于 Leader 时，Leader 将其移出 ISR。

**重新加入 ISR**：Follower 追上 Leader 的 LEO 后，自动重新加入 ISR。

### 2.2 ISR 收缩对可靠性的影响

```
正常状态：ISR = {Leader, Follower-A, Follower-B}
  acks=all 需要 3 个副本确认 -> 安全

Follower-B 网络故障，退出 ISR：
  ISR = {Leader, Follower-A}
  acks=all 只需 2 个副本确认 -> 仍安全

Follower-A 也故障，退出 ISR：
  ISR = {Leader}（仅剩 Leader 自身）
  acks=all 退化为 acks=1 -> 危险！
```

**防御措施**：在 Broker 端（或 Topic 级别）配置 `min.insync.replicas=2`，当 ISR 数量低于此值时，Broker 拒绝 Producer 写入，抛出 `NotEnoughReplicasException`，而非接受仅 Leader 的不安全写入。

---

## 三、Leader 选举流程

### 3.1 正常选举（ISR 内选举）

Broker 宕机时，Controller 触发 Leader 选举：

```
① Controller 检测到 Broker 1（原 Leader）下线
② Controller 从该 Partition 的 ISR 列表中选取第一个副本作为新 Leader
   ISR = [Broker2, Broker3] -> Broker2 成为新 Leader
③ Controller 将新 Leader 信息写入 ZooKeeper/KRaft 元数据
④ Controller 通知集群中所有 Broker 更新元数据缓存
⑤ Producer/Consumer 感知元数据变化，向新 Leader 发起请求
```

整个过程通常在 **5~30 秒**内完成（取决于 `zookeeper.session.timeout.ms` 等配置），期间该 Partition 不可写不可读。

### 3.2 Unclean Leader 选举

如果 ISR 为空（所有 ISR 副本全部宕机），还有两种选择：

| 配置 | 行为 | 适用场景 |
|------|------|---------|
| `unclean.leader.election.enable=false`（默认）| 等待 ISR 内有副本恢复，期间分区不可用 | 数据不能丢失的业务（金融、交易）|
| `unclean.leader.election.enable=true` | 从 OSR（落后副本）中选出 Leader，可能丢数据 | 可用性优先的日志收集场景 |

**为什么 Unclean 选举会丢数据？**  
OSR 副本的 LEO 落后于原 Leader，选为新 Leader 后，那些已在原 Leader 上提交但未同步到此副本的消息将永久丢失。

### 3.3 Preferred Leader 与 Leader 均衡

Kafka 允许设置 **Preferred Leader**（首选 Leader）——每个 Partition 创建时分配的第一个副本。当 Broker 从故障中恢复后，可能不再是 Leader，导致集群负载不均衡。

```shell
# 触发 Preferred Leader 重新均衡（Kafka 自带工具）
kafka-leader-election.sh \
  --bootstrap-server localhost:9092 \
  --election-type PREFERRED \
  --all-topic-partitions
```

Broker 端参数 `auto.leader.rebalance.enable=true`（默认）会定期自动执行 Preferred Leader 选举，避免人工干预。

---

## 四、Controller 的高可用

### 4.1 ZooKeeper 模式下的 Controller 选举

所有 Broker 竞争在 ZooKeeper 上创建 `/controller` 临时节点，成功者成为 Controller。  
当前 Controller 宕机 → ZooKeeper 的临时节点消失 → 其他 Broker 感知到 → 重新竞争 `/controller` 节点。

**问题**：ZooKeeper Session 超时（`zookeeper.session.timeout.ms`，默认 18s）是感知 Controller 宕机的延迟来源，这段时间内集群 Leader 选举暂停。

### 4.2 KRaft 模式下的改进

KRaft 模式用 Raft 协议替代 ZooKeeper，Controller 选举延迟从**秒级**降至**毫秒级**，具体原理见 [K-10 KRaft 模式](posts/2026-05-24-kafka-kraft.md)。

---

## 五、踩坑总结

❌ **未配置 `min.insync.replicas`，以为 3 副本就万无一失**  
✅ `replication-factor=3` 只保证有 3 个副本存在，不保证写入时有多少个副本确认。必须组合配置：`replication-factor=3` + `acks=all` + `min.insync.replicas=2`，三者缺一不可。

❌ **生产集群开启了 `unclean.leader.election.enable=true`，结果消息悄悄丢了**  
✅ 除非是日志收集等允许少量丢失的场景，生产业务集群应保持 `unclean.leader.election.enable=false`（Kafka 2.0+ 已改为默认 false）。宁可分区短暂不可用，也不要接受数据丢失。

---

## 六、文章小结

- HW 是所有 ISR 副本已同步 Offset 的最小值，Consumer 只能读 HW 以下的已提交消息
- ISR 动态维护保证了"提交的消息必然在所有 ISR 副本上存在"这一核心不变量
- `acks=all` + `min.insync.replicas=2` 是防止 ISR 收缩导致单副本写入的双重保险
- Unclean Leader 选举是"可用性 vs 一致性"的典型权衡，业务系统应默认关闭
- Leader Epoch 机制解决了 HW 延迟更新导致的数据截断问题，从 Kafka 0.11 引入

---

## 七、思考题

1. `min.insync.replicas=2` 配置在 Broker 全局级别和 Topic 级别有何区别？如果某个 Topic 没有单独配置，以哪个为准？

2. 3 副本集群中，2 个 Follower 同时缓慢（都在 ISR 内，但 LEO 落后 Leader 很多），此时 acks=all 的 Producer 会遇到什么问题？如何诊断和处理？

---

## 参考资料

> 1. [Apache Kafka 官方文档 3.7 - Replication](https://kafka.apache.org/37/documentation/#replication)
> 2. [KIP-101: Alter Replication Protocol to use Leader Epoch rather than High Watermark](https://cwiki.apache.org/confluence/display/KAFKA/KIP-101)
> 3. *Kafka: The Definitive Guide, 2nd Edition* — 第 5 章 Kafka Internals
> 4. [K-02 Kafka 整体架构深度解析](posts/2026-05-24-kafka-architecture.md)
