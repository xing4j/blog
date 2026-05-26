# K-08 Kafka 消费延迟监控与 Lag 治理

> 📚 **本文属于「Kafka 原理与生产实战」系列**
> - [K-01 Kafka 核心概念与快速上手](posts/2026-05-24-kafka-quickstart.md)
> - [K-02 Kafka 整体架构深度解析](posts/2026-05-24-kafka-architecture.md)
> - [K-03 Producer 原理与最佳实践](posts/2026-05-24-kafka-producer.md)
> - [K-04 Consumer 原理与 Rebalance 治理](posts/2026-05-24-kafka-consumer-rebalance.md)
> - [K-05 存储机制：Log 文件与索引详解](posts/2026-05-24-kafka-storage.md)
> - [K-06 高可用：副本同步与 Leader 选举](posts/2026-05-24-kafka-ha-replica.md)
> - [K-07 吞吐量调优实战](posts/2026-05-24-kafka-throughput-tuning.md)
> - 👉 **K-08 消费延迟监控与 Lag 治理（本文）**
> - [K-09 事务消息与 Exactly-Once 语义](posts/2026-05-24-kafka-exactly-once.md)
> - [K-10 KRaft 模式：去 ZooKeeper 实战](posts/2026-05-24-kafka-kraft.md)

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 28 分钟｜**分类**：中间件

---

## 导读

Consumer Lag（消费延迟）是 Kafka 生产运维最核心的健康指标。Lag 飙升意味着消息积压，轻则业务延迟，重则触发雪崩。本文系统讲解 Lag 的计算原理、监控体系的建立、告警策略，以及从"扩分区"到"优化消费逻辑"的完整治理路径，并结合一个生产中排查 Lag 飙升的真实案例。

---

## 一、Consumer Lag 的本质

**Consumer Lag = Partition 的 LEO（Log End Offset） - Consumer 已提交的 Offset**

```
Partition 0:
  LEO = 10000（Broker 已写入到这里）
  Consumer Committed Offset = 8000（Consumer 消费并提交到这里）
  Lag = 10000 - 8000 = 2000（积压了 2000 条消息）
```

整个 Consumer Group 的总 Lag = 所有订阅分区的 Lag 之和。

**Lag 的危害程度取决于场景**：
- 实时风控系统：Lag > 100 就告警
- 日志归档系统：Lag > 100 万也可接受
- 订单通知系统：Lag > 10000 就可能造成用户体验问题

---

## 二、Lag 监控方法

### 2.1 命令行查看（运维排查用）

```shell
# 查看指定 Consumer Group 的 Lag
kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group order-processing-group

# 输出示例：
# GROUP                   TOPIC          PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
# order-processing-group  order-created  0          8000            10000           2000
# order-processing-group  order-created  1          9500            9800            300
# order-processing-group  order-created  2          7200            11000           3800
```

### 2.2 JMX 指标（监控系统接入）

Kafka Broker 通过 JMX 暴露 Lag 相关指标：

```
# 每个 Consumer Group + Partition 的 Offset Lag
kafka.consumer.group:type=ConsumerGroupMetrics,name=ConsumerLag,
  group=order-processing-group,topic=order-created,partition=0

# 整个 Consumer Group 的 Max Lag（所有分区中最大的 Lag）
kafka.consumer.group:type=ConsumerGroupMetrics,name=ConsumerMaxLag,
  group=order-processing-group
```

### 2.3 Kafka Exporter + Prometheus + Grafana（推荐方案）

