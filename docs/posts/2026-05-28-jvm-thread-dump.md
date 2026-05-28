# JVM-06 线程 Dump 实战分析：死锁、线程饥饿与线程泄漏识别

<div class="post-meta">📅 2026-05-28 &nbsp;·&nbsp; 🏷️ <span class="tag">JVM</span></div>

> 📚 **本文属于「JVM 原理与调优实战」系列**
> - [JVM-01 JVM 架构总览：类加载、字节码执行与运行时内存](posts/2026-05-27-jvm-architecture.md)
> - [JVM-02 JVM 内存区域详解：六种 OOM 场景与排查实战](posts/2026-05-27-jvm-memory-areas.md)
> - [JVM-03 JVM 垃圾回收器详解：从 CMS 到 ZGC 的演进](posts/2024-05-27-jvm-gc-collectors.md)
> - [JVM-04 JVM 调优实战：参数配置、GC 日志与 Heap Dump 分析](posts/2024-07-09-jvm-tuning-heapdump.md)
> - [JVM-05 内存泄漏排查实战：ThreadLocal、静态集合与监听器三大模式](posts/2026-05-28-jvm-memory-leak.md)
> - 👉 **JVM-06 线程 Dump 实战分析：死锁、线程饥饿与线程泄漏识别（本文）**
> - [JVM-07 类加载机制与双亲委派：破坏场景、热部署与 Metaspace 泄漏](posts/2026-05-28-jvm-classloading.md)
> - [JVM-08 JVM 诊断工具全景：JFR/JMC、Arthas、async-profiler 选型与实战速查](posts/2026-05-28-jvm-profiling-tools.md)

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 30 分钟｜**分类**：Java 核心

服务接口全部超时，CPU 接近 0%，内存正常，重启后立刻恢复——最可能是死锁或线程池耗尽。CPU 飙到 100% 但接口没有流量——最可能是某些线程在死循环。这两类问题的共同诊断入口是 **Thread Dump（线程快照）**：一张 JVM 在某一时刻所有线程状态的完整快照。本文通过真实样本讲解如何读懂 Thread Dump，识别死锁、线程饥饿、线程泄漏三类高频问题。

---

## 一、Thread Dump 基础

### 1.1 获取方式

```bash
# 方式一：jstack（最常用）
jstack <pid> > thread-dump.txt

# 方式二：jcmd（推荐，信息更全）
jcmd <pid> Thread.print > thread-dump.txt

# 方式三：kill -3（Linux/macOS，输出到标准输出/日志）
kill -3 <pid>

# 方式四：Arthas（不需要 pid，直接在 Arthas 控制台）
thread -all > thread-dump.txt

# 最佳实践：连续采集 3 次，间隔 10 秒，对比变化
for i in 1 2 3; do jcmd <pid> Thread.print > dump-$i.txt; sleep 10; done
```

### 1.2 线程状态速查

| 状态 | 含义 | 常见原因 |
|------|------|---------|
| `RUNNABLE` | 正在运行或等待 CPU 调度 | 正常运行、死循环、IO 等待 |
| `BLOCKED` | 等待 synchronized 锁 | 锁竞争 |
| `WAITING` | 无限期等待（`Object.wait()`、`LockSupport.park()`） | 等待通知、等待任务 |
| `TIMED_WAITING` | 有限期等待（`sleep(n)`、`wait(n)`、`park(n)`） | 正常超时等待 |
| `TERMINATED` | 已终止 | 线程执行完毕 |

> **注意**：`RUNNABLE` 不代表线程在真正跑 CPU——JVM 层面的 RUNNABLE 包含了操作系统层面的"等待 IO"状态。磁盘 IO、网络 IO 时线程也显示 RUNNABLE。

### 1.3 一个线程 Dump 条目解读

```
"http-nio-8080-exec-1" #42 daemon prio=5 os_prio=0 cpu=1234.56ms elapsed=3600.12s tid=0x00007f1a2c001000 nid=0x1a2b waiting for monitor entry [0x00007f1a1c001000]
   java.lang.Thread.State: BLOCKED (on object monitor)

        at com.example.OrderService.createOrder(OrderService.java:87)
        - waiting to lock <0x000000076b8e6490> (a java.lang.Object)
        at com.example.OrderController.order(OrderController.java:45)
        at ...

   Locked ownable synchronizers:
        - None
```

各字段含义：
- `"http-nio-8080-exec-1"` — 线程名
- `#42` — 线程序号
- `daemon` — 守护线程标记
- `prio=5` — JVM 优先级（1-10）
- `cpu=1234.56ms` — 该线程累计消耗 CPU 时间
- `nid=0x1a2b` — 操作系统线程 ID（十六进制），可对应 `top -H` 输出
- `BLOCKED (on object monitor)` — 当前状态
- `waiting to lock <0x...>` — 等待的锁对象地址

