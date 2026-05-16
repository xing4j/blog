# JVM 调优实战：heap dump 分析与 GC 日志解读

<div class="post-meta">📅 2024-07-09 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">JVM</span> <span class="tag">性能</span></div>

JVM 调优不是玄学，关键是**看数据说话**。本文讲解 heap dump 分析与 GC 日志解读的完整流程，帮助定位内存泄漏和 GC 停顿问题。

---

## 一、GC 日志开启与格式

### JDK 8 开启 GC 日志

```bash
java -Xms2g -Xmx2g \
  -XX:+PrintGCDetails \
  -XX:+PrintGCDateStamps \
  -XX:+PrintGCTimeStamps \
  -Xloggc:/var/log/app/gc.log \
  -XX:+UseGCLogFileRotation \
  -XX:NumberOfGCLogFiles=5 \
  -XX:GCLogFileSize=20m \
  -jar app.jar
```

### JDK 9+ 统一日志（Xlog）

```bash
java -Xms2g -Xmx2g \
  -Xlog:gc*:file=/var/log/app/gc.log:time,uptime,level,tags:filecount=5,filesize=20m \
  -jar app.jar
```

---

## 二、GC 日志解读

### G1 Young GC 日志示例

```
2024-07-09T14:23:01.123+0800: 3.456: [GC pause (G1 Evacuation Pause) (young)
 Heap before GC:
   Eden: 800M(800M)->0B(800M)
   Survivors: 50M->60M
   Old: 1200M
 [Parallel Time: 12.3 ms, GC Workers: 8]
 [Eden: 800.0M(800.0M)->0.0B(800.0M) Survivors: 50.0M->60.0M Heap: 2050.0M(4096.0M)->1310.0M(4096.0M)]
 [Times: user=0.08 sys=0.01, real=0.013 secs]
```

关键指标解读：

| 字段 | 含义 |
|------|------|
| `GC pause (young)` | Young GC，仅收集新生代 |
| `real=0.013 secs` | 实际停顿 13ms（STW 时间）|
| `user=0.08` | CPU 用户态时间（多核并行）|
| `Eden: 800M->0B` | Eden 回收后清空 |
| `Heap: 2050M->1310M` | 本次 GC 释放约 740MB |

### 识别 Full GC

```
[Full GC (Ergonomics)  2048M->1536M(4096M), 8.234 secs]
                                              ^^^^^^^^ 危险！8秒停顿
```

**Full GC 触发原因排查**：
1. 老年代空间不足 → 增大 `-Xmx` 或排查内存泄漏
2. 元空间不足 → 增大 `-XX:MaxMetaspaceSize`
3. `System.gc()` 被调用 → 添加 `-XX:+DisableExplicitGC`

---

## 三、GC 日志可视化工具

推荐 **GCEasy**（在线）或 **GCViewer**（本地）：

```bash
# GCViewer 本地运行
java -jar gcviewer.jar /var/log/app/gc.log
```

重点关注指标：
- **Throughput**（吞吐量）：应 > 95%
- **Max Pause**（最大停顿）：G1 目标 < 200ms
- **Avg Pause**（平均停顿）
- **GC Overhead**（GC 时间占比）：应 < 5%

---

## 四、heap dump 采集

### 方式一：OOM 时自动生成

```bash
java -XX:+HeapDumpOnOutOfMemoryError \
     -XX:HeapDumpPath=/var/log/app/heapdump.hprof \
     -jar app.jar
```

### 方式二：手动触发（不停机）

```bash
# 找到 Java 进程 PID
jps -l

# 使用 jmap 生成（注意：会有短暂停顿）
jmap -dump:format=b,file=/tmp/heap.hprof <PID>

# JDK 9+ 推荐使用 jcmd
jcmd <PID> GC.heap_dump /tmp/heap.hprof
```

### 方式三：通过 JMX / Actuator

```bash
# Spring Boot Actuator 端点（需开放 heapdump 端点）
curl -O http://localhost:8080/actuator/heapdump
```

---

## 五、MAT（Memory Analyzer Tool）分析

MAT 是 Eclipse 出品的 heap dump 分析工具，[下载地址](https://eclipse.dev/mat/)。

### 打开 heap dump

```
File → Open Heap Dump → 选择 .hprof 文件
```

### 关键分析视图

**1. Leak Suspects Report（内存泄漏嫌疑报告）**

自动分析并给出嫌疑点，直接找到占用内存最多的对象链：

```
Problem Suspect 1:
  One instance of "com.example.cache.UserCache" 
  loaded by "jdk.internal.loader.ClassLoaders$AppClassLoader" 
  occupies 1,234,567,890 (78.5%) bytes.
  
  Keywords: HashMap, UserCache, 500,000 entries
```

**2. Dominator Tree（支配树）**

列出保留堆最大的对象，按 Retained Heap 排序：

```
Class Name                          Shallow Heap  Retained Heap
com.example.cache.UserCache              48 B     1,234 MB  ← 重点检查
  └─ java.util.HashMap                   48 B     1,234 MB
       └─ HashMap$Entry[1048576]        ...
```

**3. OQL（对象查询语言）**

```sql
-- 查找所有 UserSession 对象
SELECT * FROM com.example.session.UserSession

-- 查找 size > 1000 的 ArrayList
SELECT * FROM java.util.ArrayList a WHERE a.size > 1000
```

---

## 六、常见内存问题诊断

### 问题1：HashMap 无限增长（缓存未设置上限）

```java
// ❌ 静态 Map 作为缓存，无淘汰机制
private static final Map<String, Data> CACHE = new HashMap<>();

// ✅ 改用 Caffeine 或 Guava Cache，设置最大容量和过期时间
LoadingCache<String, Data> cache = Caffeine.newBuilder()
    .maximumSize(10_000)
    .expireAfterWrite(Duration.ofMinutes(10))
    .build(key -> loadFromDB(key));
```

### 问题2：ThreadLocal 未清理（线程池场景）

```java
// ❌ 线程池中 ThreadLocal 使用后未清理，导致旧数据残留 + 内存泄漏
ThreadLocal<UserContext> context = new ThreadLocal<>();

// ✅ 使用 try-finally 确保清理
try {
    context.set(new UserContext(userId));
    doProcess();
} finally {
    context.remove(); // 必须清理！
}
```

---

## 七、JVM 调优常用参数速查

```bash
# 堆内存
-Xms4g -Xmx4g          # 初始/最大堆（建议相同，避免扩缩停顿）
-Xmn1g                  # 新生代大小（G1 不建议手动设置）

# 元空间
-XX:MetaspaceSize=256m
-XX:MaxMetaspaceSize=512m

# G1 调优
-XX:+UseG1GC
-XX:MaxGCPauseMillis=100
-XX:G1HeapRegionSize=16m

# 诊断
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/tmp/
-XX:+PrintGCDetails
-Xlog:gc*:file=/tmp/gc.log:time
```

---

## 总结

1. **GC 日志**是调优的第一手数据，重点看停顿时间和 Full GC 频率
2. **heap dump** 结合 MAT 的 Dominator Tree 能快速定位内存泄漏元凶
3. 常见泄漏来源：无上限缓存、ThreadLocal 未清理、监听器未注销、连接未关闭
4. 调优公式：先扩大内存（快速止血）→ 再分析根因（根本解决）
