# JVM-08 JVM 诊断工具全景：JFR/JMC、Arthas、async-profiler 选型与实战速查

<div class="post-meta">📅 2026-05-28 &nbsp;·&nbsp; 🏷️ <span class="tag">JVM</span></div>

> 📚 **本文属于「JVM 原理与调优实战」系列**
> - [JVM-01 JVM 架构总览：类加载、字节码执行与运行时内存](posts/2026-05-27-jvm-architecture.md)
> - [JVM-02 JVM 内存区域详解：六种 OOM 场景与排查实战](posts/2026-05-27-jvm-memory-areas.md)
> - [JVM-03 JVM 垃圾回收器详解：从 CMS 到 ZGC 的演进](posts/2024-05-27-jvm-gc-collectors.md)
> - [JVM-04 JVM 调优实战：参数配置、GC 日志与 Heap Dump 分析](posts/2024-07-09-jvm-tuning-heapdump.md)
> - [JVM-05 内存泄漏排查实战：ThreadLocal、静态集合与监听器三大模式](posts/2026-05-28-jvm-memory-leak.md)
> - [JVM-06 线程 Dump 实战分析：死锁、线程饥饿与线程泄漏识别](posts/2026-05-28-jvm-thread-dump.md)
> - [JVM-07 类加载机制与双亲委派：破坏场景、热部署与 Metaspace 泄漏](posts/2026-05-28-jvm-classloading.md)
> - 👉 **JVM-08 JVM 诊断工具全景：JFR/JMC、Arthas、async-profiler 选型与实战速查（本文）**

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 35 分钟｜**分类**：Java 核心

同样是 JVM 性能问题，用 `System.out.println` 埋点排查和用 JFR 火焰图定位，效率相差可以是几十倍。JVM 诊断工具体系庞杂：JDK 自带的 jstat/jstack/jmap、生产级 profiler JFR/async-profiler、在线热修复利器 Arthas——每种工具解决不同层面的问题，滥用或误用反而增加噪音。本文按"问题类型 → 工具选择 → 具体操作"的思路，给出一份可直接在生产环境参考的实战速查手册。

---

## 一、工具全景：问题类型与工具选择

### 1.1 选型矩阵

| 问题类型 | 首选工具 | 备选 | 不推荐 |
|---------|---------|------|--------|
| CPU 热点代码 | async-profiler | JFR + JMC | jstack 采样（精度低）|
| 内存泄漏/OOM | MAT + Heap Dump | JFR 内存事件 | jmap（触发 Full GC）|
| 线程死锁/饥饿 | Arthas `thread` | jstack | — |
| GC 行为分析 | GC 日志 + GCViewer | JFR GC 事件 | — |
| 方法耗时（在线） | Arthas `trace` | JFR 方法采样 | — |
| 类加载/Metaspace | jcmd VM.metaspace | MAT ClassLoader | — |
| 线上代码热修复 | Arthas `redefine` | — | — |
| 全量系统事件 | JFR + JMC | — | 生产 jprofiler（开销大）|

### 1.2 工具开销对比

| 工具 | CPU 开销 | 内存开销 | 是否可生产使用 |
|------|---------|---------|--------------|
| JFR（默认配置）| < 1% | 约 10-20 MB | ✅ 推荐 |
| async-profiler | 1-3% | 约 5 MB | ✅ 推荐 |
| Arthas trace | 5-30%（按调用量）| 低 | ⚠️ 高流量慎用 |
| jmap（live）| 触发 Full GC，STW | — | ❌ 慎用 |
| JProfiler/YourKit | 10-30% | 高 | ❌ 不推荐生产 |

---

## 二、JDK 内置工具速查

### 2.1 常用命令一览

```bash
# ----- jps：查看 JVM 进程 -----
jps -l
# 输出：12345 com.example.Application

# ----- jstat：GC 统计 -----
# 每 3 秒输出一次，共 5 次
jstat -gcutil <pid> 3000 5
# 列：S0 S1 E(Eden) O(Old) M(Metaspace) YGC YGCT FGC FGCT GCT

# ----- jstack：线程 Dump -----
jstack -l <pid> > thread.txt   # -l 包含锁信息

# ----- jcmd：多功能诊断（推荐替代 jmap/jstack）-----
jcmd <pid> help                          # 列出所有可用命令
jcmd <pid> Thread.print                  # 线程 dump
jcmd <pid> GC.heap_dump /tmp/heap.hprof  # heap dump（不触发 Full GC）
jcmd <pid> VM.metaspace                  # Metaspace 详情
jcmd <pid> VM.flags                      # 当前 JVM 参数
jcmd <pid> GC.run                        # 触发一次 GC
jcmd <pid> VM.native_memory              # 本地内存跟踪（需启动时加 -XX:NativeMemoryTracking=detail）
```

