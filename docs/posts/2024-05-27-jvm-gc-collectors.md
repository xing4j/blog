# JVM-03 JVM 垃圾回收器详解：从 CMS 到 ZGC 的演进

<div class="post-meta">📅 2024-05-27 &nbsp;·&nbsp; 🏷️ <span class="tag">JVM</span></div>

> 📚 **本文属于「JVM 原理与调优实战」系列**
> - [JVM-01 JVM 架构总览：类加载、字节码执行与运行时内存](posts/2026-05-27-jvm-architecture.md)
> - [JVM-02 JVM 内存区域详解：六种 OOM 场景与排查实战](posts/2026-05-27-jvm-memory-areas.md)
> - 👉 **JVM-03 JVM 垃圾回收器详解：从 CMS 到 ZGC 的演进（本文）**
> - [JVM-04 JVM 调优实战：参数配置、GC 日志与 Heap Dump 分析](posts/2024-07-09-jvm-tuning-heapdump.md)

服务 P99 延迟偶发抖动，监控显示规律性的几百毫秒暂停——GC STW（Stop-The-World）是最常见的元凶。了解各代 GC 收集器的设计目标、工作机制和适用场景，是 JVM 调优的基础。

---

## 一、背景：垃圾回收要解决什么问题

JVM 自动内存管理的核心是**找出哪些对象不再被引用（垃圾），然后回收其占用的内存**。GC 的核心挑战是在三个目标之间取得平衡：

```
       吞吐量（Throughput）
      /         \
     /  三角平衡   \
暂停时间（Latency） —— 内存占用（Footprint）
```
- **高吞吐量**：让 GC 少打断业务线程，批处理首选
- **低延迟**：让每次 GC 暂停时间尽量短，在线服务首选
- **低内存占用**：适合嵌入式或内存受限环境

不同 GC 收集器在这三个维度上做了不同的取舍。

---

## 二、堆内存结构基础

GC 基于**分代假说**（大多数对象"朝生夕死"）将堆分区管理：

```
+------------------------------------------------------+
|                      JVM Heap                        |
|  +------------------------+  +----------------------+|
|  |      Young Gen          |  |       Old Gen        ||
|  |  +------+------+------+|  |   Long-lived Objects   ||
|  |  | Eden |  S0  |  S1  ||  |                      ||
|  |  +------+------+------+|  +----------------------+|
|  +------------------------+                           |
|                   +--------------+                    |
|                   |  Metaspace   |  (off-heap)       |
|                   +--------------+                    |
+------------------------------------------------------+
```
- **Minor GC**：只回收 Young Gen，频率高，速度快（通常 < 10ms）
- **Full GC / Major GC**：回收整个堆，暂停时间长（秒级），需要尽量避免
- **Mixed GC**（G1 特有）：同时回收 Young Gen 和部分 Old Gen，在两者间取得平衡

---

## 三、各代 GC 收集器演进

### 3.1 Serial GC（-XX:+UseSerialGC）

**定位**：单线程，Client 模式，嵌入式/小程序

```
GC 期间：
业务线程 -------------- STW --------------> 业务线程
                  单 GC 线程工作
```
- Young Gen：标记-复制（Serial）
- Old Gen：标记-整理（Serial Old）
- **优点**：简单，无线程切换开销；**缺点**：STW 时间长，不适合交互应用

### 3.2 Parallel GC（-XX:+UseParallelGC，JDK 8 默认）

**定位**：多线程，高吞吐量，批处理

```
GC 期间：
业务线程1 ---- STW ----> 
业务线程2 ---- STW ---->  多 GC 线程并行工作（缩短 STW）
业务线程3 ---- STW ---->
```
- Young + Old 都使用多线程并行，吞吐量比 Serial 大幅提升
- 关键参数：-XX:ParallelGCThreads=N（通常等于 CPU 核数）
- **适用场景**：对延迟不敏感的批处理、计算密集型应用

### 3.3 CMS（-XX:+UseConcMarkSweepGC，JDK 9 废弃，14 移除）

**定位**：低延迟，与业务线程并发标记

```
业务线程  -----+--- STW --+----------------------+-- STW --+----->
              | InitMk | Concurrent Mark|Remark| Sweep
GC 线程        +----------+                        +---------+
```
四个阶段：
1. **初始标记（STW，极短）**：只标记 GC Roots 直接可达的对象
2. **并发标记（并发）**：与业务线程同时运行，标记全部存活对象
3. **重新标记（STW，短）**：修正并发标记阶段产生的变化
4. **并发清除（并发）**：与业务线程同时清除垃圾

**CMS 的问题**：
- 使用标记-清除，产生**内存碎片**，长时间运行后触发 Full GC（标记-整理）
- 并发模式失败（Concurrent Mode Failure）：Old Gen 未满就 GC，但回收速度赶不上分配速度

### 3.4 G1（-XX:+UseG1GC，JDK 9+ 默认）

**定位**：可预测低延迟 + 高吞吐量兼顾，大内存（4GB+）首选

**核心创新**：将堆划分为若干等大的 **Region**（默认 1~32MB），不再固定 Young/Old 区位置，每个 Region 可以动态地成为 Eden/Survivor/Old/Humongous：