---

## 二、死锁识别与分析

### 2.1 死锁的 Thread Dump 特征

jstack 会在文件末尾自动输出死锁检测报告：

```
Found one Java-level deadlock:
=============================
"Thread-B":
  waiting to lock monitor 0x000000076b8e6490 (object 0x000000076bab1e00, a java.lang.String),
  which is held by "Thread-A"

"Thread-A":
  waiting to lock monitor 0x000000076b8e64b0 (object 0x000000076bab2000, a java.lang.String),
  which is held by "Thread-B"

Java stack information for the threads listed above:
===================================================
"Thread-B":
        at com.example.DeadlockDemo.methodB(DeadlockDemo.java:42)
        - waiting to lock <0x000000076bab1e00> (a java.lang.String)
        - locked <0x000000076bab2000> (a java.lang.String)
        at com.example.DeadlockDemo.lambda$main$1(DeadlockDemo.java:28)

"Thread-A":
        at com.example.DeadlockDemo.methodA(DeadlockDemo.java:31)
        - waiting to lock <0x000000076bab2000> (a java.lang.String)
        - locked <0x000000076bab1e00> (a java.lang.String)
        at com.example.DeadlockDemo.lambda$main$0(DeadlockDemo.java:22)
```

关键信息：
1. `Found one Java-level deadlock` — 自动检测到死锁
2. Thread-A 持有锁 `0x...1e00`，等待 `0x...2000`
3. Thread-B 持有锁 `0x...2000`，等待 `0x...1e00`
4. 堆栈直接指向代码行号 `DeadlockDemo.java:31`

### 2.2 复现代码

```java
// JDK 17
public class DeadlockDemo {
    private static final Object LOCK_A = new Object();
    private static final Object LOCK_B = new Object();

    public static void main(String[] args) {
        Thread threadA = new Thread(() -> {
            synchronized (LOCK_A) {               // Thread-A 获取 LOCK_A
                System.out.println("A: got LOCK_A");
                sleep(100);
                synchronized (LOCK_B) {           // Thread-A 等待 LOCK_B（Thread-B 持有）
                    System.out.println("A: got LOCK_B");
                }
            }
        }, "Thread-A");

        Thread threadB = new Thread(() -> {
            synchronized (LOCK_B) {               // Thread-B 获取 LOCK_B
                System.out.println("B: got LOCK_B");
                sleep(100);
                synchronized (LOCK_A) {           // Thread-B 等待 LOCK_A（Thread-A 持有）
                    System.out.println("B: got LOCK_A");
                }
            }
        }, "Thread-B");

        threadA.start();
        threadB.start();
    }
}
```

### 2.3 死锁预防原则

```java
// ✅ 固定锁顺序：两个线程都按 LOCK_A -> LOCK_B 的顺序申请
// 无论哪个线程先执行，都不会出现循环等待

// ✅ 使用 tryLock 超时（ReentrantLock）
ReentrantLock lockA = new ReentrantLock();
ReentrantLock lockB = new ReentrantLock();

boolean gotAll = false;
try {
    if (lockA.tryLock(100, TimeUnit.MILLISECONDS)) {   // 带超时的尝试
        try {
            if (lockB.tryLock(100, TimeUnit.MILLISECONDS)) {
                try {
                    gotAll = true;
                    // 业务逻辑
                } finally { lockB.unlock(); }
            }
        } finally { lockA.unlock(); }
    }
} catch (InterruptedException e) {
    Thread.currentThread().interrupt();
}
if (!gotAll) {
    // 超时，回退处理（重试/告警）
}
```

---

## 三、线程饥饿识别

### 3.1 线程池耗尽——服务挂起

现象：接口 100% 超时，CPU 接近 0%，无错误日志。

Thread Dump 特征：

```
"http-nio-8080-exec-200" #241 daemon prio=5 ... WAITING
    java.lang.Thread.State: WAITING (parking)
        at sun.misc.Unsafe.park(Native Method)
        at java.util.concurrent.locks.LockSupport.park(LockSupport.java:175)
        at java.util.concurrent.SynchronousQueue$TransferStack.awaitFulfill(...)
        at com.example.InternalCallService.call(InternalCallService.java:56)

... (重复 200 次，所有线程都在等同一个 SynchronousQueue)
```

**分析**：200 个 Tomcat 线程全部在 `WAITING`，等待一个 `SynchronousQueue`——这是 `Executors.newCachedThreadPool()` 的默认阻塞队列。业务代码在 Tomcat 线程中又提交任务到另一个线程池，而那个线程池也满了，形成双层阻塞。