### 2.2 jstat 输出解读

```
# jstat -gcutil 12345 3000 5 的典型输出：
  S0     S1     E      O      M     CCS    YGC     YGCT    FGC    FGCT     GCT
   0.00  98.52  12.34  45.21  97.12  95.34    234   2.341     2   0.456   2.797
   0.00  98.52  34.56  45.21  97.12  95.34    234   2.341     2   0.456   2.797
   0.00   0.00   8.12  47.89  97.12  95.34    235   2.352     2   0.456   2.808
   0.00  98.12  21.34  47.89  97.12  95.34    235   2.352     2   0.456   2.808
   0.00  98.12  45.67  50.23  97.12  95.34    236   2.363     3   0.612   2.975
```

解读要点：
- `O` 列（Old Gen）：每次 Full GC 后基线上升 → 内存泄漏
- `FGC` 列：频率高（每分钟超 1 次）→ 需优化
- `YGC` 列：高频 YGC（每秒多次）→ 对象分配速率过高
- `M` 列接近 100%：Metaspace 接近上限 → 需扩容或排查类加载泄漏

---

## 三、JFR（Java Flight Recorder）

### 3.1 什么是 JFR

JFR 是 JDK 内置的**低开销持续性能记录器**，JDK 11+ 完全免费开放（早期是 Oracle JDK 商业特性）。它以环形缓冲区方式持续记录 JVM 内部事件（GC、锁、IO、方法采样等），CPU 开销 < 1%，可以在生产环境 7×24 小时开启。

### 3.2 启动与采集

```bash
# 方式一：JVM 启动时开启（推荐，持续录制）
java -XX:StartFlightRecording=duration=0,filename=/tmp/app.jfr,
     settings=profile,maxsize=256m \
     -jar app.jar
# duration=0 表示持续录制，maxsize 限制文件大小（环形缓冲，自动覆盖旧数据）

# 方式二：运行中动态开启（不重启）
jcmd <pid> JFR.start name=myrecording duration=60s filename=/tmp/app.jfr settings=profile
# 录制 60 秒后自动停止并写出文件

# 查看录制状态
jcmd <pid> JFR.check

# 手动停止并保存
jcmd <pid> JFR.stop name=myrecording filename=/tmp/app.jfr

# settings 选项：
# default  - 低开销，适合长期监控（CPU < 0.3%）
# profile  - 更多数据，包含方法采样（CPU < 1%，推荐问题排查时用）
```

### 3.3 JMC（Java Mission Control）分析 JFR 文件

