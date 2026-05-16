# JVM 垃圾回收器对比：G1 / ZGC / Shenandoah

<div class="post-meta">📅 2024-05-27 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">JVM</span></div>

选对 GC 回收器对应用的吞吐量和延迟有决定性影响。本文对比三款现代 GC 回收器的设计目标、工作原理及适用场景。

---

## 一、GC 回收器发展脉络

```
Serial / Parallel → CMS → G1 → ZGC / Shenandoah
（停顿为主）      （低延迟）（可预测停顿）（超低延迟）
```

Java 9 起 G1 成为默认回收器；Java 11 引入 ZGC；Java 12 引入 Shenandoah（OpenJDK）。

---

## 二、G1（Garbage First）

### 设计目标
在**可预测停顿时间**内完成回收，默认目标 ≤ 200ms，兼顾吞吐量。

### 核心思想：Region 化堆

```
┌────┬────┬────┬────┬────┬────┬────┬────┐
│ E  │ S  │ O  │ E  │ H  │ O  │ E  │ S  │  E=Eden S=Survivor O=Old H=Humongous
└────┴────┴────┴────┴────┴────┴────┴────┘
 每个 Region 约 1~32MB，动态分配角色
```

### 回收流程

1. **Minor GC（Young GC）**：收集 Eden + Survivor
2. **Concurrent Marking**：并发标记存活对象（与应用线程同时运行）
3. **Mixed GC**：同时收集 Young + 部分 Old（优先回收垃圾最多的 Region）
4. **Full GC**（应急）：单线程，STW，应尽量避免

### 关键参数

```bash
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200          # 目标最大停顿时间（毫秒）
-XX:G1HeapRegionSize=8m           # Region 大小（1~32MB，2 的幂次）
-XX:InitiatingHeapOccupancyPercent=45  # 触发并发标记的堆占用阈值
-XX:G1ReservePercent=10           # 预留空间防止晋升失败
```

---

## 三、ZGC（Z Garbage Collector）

### 设计目标
**亚毫秒级停顿**（< 1ms），停顿时间不随堆大小增长（支持 TB 级堆）。Java 15 起转为正式可用。

### 核心技术

**染色指针（Colored Pointers）**：将 GC 元数据编码到指针的高位 bits，无需读写屏障即可实现并发对象移动。

```
63      44 43  42 41  40 39                0
┌─────────┬────┬────┬────┬─────────────────┐
│ 保留位   │ M1 │ M0 │Fin │    对象地址      │
└─────────┴────┴────┴────┴─────────────────┘
 M1/M0=标记位  Fin=Finalizable
```

**读屏障（Load Barrier）**：每次从堆中读取引用时，检查并修正指针。

### STW 阶段（极短）

| 阶段 | 作用 | 典型时间 |
|------|------|---------|
| Pause Mark Start | 标记 GC Roots | < 1ms |
| Pause Mark End | 同步标记结果 | < 1ms |
| Pause Relocate Start | 开始并发移动 | < 1ms |

其余全部并发完成，停顿时间**与堆大小无关**。

### 关键参数

```bash
-XX:+UseZGC
-XX:ZAllocationSpikeTolerance=2   # 分配速率尖刺容忍度
-XX:ZCollectionInterval=0         # 主动 GC 间隔（0=禁用）
-Xmx32g -Xms32g                  # 建议堆内存固定（避免扩缩容）
```

---

## 四、Shenandoah

### 设计目标
与 ZGC 类似，追求**超低停顿**，但实现路径不同：通过**转发指针（Brooks Pointer）** 实现并发移动。

### 与 ZGC 的核心区别

| 维度 | ZGC | Shenandoah |
|------|-----|-----------|
| 并发移动实现 | 染色指针 + 读屏障 | 转发指针 + 读/写屏障 |
| 写屏障 | 不需要 | 需要 |
| 适用 JDK | Oracle JDK / OpenJDK | 主要 OpenJDK |
| Region 大小 | 动态（2MB/32MB/Large）| 固定（可配置）|

---

## 五、三款回收器横向对比

| 维度 | G1 | ZGC | Shenandoah |
|------|-----|-----|-----------|
| **停顿时间** | 可配置（默认 200ms）| < 1ms | < 10ms |
| **吞吐量** | 高 | 略低（读屏障开销）| 略低 |
| **堆大小** | 4GB ~ 数十 GB | 8MB ~ 16TB | 中等 |
| **内存占用** | 较高（Remember Set）| 较高（多映射）| 中等 |
| **生产成熟度** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| **推荐 Java 版本** | 8+ | 15+ | 12+（OpenJDK）|

---

## 六、选型建议

```
追求低延迟（API 服务、游戏服务器）
  ├─ Java 21+，堆 < 1TB → ZGC（推荐，亚毫秒停顿）
  └─ OpenJDK，要求更低堆占用 → Shenandoah

追求高吞吐（批处理、大数据计算）
  └─ G1（默认）或 ParallelGC

堆 > 100GB
  └─ ZGC（唯一可用选项）
```

---

## 总结

- **G1**：均衡选手，默认推荐，可预测停顿，适合绝大多数业务
- **ZGC**：停顿时间与堆无关，适合超大堆或对延迟极敏感的服务，Java 21 进一步优化了吞吐
- **Shenandoah**：思路与 ZGC 类似，OpenJDK 生态更友好，但生产成熟度稍低