```java
// ❌ 典型的嵌套线程池死锁场景
@GetMapping("/order")
public CompletableFuture<String> order() {
    // Tomcat 线程处理请求，里面又提交到内部线程池
    return CompletableFuture.supplyAsync(() -> {
        // 内部任务又等待另一个线程池的结果
        return anotherPool.submit(() -> "result").get(); // ❌ get() 阻塞
    }, businessPool);
    // Tomcat 线程等 businessPool，businessPool 线程等 anotherPool
    // 若 anotherPool 满了，形成链式等待
}
```

### 3.2 锁竞争热点——吞吐量低

现象：CPU 不高，但 TPS 远低于预期。

Thread Dump 特征（大量线程 BLOCKED 在同一个锁）：

```
"http-nio-8080-exec-15" BLOCKED (on object monitor)
    at com.example.CounterService.increment(CounterService.java:23)
    - waiting to lock <0x000000076b8e6490> (a java.lang.Object)

"http-nio-8080-exec-16" BLOCKED (on object monitor)
    at com.example.CounterService.increment(CounterService.java:23)
    - waiting to lock <0x000000076b8e6490> (a java.lang.Object)

... (50 个线程都在等同一个锁 0x...6490)
```

找到锁的持有者：

```
"http-nio-8080-exec-3" RUNNABLE
    at com.example.CounterService.increment(CounterService.java:23)
    - locked <0x000000076b8e6490> (a java.lang.Object)
    at com.example.CounterService.expensiveOperation(CounterService.java:45)
    # 持有锁的线程在执行耗时操作，导致其他线程长时间等待
```

修复：缩小锁粒度，或换用 `LongAdder` / `AtomicLong`：

```java
// ❌ 粗粒度锁
public class CounterService {
    private long count = 0;
    public synchronized void increment() {
        count++;
        expensiveOperation(); // 锁内执行耗时操作
    }
}

// ✅ 细粒度：只锁最小必要范围
public class CounterService {
    private final LongAdder count = new LongAdder(); // 高并发无锁计数

    public void increment() {
        count.increment();       // 无锁
        expensiveOperation();    // 锁外执行
    }
}
```

---

## 四、线程泄漏识别

### 4.1 线程泄漏的特征

线程泄漏是指线程被创建后无法正常终止，持续占用系统资源。与内存泄漏类似，重启能恢复，运行一段时间后复发。

Thread Dump 特征：

```
# 正常服务线程数约 50~200，但 dump 里出现 3000+ 线程，且大量是：
"pool-1-thread-2847" #2892 prio=5 ... WAITING (parking)
    at sun.misc.Unsafe.park(Native Method)
    at java.util.concurrent.locks.LockSupport.park(LockSupport.java:175)
    at java.util.concurrent.LinkedBlockingQueue.take(LinkedBlockingQueue.java:433)
    at java.util.concurrent.ThreadPoolExecutor.getTask(ThreadPoolExecutor.java:1074)
    at java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1134)
    at java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:624)
    at java.lang.Thread.run(Thread.java:833)
```

**分析**：`pool-1-thread-XXXX` 编号持续增大，说明线程池在不断创建新线程但旧线程没有退出。常见原因：

1. `Executors.newCachedThreadPool()` 无上限，高并发下无限创建
2. 每次请求都 `new Thread()` 或 `new ThreadPoolExecutor()` 而不复用
3. 线程池的 `keepAliveTime` 设置过长，闲置线程不退出

### 4.2 复现代码

```java
// JDK 17
@Service
public class LeakyService {
    @GetMapping("/process")
    public String process() {
        // ❌ 每次请求都创建新线程池，且不关闭
        ExecutorService pool = Executors.newFixedThreadPool(10);
        pool.submit(() -> doWork());
        // pool.shutdown() 从未调用，10 个线程永远等待
        return "ok";
    }
}
```

修复：共享线程池，由 Spring 管理生命周期：

```java
// ✅ 使用 Spring 管理的线程池（应用关闭时自动 shutdown）
@Configuration
public class ThreadPoolConfig {
    @Bean(destroyMethod = "shutdown")
    public ExecutorService businessPool() {
        return new ThreadPoolExecutor(
            10, 50,              // coreSize=10, maxSize=50
            60, TimeUnit.SECONDS,
            new LinkedBlockingQueue<>(1000),
            new ThreadFactoryBuilder().setNameFormat("biz-pool-%d").build(),
            new ThreadPoolExecutor.CallerRunsPolicy() // 拒绝策略
        );
    }
}
```

### 4.3 用 Arthas 统计线程数变化

```bash
# 每 5 秒打印一次线程概况
thread -i 5000

# 输出示例：
# Threads Total: 3241, NEW: 0, RUNNABLE: 45, BLOCKED: 0,
# WAITING: 3196, TIMED_WAITING: 0, TERMINATED: 0

# 查看线程数最多的线程池（按线程名前缀分组）
thread | grep "pool-1" | wc -l
```