```
+----+----+----+----+----+----+
| E  | E  | S  | O  | H  | O  |  Region 动态分配
+----+----+----+----+----+----+  E=Eden, S=Survivor
| O  | E  | O  | E  | O  | S  |  O=Old,  H=Humongous
+----+----+----+----+----+----+
```
**关键机制**：
- 优先回收垃圾最多的 Region（Garbage First），最大化回收效率
- Remembered Set：每个 Region 记录外部引用指针，无需全堆扫描
- Mixed GC：Young GC + 选择性 Old Region GC，增量回收，控制 STW 时间

**核心参数**：
```bash
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200        # 期望最大暂停时间（软目标），默认 200ms
-XX:G1HeapRegionSize=16m        # Region 大小，堆大时适当增大
-XX:InitiatingHeapOccupancyPercent=45  # Old Gen 占用多少时触发并发标记
```
### 3.5 ZGC（-XX:+UseZGC，JDK 15 正式可用）

**定位**：极低延迟（亚毫秒），适合超大堆（TB 级）

**核心技术**：
- **着色指针（Colored Pointers）**：在 64 位指针中用 4 位存储 GC 元数据，无需 Write Barrier 扫描对象头
- **读屏障（Load Barrier）**：对象引用读取时触发，实现并发重定位
- 几乎全程并发，STW 只有初始标记和最终标记两个极短阶段（通常 < 1ms）

```
ZGC 阶段（大部分并发）：
并发标记 -> 并发预备重定位 -> 并发重定位 -> 并发重映射
  STW              并发                   并发
(< 1ms)
```
**适用场景**：
- 对 P99/P999 延迟极度敏感的在线服务
- 超大内存服务（> 32GB），G1 的 STW 时间随堆增大而增大，ZGC 则几乎不受影响

### 3.6 Shenandoah（-XX:+UseShenandoahGC）

RedHat 开发，与 ZGC 目标相似（低延迟），使用**并发压缩（Concurrent Compaction）**通过 Brook Forwarding Pointer 实现并发移动对象。JDK 12 进入主线。

---

## 四、选型对比

| GC 收集器 | 适用场景 | 延迟 | 吞吐量 | 内存占用 | 推荐 JDK |
|---------|---------|------|-------|---------|---------|
| Serial | 客户端、嵌入式，< 100MB | 高 STW | 低 | 最小 | 任意 |
| Parallel | 批处理、计算任务，> 4GB | 中 STW | 最高 | 小 | JDK 8（默认）|
| CMS | 低延迟老应用（已废弃）| 低 STW | 中 | 中 | JDK ≤ 8 |
| **G1** | **通用在线服务，4~32GB** | **低** | **高** | **中** | **JDK 9+（默认）**|
| **ZGC** | **超低延迟，大内存 > 32GB** | **亚毫秒** | **中** | **大** | **JDK 15+** |
| Shenandoah | 低延迟，中等内存 | 极低 | 中 | 大 | JDK 12+ |

---

## 五、常见坑点与最佳实践

### 坑 1：JDK 8 默认 GC 并非 G1

JDK 8 的 Server 模式默认是 **Parallel GC**（高吞吐），不是 G1。如果要低延迟，需要显式指定 -XX:+UseG1GC。

### 坑 2：调小 MaxGCPauseMillis 并非无代价

```bash
# ❌ 过于激进：G1 为了控制暂停时间，每次回收 Region 数量减少，回收频率升高
-XX:MaxGCPauseMillis=50

# ✅ 合理值：200ms 是官方默认，多数在线服务可接受
-XX:MaxGCPauseMillis=200
```
G1 的暂停目标是"软目标"，不保证每次都达到，但会以此调整回收策略。

### 坑 3：大对象（Humongous Object）绕过 Young GC

G1 中，大于 Region 大小 50% 的对象直接分配到 Humongous Region，不经过 Young GC，需要 Mixed GC 才能回收。大量大对象会导致 Mixed GC 频繁触发。

```bash
# 监控 Humongous 分配
-Xlog:gc+humongous=debug
```
### 坑 4：元空间（Metaspace）溢出不是堆 OOM

类加载过多（如 CGLIB 动态代理、频繁热部署）会导致 Metaspace OOM。需要设置上限并监控：

```bash
-XX:MetaspaceSize=256m          # 初始大小（触发 Full GC 的阈值）
-XX:MaxMetaspaceSize=512m       # 上限，防止无限增长
```
---

## 六、总结与延伸

**核心要点**：
- GC 在吞吐量、延迟、内存三者之间取舍；没有万能最优方案
- JDK 9+ 默认 G1，适合大多数在线服务；超低延迟场景选 ZGC（JDK 15+）
- G1 关键参数：-XX:MaxGCPauseMillis（目标暂停时间）和 Region 大小
- 大对象、Metaspace 溢出是常见但容易忽略的 GC 问题

**延伸阅读方向**：
- JVM GC 日志分析：-Xlog:gc*:file=gc.log:time,level,tags + GCViewer/GCEasy 工具
- G1 Evacuation Failure（疏散失败）：Old Gen 空间不足时的处理机制
- ZGC 的着色指针与读屏障实现原理（OpenJDK 源码）
- JVM 调优案例实战：本站 [JVM 调优实战：参数配置与 Heap Dump 分析](posts/2024-07-09-jvm-tuning-heapdump.md)