生产环境推荐用 [kafka-exporter](https://github.com/danielqsj/kafka_exporter) 将 JMX 指标转为 Prometheus 格式：

```yaml
# docker-compose.yml —— 部署 kafka-exporter
services:
  kafka-exporter:
    image: danielqsj/kafka-exporter:latest
    command:
      - '--kafka.server=broker1:9092'
      - '--kafka.server=broker2:9092'
      - '--kafka.server=broker3:9092'
    ports:
      - "9308:9308"
```

**核心 Prometheus 告警规则**：

```yaml
# prometheus-rules.yml
groups:
  - name: kafka_lag_alerts
    rules:
      - alert: KafkaConsumerLagHigh
        expr: kafka_consumergroup_lag > 10000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Consumer Group {{ $labels.consumergroup }} Lag 过高"
          description: "Topic {{ $labels.topic }} Partition {{ $labels.partition }} Lag = {{ $value }}"

      - alert: KafkaConsumerLagCritical
        expr: kafka_consumergroup_lag > 100000
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Consumer Group {{ $labels.consumergroup }} 消息严重积压"
```

**Grafana Dashboard** 推荐使用 Dashboard ID [7589](https://grafana.com/grafana/dashboards/7589)，开箱即用。

---

## 三、Lag 飙升原因分析

### 3.1 生产侧突增

Producer 端写入量突然激增（如大促、秒杀），超过消费侧处理能力。

**诊断**：
```shell
# 查看 Topic 的写入速率（messages/sec）
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group __kafka_internal_offsets_monitor  # 不存在，换成观察 log-end-offset 增长速率
```

用监控面板观察 `kafka_topic_partition_current_offset` 的增长速率，与 Consumer Group 的 Offset 提交速率对比。

### 3.2 消费侧变慢

最常见的原因：
1. **下游依赖变慢**：数据库慢查询、外部 HTTP 接口超时
2. **消费逻辑出现异常**：大量重试、死循环
3. **Rebalance 频繁**：消费暂停期间 Lag 快速累积（参见 [K-04](posts/2026-05-24-kafka-consumer-rebalance.md)）
4. **GC 暂停**：Consumer JVM GC 停顿过长

**诊断步骤**：
```shell
# 1. 查看 Consumer 实例是否存活及分区分配
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group order-processing-group

# 2. 如果 CONSUMER-ID 列为空，说明消费者已断开（Rebalance 或宕机）

# 3. 查看 Consumer 应用日志，搜索关键字：
#    - "Rebalance"
#    - "CommitFailedException"
#    - "poll() interval exceeded"
#    - 数据库/HTTP 超时异常栈
```

### 3.3 分区数不足

消费者数量已达上限（= 分区数），但处理能力仍不足，需要扩分区。

---

## 四、Lag 治理方案

### 4.1 方案一：扩消费者（无需停服）

适用条件：消费者数量 < 分区数，且单消费者 CPU/线程不是瓶颈。

```shell
# 直接横向扩容 Consumer 实例（K8s 场景）
kubectl scale deployment order-consumer --replicas=6

# 扩容后触发 Rebalance，新 Consumer 接管部分分区
# 消费速率提升约：(新实例数 / 旧实例数) 倍
```

### 4.2 方案二：扩分区（需评估影响）

适用条件：消费者数 = 分区数（已达并发上限），需要更高并发。

```shell
# 扩分区（只能增加，不能减少）
kafka-topics.sh --bootstrap-server localhost:9092 \
  --alter --topic order-created \
  --partitions 12  # 从 6 扩到 12

# 注意：扩分区后同步扩容 Consumer 实例，否则无效
# 注意：基于 Key Hash 路由的消息，扩分区后同 Key 可能路由到不同分区，影响顺序性
```

**扩分区的副作用**：
- 原来路由到 Partition-0 的 Key（如订单 ID），扩分区后可能路由到 Partition-7
- 新旧分区的消息顺序保障会断裂，需要业务侧评估影响

### 4.3 方案三：优化消费逻辑

当瓶颈在消费侧处理逻辑本身时，扩分区和扩实例都治标不治本：

```java
// JDK 17 + kafka-clients 3.7.0 —— 批量处理优化示例
// 问题：原来逐条写数据库，每条消息一次数据库操作
for (ConsumerRecord<String, String> record : records) {
    orderRepository.save(parseOrder(record.value()));  // N 次数据库写入
}

// 优化：批量写入数据库，N 条消息一次数据库操作
List<Order> orders = new ArrayList<>();
for (ConsumerRecord<String, String> record : records) {
    orders.add(parseOrder(record.value()));
}
orderRepository.batchSave(orders);  // 1 次批量写入，性能提升约 10~50 倍
consumer.commitSync();
```

### 4.4 方案四：临时加速消费（从历史 Offset 追赶）

Lag 积压量巨大时，可以临时启动专用的"追赶组"：

```shell
# 创建临时消费组，从当前积压位置开始消费历史消息
# 注意：这是独立的 Consumer Group，不影响正常消费组

kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group catchup-group-tmp \
  --topic order-created \
  --reset-offsets \
  --to-offset 8000 \  # 从 offset=8000 开始
  --execute
```

---

## 五、生产案例：大促期间 Lag 飙升排查

**背景**：某电商平台 11.11 大促，凌晨 0 点后订单通知 Consumer Group 的 Lag 从平均 200 飙升至 80 万，通知严重延迟。

**排查过程**：

```
Step 1：查看 Consumer Group 状态
  → Consumer 实例都存活，分区分配正常
  → 排除 Rebalance 和实例宕机

Step 2：查看 Lag 增长曲线
  → LEO（生产速率）从 5000 msg/s 突增至 50000 msg/s（大促流量）
  → Consumer 提交 Offset 增长速率仍是 5000 msg/s
  → 生产/消费速率比 = 10:1，消费侧成为瓶颈

Step 3：查看消费者 GC 日志
  → 正常，无异常 GC

Step 4：查看消费者应用日志
  → 发现通知发送（调用短信平台 HTTP API）P99 延迟从 50ms 升至 800ms
  → 短信平台被大促流量压垮，响应变慢

Step 5：根本原因
  → 消费者单线程 + HTTP 调用阻塞，实际并发处理能力 = 1000ms / 800ms ≈ 1.2 条/线程/秒
  → 6 个 Consumer 实例 × 1.2 条/秒 = 约 7 条/秒（远低于 50000 msg/s）
```

**应急处理**：
1. 降级：短信通知改为异步投递（写入另一个低优先级 Topic，24 小时内补发）
2. 扩容：Consumer 实例从 6 个扩到 24 个，分区从 6 个扩到 24 个
3. 限流：对通知 Topic 设置 Consumer 端 `max.poll.records=50` 配合批量发送

**最终结果**：Lag 在 40 分钟内从 80 万降至正常水位（< 1000）。

---

## 六、踩坑总结

❌ **只监控 Consumer Group 总 Lag，忽略分区级 Lag 不均衡**  
✅ 某个分区 Lag 极高而其他分区正常，通常是该分区的消费者出现问题（OOM、网络断开等）。监控系统必须细化到**分区级**，而非只看总量。

❌ **扩分区解决 Lag 后，同 Key 消息顺序被打乱，引发业务 Bug**  
✅ 扩分区前务必评估：哪些业务依赖同 Key 消息的顺序性？可以在扩分区后，对历史消息重新路由（临时写入新分区），或在消费逻辑中加业务层排序。

---

## 七、文章小结

- Consumer Lag = LEO - 已提交 Offset，是反映消费健康状况的核心指标
- kafka-exporter + Prometheus + Grafana 是生产级 Lag 监控的主流方案
- Lag 飙升的根因排查顺序：生产侧突增 → 消费侧变慢 → Rebalance → 分区数不足
- 治理方案选择：消费者 < 分区数时先扩实例；已达上限时扩分区并同步扩实例；下游依赖慢时优化消费逻辑
- 批量写入是消费侧最高效的性能优化手段，可将吞吐量提升数十倍

---

## 八、思考题

1. 某 Consumer Group 的 Lag 长期在 5000~8000 之间波动，既不增长也不清零，这种情况意味着什么？如何定性它是"正常波动"还是"慢性积压"？

2. 如果要对 Lag 设置告警，除了绝对值（Lag > N），还有什么维度更能反映问题的严重程度？

---

## 参考资料

> 1. [Apache Kafka 官方文档 3.7 - Monitoring](https://kafka.apache.org/37/documentation/#monitoring)
> 2. [kafka-exporter GitHub](https://github.com/danielqsj/kafka_exporter)
> 3. [Grafana Dashboard for Kafka Overview (ID: 7589)](https://grafana.com/grafana/dashboards/7589)
> 4. [K-04 Consumer 原理与 Rebalance 治理](posts/2026-05-24-kafka-consumer-rebalance.md)