---

## 五、CPU 飙高定位：从 Thread Dump 找热点线程

### 5.1 操作步骤

```bash
# Step 1: 找到 CPU 最高的线程（Linux）
top -H -p <pid>
# 记录 CPU 最高的线程 PID，如 7851

# Step 2: 转换为 16 进制
printf "%x\n" 7851
# 输出: 1aab

# Step 3: 在 Thread Dump 中搜索 nid=0x1aab
grep -A 30 "nid=0x1aab" thread-dump.txt
```

### 5.2 Arthas 一键定位（推荐）

```bash
# 直接显示 CPU 最高的 N 个线程及其堆栈
thread -n 5

# 输出示例：
# "GC task thread#0 (ParallelGC)" Id=8 cpuUsage=98% deltaTime=980ms time=45230ms
#     ...
# 或者：
# "http-nio-8080-exec-3" Id=42 cpuUsage=87% deltaTime=870ms time=12340ms
#    at com.example.JsonParser.parse(JsonParser.java:234)  <- 死循环或热点代码
```

---

## 六、各线程状态正常比例参考

| 线程分组 | 正常状态 | 异常信号 |
|---------|---------|---------|
| Tomcat 工作线程 | 少量 RUNNABLE，多数 WAITING | 全部 BLOCKED / WAITING |
| 业务线程池 | 有任务时 RUNNABLE，无任务时 WAITING | 线程数持续增长超 500 |
| GC 线程 | 短暂 RUNNABLE | 长期 RUNNABLE 且 CPU 高 |
| Finalizer 线程 | WAITING | RUNNABLE 且队列积压 |
| `DestroyJavaVM` | WAITING | — |

---

## 七、踩坑总结

**❌ 错误做法 1**：只采集一次 Thread Dump 就下结论

一次快照只代表那一时刻的状态。有些问题（如偶发锁竞争）一次采集可能捕捉不到。

**✅ 正确做法**：间隔 10 秒采集 3 次，对比三次结果：
- 三次都在同一行 → 线程真的卡住（死锁/饥饿）
- 三次不同行但都是同一方法 → 热点代码，CPU 高
- 三次完全随机 → 正常运行

---

**❌ 错误做法 2**：`WAITING` 状态的线程都认为是异常

线程池的空闲线程本来就是 `WAITING`（等任务），这是正常现象。判断异常的关键是：
1. `WAITING` 的线程是否在**非预期位置**等待（不是在线程池 `take()`，而是在业务代码 `park()`）
2. `WAITING` 线程数**持续增长**（线程泄漏）

---

**❌ 错误做法 3**：生产环境禁止 jstack，导致问题无法诊断

**✅ 正确做法**：提前在应用中暴露 `/actuator/threaddump` 端点（Spring Boot Actuator），可通过 HTTP 安全获取。并配置访问鉴权防止泄漏线程信息。

```yaml
# application.yml
management:
  endpoints:
    web:
      exposure:
        include: threaddump
  endpoint:
    threaddump:
      enabled: true
```

---

## 八、文章小结

1. **Thread Dump** 是线程问题的核心诊断工具，记录 JVM 某时刻所有线程的完整调用栈和状态，jstack / jcmd 均可获取。
2. **死锁**：jstack 会自动检测并报告，`Found one Java-level deadlock` 后直接看引用链；预防靠固定锁顺序或 `tryLock` 超时。
3. **线程饥饿**：大量线程 `BLOCKED` 在同一锁 → 锁竞争热点；大量线程 `WAITING` 且全部卡在业务代码 → 线程池耗尽或嵌套阻塞。
4. **线程泄漏**：线程数持续增长，`pool-X-thread-NNNN` 编号越来越大 → 不断创建新池未关闭；修复靠 Spring 管理的单例线程池。
5. **CPU 飙高**：用 `top -H` 找 OS 线程 ID，转十六进制后在 Thread Dump 中搜 `nid`；Arthas `thread -n 5` 可一步到位。

---

## 九、参考资料

- [Java Thread Dump 官方说明](https://docs.oracle.com/javase/8/docs/technotes/guides/troubleshoot/tooldescr034.html)
- [Arthas thread 命令文档](https://arthas.aliyun.com/doc/thread.html)（Arthas 3.7+）
- 《Java 并发编程实战》Brian Goetz 著，第 10 章"避免活跃性危险"
- [JDK troubleshooting guide](https://docs.oracle.com/en/java/javase/21/troubleshoot/index.html)（JDK 21）
- [fastthread.io](https://fastthread.io/)：在线 Thread Dump 可视化分析工具
