# Java CPU 飙高排查实战

<div class="post-meta">📅 2025-10-26 &nbsp;·&nbsp; 🏷️ <span class="tag">性能</span> <span class="tag">Java</span></div>

CPU 飙高是生产环境最常见的故障之一，本文总结完整排查流程和典型案例。

---

## 一、快速定位流程

```bash
# 1. 找到 CPU 占用高的 Java 进程
top -c
# 或更友好的
ps aux | sort -k3 -rn | head -5

# 记录 PID（假设为 1234）

# 2. 找到进程内占用 CPU 最高的线程
top -H -p 1234
# -H 显示线程，记录 TID（假设最高的线程 TID 为 5678）

# 3. 将 TID 转为十六进制
printf "%x\n" 5678
# 输出：162e

# 4. 抓取 JVM 线程 dump
jstack 1234 > /tmp/thread_dump.txt

# 5. 在 dump 中搜索 tid=0x162e 的线程
grep -A 30 "162e" /tmp/thread_dump.txt
```

---

## 二、线程 dump 分析

```
典型的 CPU 飙高场景：

场景1：无限循环
"http-nio-8080-exec-1" #28 daemon prio=5 os_prio=0 tid=0x...
   java.lang.Thread.State: RUNNABLE
    at com.example.SomeService.processData(SomeService.java:78)  ← 关注这里
    at com.example.Controller.handle(Controller.java:45)

    → 定位到 SomeService.java 第 78 行，检查是否有死循环

场景2：频繁 GC（STW）
"GC task thread#0" RUNNABLE
"GC task thread#1" RUNNABLE

    → CPU 主要被 GC 消耗，需要分析堆内存

场景3：正则表达式灾难性回溯
at java.util.regex.Pattern$Branch.match(Pattern.java:4778)  ← 递归
at java.util.regex.Pattern$Branch.match(Pattern.java:4778)  ← 深度递归
```

---

## 三、典型原因与修复

### 死循环

```java
// 漏洞：HashMap 在并发场景的死循环（JDK 7）
// 症状：某个线程 100% CPU，jstack 显示都在 HashMap 相关方法

// 修复：使用 ConcurrentHashMap
private ConcurrentHashMap<String, Object> cache = new ConcurrentHashMap<>();
```

### 正则回溯

```java
// 危险正则（指数级回溯）
Pattern p = Pattern.compile("(a+)+b");  // ❌
// 输入 "aaaaaaaaaaaaaaac" → 长时间 CPU 100%

// 修复：使用原子分组或简化正则
Pattern p = Pattern.compile("a+b");     // ✅ 简化

// 线上正则编译缓存（避免每次 new Pattern）
private static final Pattern EMAIL_PATTERN = 
    Pattern.compile("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$");
```

### 频繁 GC

```bash
# 查看 GC 情况
jstat -gcutil 1234 1000 10  # 每隔1秒打印10次

# 输出示例：
#  S0     S1     E      O      M     CCS    YGC     YGCT    FGC    FGCT     GCT
#   0.00  80.04  72.34  98.56  94.12  91.23    156    2.456    32    15.234   17.690
#                                ↑ 老年代 98% → 频繁 Full GC

# 生成堆 dump
jmap -dump:format=b,file=/tmp/heap.hprof 1234
```

---

## 四、arthas 实时诊断

```bash
# 下载 arthas
curl -O https://arthas.aliyun.com/arthas-boot.jar
java -jar arthas-boot.jar   # 选择目标进程

# 实时查看 CPU 最高的方法（采样15秒）
profiler start
# 等待15秒
profiler stop --format html  # 生成火焰图

# 查看线程状态统计
thread -n 5   # 显示 CPU 最高的5个线程

# 查看指定线程的堆栈
thread 5678

# 实时监控方法调用
watch com.example.SomeService processData '{params,returnObj,throwExp}' '#cost>100'
# 监控 processData 方法，耗时超过100ms时打印参数

# 追踪方法调用链路及耗时
trace com.example.Controller handle '#cost>50'
```

---

## 五、火焰图分析

```
火焰图（Flame Graph）说明：
- X 轴：方法占用时间比例（越宽 CPU 时间越多）
- Y 轴：调用栈深度
- 颜色：无特殊含义，随机着色

重点关注：
1. 顶部最宽的方法 → CPU 热点
2. 宽矩形平顶 → 方法本身消耗时间多（非子调用）
3. JVM 内置方法（如 GC 相关）占比过高 → 需要优化内存

生成工具：
- arthas profiler（推荐）
- async-profiler
- JFR（Java Flight Recorder）+ JMC
```

---

## 总结

| 步骤 | 命令 |
|------|------|
| 找到高 CPU 进程 | `top -c` |
| 找到高 CPU 线程 | `top -H -p PID` |
| 转十六进制 | `printf "%x\n" TID` |
| 抓取线程 dump | `jstack PID` |
| 在 dump 中搜索 | `grep -A 30 "tid"` |
| 分析 GC | `jstat -gcutil PID 1000 10` |
| 实时诊断 | arthas `thread -n 5` / `profiler` |