JMC 是 JFR 文件的可视化分析工具（免费下载：[jdk.java.net/jmc](https://jdk.java.net/jmc/)）。

打开 `.jfr` 文件后，关键视图：

```
JMC 主要分析页签：

1. Automated Analysis（自动分析）
   - 一键生成性能问题摘要，标注严重程度
   - 直接告诉你：GC 占用了多少 CPU、哪些方法热点最高

2. Method Profiling（方法性能）
   - 火焰图 + 调用树
   - 找到 CPU 热点方法

3. Memory（内存）
   - Heap 使用趋势
   - 对象分配热点（哪些方法分配对象最多）

4. GC（垃圾回收）
   - GC 暂停时间分布
   - GC 各阶段耗时详情

5. Threads（线程）
   - 线程状态时序图
   - 锁竞争热点
```

### 3.4 生产实践：持续录制 + 触发式保存

```bash
# 最佳实践：在 JVM 启动参数中加入持续录制
-XX:StartFlightRecording=disk=true,maxsize=500m,maxage=24h,
  settings=default,dumponexit=true,filename=/var/log/jfr/app.jfr

# dumponexit=true：JVM 退出时自动保存（适合捕获 OOM 崩溃前的状态）
# maxage=24h：只保留最近 24 小时的事件（自动清理旧数据）
```

问题发生时手动触发快照（保留环形缓冲中最近 5 分钟）：

```bash
jcmd <pid> JFR.dump filename=/tmp/incident.jfr maxage=5m
```

---

## 四、async-profiler：CPU 热点与火焰图

### 4.1 为什么需要 async-profiler

JFR 的方法采样基于 JVM SafePoint（安全点），在安全点间隔长的方法中（如 GC、JIT 编译）存在**SafePoint 偏差**，可能漏掉真正的 CPU 热点。

async-profiler 使用 `AsyncGetCallTrace` API（不依赖 SafePoint）+ Linux `perf_events`，采样更精准，还能同时捕获本地代码（JNI、GC 代码）的开销。

### 4.2 安装与使用

```bash
# 下载（Linux x64）
wget https://github.com/async-profiler/async-profiler/releases/download/v3.0/
     async-profiler-3.0-linux-x64.tar.gz
tar -xzf async-profiler-3.0-linux-x64.tar.gz

# 采集 CPU 热点 30 秒，生成火焰图
./asprof -d 30 -f /tmp/cpu.html <pid>
# 在浏览器打开 cpu.html，查看交互式火焰图

# 采集内存分配热点（哪些方法分配对象最多）
./asprof -e alloc -d 30 -f /tmp/alloc.html <pid>

# 采集锁竞争热点
./asprof -e lock -d 30 -f /tmp/lock.html <pid>

# 同时采集 CPU + 分配（JVMTI 方式，更精确）
./asprof -e cpu,alloc -d 30 -f /tmp/combined.jfr <pid>
```

### 4.3 火焰图阅读方法

```
火焰图规则：
- X 轴：采样宽度（越宽 = 占用 CPU 时间越多），不是时间轴
- Y 轴：调用栈深度（底部 = 入口，顶部 = 叶子方法）
- 颜色：随机（无特殊含义），只是为了视觉区分
- 宽平台顶部 = 热点：CPU 大量消耗在这个方法，没有进一步调用

          +---------+
          |parseJSON|  <- 宽平台：CPU 热点，值得优化
    +-----+---------+----+
    | deserialize        |
  +-+--------------------+--+
  |    OrderController.post  |
+-+--------------------------+--+
|    Thread (http-exec-1)       |
```

### 4.4 典型火焰图问题识别

| 火焰图特征 | 可能问题 |
|-----------|---------|
| 顶部宽平台在 GC 相关方法 | GC 开销过大 |
| 顶部宽平台在正则匹配/JSON 解析 | 频繁解析，可缓存或优化 |
| `java/lang/String.intern` 占比高 | 字符串驻留滥用，Metaspace 压力 |
| 大量 `sun.misc.Unsafe.park` | 线程等待（锁、IO、队列）|
| `ThreadLocal.get()` 占比高 | ThreadLocal 访问成为热点（少见）|

---

## 五、Arthas 实战速查

### 5.1 启动与连接

```bash
# 下载并启动（Java 8+ 均支持）
curl -O https://arthas.aliyun.com/arthas-boot.jar
java -jar arthas-boot.jar        # 自动列出 JVM 进程供选择
java -jar arthas-boot.jar <pid>  # 直接连接指定进程
```

### 5.2 高频命令速查

```bash
# --- 系统概况 ---
dashboard          # 实时面板：线程、内存、GC 汇总，每 5 秒刷新

# --- 线程诊断 ---
thread             # 所有线程概况 + 状态
thread -n 5        # CPU 最高的 5 个线程 + 堆栈（CPU 飙高必用）
thread -b          # 检测死锁（BLOCKED 线程）
thread <id>        # 查看指定线程堆栈

# --- 方法追踪 ---
# 追踪 OrderService.createOrder() 的执行时间（包含子调用）
trace com.example.OrderService createOrder
# 限制只显示耗时 > 100ms 的调用
trace com.example.OrderService createOrder '#cost > 100'

# 追踪整个调用链（4 层）
trace -E com.example.OrderService|InventoryService '*' --skipJDKMethod false -n 3

# --- 方法参数/返回值查看 ---
watch com.example.OrderService createOrder '{params, returnObj, throwExp}' -x 3
# -x 3: 展开深度 3 层

# --- 性能分析 ---
profiler start                                  # 开始采样 CPU
profiler stop --format html --file /tmp/flame.html  # 停止并生成火焰图

# --- 热更新代码 ---
# 1. 在本地修改代码并编译出 .class 文件
# 2. 上传到服务器
# 3. 执行 redefine（不重启 JVM 热更新）
redefine /tmp/OrderService.class
# 注意：不能新增方法/字段，只能修改方法体

# --- 动态修改日志级别 ---
ognl '@org.slf4j.LoggerFactory@getLogger("com.example").setLevel(
    @ch.qos.logback.classic.Level@DEBUG)'

# --- 查看类加载信息 ---
classloader -t          # 打印类加载器树
sc com.example.Order*   # 搜索已加载的类
sm com.example.OrderService create*  # 查看类的方法

# --- 在线执行表达式 ---
ognl '@com.example.config.AppConfig@getInstance().getDbUrl()'
ognl 'new java.text.SimpleDateFormat("yyyy-MM-dd").format(new java.util.Date())'
```

### 5.3 trace 命令注意事项

`trace` 通过字节码增强（ASM）在方法入口/出口插入计时逻辑，**每次方法调用都有额外开销**。高并发接口慎用：

```bash
# 限制采样次数（-n 5 只追踪 5 次）
trace com.example.OrderService createOrder -n 5

# 限制条件触发（只追踪参数满足条件的调用）
trace com.example.OrderService createOrder 'params[0].orderId == "12345"'
```

---

## 六、完整排查流程图

```
接口超时 / 服务异常
          |
          v
    +-----+------+
    | 看 dashboard|  <- Arthas，确认问题方向
    +-----+------+
          |
    +-----+---------------+---------------+
    |                     |               |
  CPU 高               内存高          线程卡住
    |                     |               |
async-profiler         jcmd heap_dump   thread -b / -n
生成火焰图              MAT 分析         找死锁/热点线程
    |                     |               |
找热点方法            找泄漏路径       找锁持有者
    |                     |               |
Arthas trace          修复引用链      修复锁顺序/超时
确认方法耗时
```

---

## 七、生产环境推荐配置

```bash
# 推荐生产 JVM 启动参数（JDK 17+，G1GC）
java \
  # 堆大小（按应用需求调整）
  -Xms4g -Xmx4g \
  # GC 选择
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  # GC 日志（结构化，便于 GCViewer 分析）
  -Xlog:gc*:file=/var/log/gc/gc.log:time,uptime,level,tags:filecount=10,filesize=50m \
  # OOM 自动 Heap Dump
  -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=/var/log/heap/ \
  # JFR 持续录制
  -XX:StartFlightRecording=disk=true,maxsize=500m,maxage=24h,\
    settings=default,dumponexit=true,filename=/var/log/jfr/app.jfr \
  # 本地内存跟踪（若需要 Direct Memory 诊断，开销约 3-5%）
  # -XX:NativeMemoryTracking=summary \
  -jar app.jar
```

---

## 八、对比总结

| 维度 | JFR + JMC | async-profiler | Arthas |
|------|-----------|----------------|--------|
| **场景** | 全量事件记录，事后分析 | CPU/内存热点，火焰图 | 在线诊断，不重启 |
| **开销** | < 1% | 1-3% | 按命令而定（trace 较高）|
| **采样精度** | SafePoint 偏差 | AsyncGetCallTrace，无偏差 | 字节码增强，精确 |
| **生产可用** | ✅ 强烈推荐长期开启 | ✅ 按需开启 | ⚠️ 谨慎（trace 慎用）|
| **操作难度** | 需要 JMC GUI | 命令行 + 浏览器 | 命令行 / HTTP API |
| **热修复** | ❌ | ❌ | ✅ redefine |
| **本地代码可见** | 部分 | ✅ 含 JNI/GC 代码 | ❌ |

---

## 九、踩坑总结

**❌ 错误做法 1**：生产故障时才想起没有 JFR，手忙脚乱补开启

**✅ 正确做法**：将 JFR 持续录制纳入标准启动参数，问题发生时直接 dump 最近数据，无需复现。

---

**❌ 错误做法 2**：高并发接口上执行 `trace com.example.*` 全类通配

通配会匹配上百个方法，字节码增强数量暴增，CPU 可能从 30% 飙到 90%，引发新的问题。

**✅ 正确做法**：精确到具体类 + 具体方法，加 `-n 5` 限制次数。

---

**❌ 错误做法 3**：用 jmap 生产 dump（默认触发 Full GC）

```bash
# ❌ 会触发 Full GC，线上慎用
jmap -dump:format=b,file=heap.hprof <pid>

# ✅ jcmd 不触发 Full GC（加 live 才触发）
jcmd <pid> GC.heap_dump /tmp/heap.hprof  # 不加 live，只 dump 当前堆
```

---

## 十、文章小结

1. **工具选型**：CPU 热点用 async-profiler（精度最高），内存泄漏用 MAT，在线诊断用 Arthas，全量事件分析用 JFR + JMC。
2. **JFR 是最值得投入的基础设施**：开销 < 1%，可 7×24 小时开启；出问题时一键 dump，无需复现。
3. **async-profiler 的火焰图**读法：宽平台顶部 = CPU 热点，X 轴宽度代表采样比例，不是时间轴。
4. **Arthas 的 trace** 命令会增强字节码，高并发场景必须加 `-n` 限制次数，避免加剧服务压力。
5. **生产标配参数**：`-XX:+HeapDumpOnOutOfMemoryError`（OOM 自动 dump）+ JFR 持续录制 + 结构化 GC 日志，三件套缺一不可。

---

## 十一、参考资料

- [JFR 官方文档（JDK 21）](https://docs.oracle.com/en/java/javase/21/jfapi/index.html)
- [JMC 下载](https://jdk.java.net/jmc/)（JMC 9，支持 JDK 17+）
- [async-profiler GitHub](https://github.com/async-profiler/async-profiler)（3.x，JDK 8-21）
- [Arthas 用户文档](https://arthas.aliyun.com/doc/)（Arthas 3.7+）
- [Brendan Gregg 火焰图指南](https://www.brendangregg.com/flamegraphs.html)
- 《Java 性能权威指南》第 2 版，Scott Oaks 著，第 3 章"JVM 性能调优工具"
