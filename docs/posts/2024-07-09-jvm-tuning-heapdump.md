# JVM-04 JVM 调优实战：参数配置、GC 日志与 Heap Dump 分析

<div class="post-meta">📅 2024-07-09 &nbsp;·&nbsp; 🏷️ <span class="tag">JVM</span></div>

> 📚 **本文属于「JVM 原理与调优实战」系列**
> - [JVM-01 JVM 架构总览：类加载、字节码执行与运行时内存](posts/2026-05-27-jvm-architecture.md)
> - [JVM-02 JVM 内存区域详解：六种 OOM 场景与排查实战](posts/2026-05-27-jvm-memory-areas.md)
> - [JVM-03 JVM 垃圾回收器详解：从 CMS 到 ZGC 的演进](posts/2024-05-27-jvm-gc-collectors.md)
> - 👉 **JVM-04 JVM 调优实战：参数配置、GC 日志与 Heap Dump 分析（本文）**

生产服务半夜频繁重启，日志只有 java.lang.OutOfMemoryError: Java heap space。没有 heap dump，没有 GC 日志，运维人员只能重启祈祷。这篇文章的目的是：**在问题发生之前配置好可观测性工具，在问题发生时能快速定位**。

---

## 一、背景：JVM 调优的目标与前提

JVM 调优的目标不是"参数越多越好"，而是针对具体问题找到根因：

| 症状 | 可能原因 | 排查手段 |
|------|---------|---------|
| CPU 持续高 | GC 频繁、死循环、序列化瓶颈 | 线程 dump + GC 日志 |
| 内存持续增长 | 内存泄漏、缓存无限增长 | Heap dump + MAT 分析 |
| 接口延迟抖动 | GC STW 暂停 | GC 日志 + 暂停时间分析 |
| OOM crash | 堆/元空间/直接内存耗尽 | Heap dump on OOM |
| 慢启动 | 类加载慢、JIT 预热 | -verbose:class + JFR |

**调优前提**：先配置好 GC 日志输出和 OOM 时自动导出 heap dump，确保出问题时有数据。

---

## 二、生产环境必配的 JVM 参数

### 2.1 内存配置

```bash
# 堆大小：-Xms 和 -Xmx 设置相同，避免运行中动态扩容导致 Full GC
-Xms4g -Xmx4g

# 新生代大小：通常占堆的 1/3~1/4，具体看应用对象生命周期
-Xmn1g

# 元空间：必须设上限，防止 CGLIB/动态代理无限加载类
-XX:MetaspaceSize=256m
-XX:MaxMetaspaceSize=512m

# 直接内存（NIO/Netty 使用）：默认等于 -Xmx，建议显式指定
-XX:MaxDirectMemorySize=2g

# 栈大小：默认 512k~1m，递归深的应用适当增大
-Xss512k
```
### 2.2 GC 日志配置（JDK 9+ 统一日志框架）

```bash
# JDK 9+ 统一日志框架（推荐）
-Xlog:gc*:file=/logs/gc.log:time,level,tags:filecount=10,filesize=50m

# JDK 8 的 GC 日志配置
-XX:+PrintGCDetails
-XX:+PrintGCDateStamps
-XX:+PrintGCTimeStamps
-Xloggc:/logs/gc.log
-XX:+UseGCLogFileRotation
-XX:NumberOfGCLogFiles=10
-XX:GCLogFileSize=50m
```
### 2.3 OOM 时自动导出 Heap Dump

```bash
# 发生 OOM 时自动导出 heap dump（不需要手动操作，自动触发）
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/logs/heapdump.hprof

# 打印 OOM 时的完整堆栈
-XX:+PrintClassHistogramBeforeFullGC
```
### 2.4 完整生产配置模板

```bash
java \
  -server \
  -Xms4g -Xmx4g \
  -Xmn1g \
  -XX:MetaspaceSize=256m -XX:MaxMetaspaceSize=512m \
  -XX:MaxDirectMemorySize=1g \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  -XX:G1HeapRegionSize=16m \
  -XX:InitiatingHeapOccupancyPercent=45 \
  -Xlog:gc*:file=/logs/gc.log:time,level,tags:filecount=10,filesize=50m \
  -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=/logs/heapdump.hprof \
  -jar app.jar
```
---

## 三、GC 日志分析

### 3.1 读懂 GC 日志

```
# G1 GC 日志示例（JDK 11）
[2024-07-09T10:23:45.123+0800][GC pause (G1 Young Generation) (young), 0.0523 secs]
   [Parallel Time: 45.6 ms, GC Workers: 8]
   [Eden: 512.0M(512.0M)->0.0B(512.0M) Survivors: 64.0M->64.0M Heap: 1536.0M(4096.0M)->1064.0M(4096.0M)]

关键字段：
- "young"：Young GC（仅清理新生代）
- "0.0523 secs"：本次 GC 暂停时间 52.3ms
- Eden: 512M->0B：Eden 区清空
- Heap: 1536M->1064M：堆总使用量从 1.5G 降到 1G
```
```
# Full GC 警告信号
[GC pause (G1 Evacuation Pause) (mixed), 1.2345 secs]  <- mixed GC 超过 1 秒，需关注
[Full GC (Allocation Failure), 5.6789 secs]             <- Full GC，问题严重
```
### 3.2 判断 GC 健康度

| 指标 | 健康 | 需关注 | 告警 |
|------|------|-------|------|
| Young GC 频率 | < 1次/分钟 | 1~5次/分钟 | > 5次/分钟 |
| Young GC 耗时 | < 50ms | 50~200ms | > 200ms |
| Full GC 频率 | 0 | 1次/天 | > 1次/天 |
| GC 占用时间比 | < 5% | 5~15% | > 15% |
| Old Gen 增长趋势 | 稳定 | 缓慢增长 | 持续增长（内存泄漏） |

### 3.3 推荐工具

- **GCEasy**（[gceasy.io](https://gceasy.io)）：上传 GC 日志，自动生成可视化报告
- **GCViewer**：本地工具，可查看 GC 暂停时间分布
- **JDK Mission Control（JMC）**：配合 JFR（Java Flight Recorder）做深度分析

---

## 四、Heap Dump 分析实战

### 4.1 获取 Heap Dump

```bash
# 方式一：OOM 时自动触发（推荐，已在 JVM 参数中配置）
-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/logs/heapdump.hprof

# 方式二：手动触发（不重启，适合内存泄漏排查）
jmap -dump:format=b,file=/tmp/heapdump.hprof <PID>

# 方式三：jcmd（JDK 9+，更安全，不触发 Full GC）
jcmd <PID> GC.heap_dump /tmp/heapdump.hprof

# 注意：4GB 堆的 dump 文件约 2~4GB，确保磁盘空间充足
```
### 4.2 用 MAT（Eclipse Memory Analyzer Tool）分析

1. 下载 MAT：[eclipse.org/mat](https://eclipse.org/mat)
2. 打开 heapdump.hprof
3. 点击 **Leak Suspects Report** 自动分析潜在泄漏

**核心视图**：

```
Leak Suspects Report：
Problem Suspect 1:
  One instance of "com.example.CacheManager" loaded by "app" occupies 2.1 GB (52.3%)
  ^ 这是最可能的泄漏点，CacheManager 持有了 52% 的堆

Dominator Tree（支配树）：
  com.example.CacheManager
    +- HashMap[] (2.1GB)
         +- 大量 UserSession 对象（应该已过期但未被清除）

-> 结论：CacheManager 的 HashMap 没有设置过期策略，用户 Session 对象无限堆积
```
### 4.3 典型内存泄漏场景

```java
// 场景 1：Static 集合持有对象引用
public class CacheManager {
    // ❌ 静态 Map 持有引用，GC 无法回收
    private static final Map<String, Object> cache = new HashMap<>();

    public void add(String key, Object value) {
        cache.put(key, value); // 只增不减，内存持续增长
    }
}

// 场景 2：ThreadLocal 使用后未 remove（线程池场景）
void processRequest(String userId) {
    USER_CONTEXT.set(userId);
    try {
        doWork();
    } finally {
        USER_CONTEXT.remove(); // ✅ 必须！线程池线程复用，不 remove 会泄漏
    }
}

// 场景 3：监听器/回调注册后未注销
eventBus.register(this);  // ✅ 使用后必须 eventBus.unregister(this)
```
---

## 五、高频问题排查 SOP

### 内存持续增长

```bash
# 步骤1：监控堆使用趋势（5分钟一次）
jstat -gcutil <PID> 300000

# 步骤2：确认是堆泄漏还是元空间或直接内存
jcmd <PID> VM.native_memory summary  # 查看各内存区域使用量

# 步骤3：Old Gen 持续增长 -> 导出 heap dump 用 MAT 分析
jcmd <PID> GC.heap_dump /tmp/heap.hprof

# 步骤4：查看 MAT Leak Suspects 报告，找到持有大量内存的对象
```
### GC 频繁/暂停时间长

```bash
# 查看 GC 统计
jstat -gc <PID> 1000 10   # 每秒打印一次，共10次

# 输出示例：
# S0C  S1C  S0U  S1U  EC     EU     OC      OU    MC    MU   YGC  YGCT  FGC  FGCT   GCT
# 512  512  0    512  4096   3500   8192    7500  256   240   150  8.5   2    12.3  20.8
#                                           ^OldGen接近满          ^Full GC 占比高

# 分析：Old Gen 91.5% 使用率，考虑增大堆或排查对象晋升异常
```
---

## 六、总结与延伸

**核心要点**：
- 生产环境必须预先配置 GC 日志和 OOM 自动 dump，否则出问题无从排查
- -Xms 和 -Xmx 设置相同值，避免堆动态扩容触发 Full GC
- Heap dump 分析首选 MAT 的 Leak Suspects 报告，找到最大对象持有者
- 内存泄漏三大常见源头：Static 集合、ThreadLocal 未 remove、监听器未注销

**延伸阅读方向**：
- JVM GC 收集器原理：本站 [JVM 垃圾回收器详解](posts/2024-05-27-jvm-gc-collectors.md)
- Java Flight Recorder（JFR）：JDK 11+ 内置的低开销持续性能分析工具
- Arthas：阿里开源的 Java 在线诊断工具，无需重启、支持热更新
- JVM 内存结构详解：方法区、虚拟机栈、本地方法栈、程序计数器
