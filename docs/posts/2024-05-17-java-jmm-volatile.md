# Java 内存模型（JMM）与 volatile 深度解析

<div class="post-meta">📅 2024-05-17 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">并发</span></div>

线上某个状态控制 Bug 困扰了团队三天：一个线程写入了 running = false，另一个线程的循环却永远不退出。加了日志之后能复现，不加日志就消失——典型的可见性问题。理解这类 Bug，必须从 Java 内存模型（JMM）的根源讲起。

---

## 一、背景：为什么需要 JMM

现代 CPU 为了弥补与内存之间的速度鸿沟，引入了多级缓存（L1/L2/L3 Cache）。每个 CPU 核心都有自己独立的 L1/L2 缓存，对变量的读写优先操作缓存而非主内存。这带来了三个经典并发问题：

| 问题 | 根源 | 示例 |
|------|------|------|
| **可见性** | CPU 缓存导致修改对其他核不可见 | 线程 A 写了变量，线程 B 读到旧值 |
| **原子性** | 多步操作中途可被抢占 | i++ 是三步操作（读-改-写），非原子 |
| **有序性** | 编译器/CPU 为优化会重排序指令 | 指令执行顺序与源码不一致 |

JMM 不是 Java 特有的问题——C++、Go 也有类似的内存模型规范。JMM 的作用是**屏蔽不同硬件平台的差异，为 Java 程序提供统一的并发语义保证**。

---

## 二、JMM 核心模型

### 主内存与工作内存

JMM 规定：所有变量存储在**主内存**，每个线程拥有独立的**工作内存**（对应 CPU 寄存器/缓存的抽象）。线程对变量的所有操作必须在工作内存中进行，不能直接操作主内存。

```
  Thread A                        Thread B
+------------------+            +------------------+
|  Working Memory  |            |  Working Memory  |
| flag=false(old)  |            |  flag=true(new)  |
+--------+---------+            +--------+---------+
         | read / write                 | read / write
         v                              v
    +----------------------------------------+
    |              Main Memory               |
    |            flag = true                 |
    +----------------------------------------+

Thread B 写入 flag=true 到主内存，
但 Thread A 的工作内存中仍是旧值 false，
除非有机制强制刷新，否则 Thread A 永远看不到更新。
```
### happens-before：可见性的正式定义

JMM 用 **happens-before（hb）** 关系来定义"谁能看到谁的修改"。若 A hb B，则 A 的所有操作结果对 B 可见。

六条核心规则：

1. **程序顺序规则**：同一线程内，前面的操作 hb 后面的操作
2. **锁规则**：unlock hb 后续对同一锁的 lock
3. **volatile 规则**：volatile 写 hb 后续对同一变量的 volatile 读
4. **线程启动规则**：Thread.start() hb 线程内任意操作
5. **线程终止规则**：线程所有操作 hb Thread.join() 返回
6. **传递性**：A hb B，B hb C，则 A hb C

> happens-before 不是时间先后，而是**可见性保证**。A hb B 意味着 B 能看到 A 的所有修改，即使它们并发执行。

---

## 三、volatile 语义与底层实现

volatile 提供两个保证：**可见性**和**有序性**（禁止重排序），但**不保证原子性**。

### 可见性实现

写 volatile 变量时，JVM 插入 store 操作，将工作内存的值**立即刷新到主内存**；读 volatile 变量时，插入 load 操作，强制从主内存**重新加载**，跳过 CPU 缓存。

### 禁止重排序：内存屏障

JMM 通过四种**内存屏障**指令（Memory Barrier）实现有序性：

| 屏障 | 作用 |
|------|------|
| LoadLoad | 屏障前的 Load 操作先于屏障后的 Load |
| StoreStore | 屏障前的 Store 先于屏障后的 Store |
| LoadStore | 屏障前的 Load 先于屏障后的 Store |
| StoreLoad | 全能屏障，开销最大 |

JMM 规定 volatile 读写插入屏障的位置：

```
volatile 写：
  [前] StoreStore 屏障  <- 禁止上面的写与 volatile 写重排
  volatile 写操作
  [后] StoreLoad 屏障   <- 禁止 volatile 写与后面的读重排

volatile 读：
  volatile 读操作
  [后] LoadLoad 屏障    <- 禁止 volatile 读与后面的读重排
  [后] LoadStore 屏障   <- 禁止 volatile 读与后面的写重排
```
x86 架构上，StoreLoad 屏障对应 MFENCE 指令；ARM 上对应 DMB 指令。

---

## 四、实战场景

### 场景一：状态标志（volatile 最典型用法）

```java
public class Worker implements Runnable {
    // 用 volatile 保证可见性，一写多读场景
    private volatile boolean stopped = false;

    public void stop() {
        stopped = true;  // 写操作：立即刷新到主内存
    }

    @Override
    public void run() {
        while (!stopped) {   // 读操作：每次从主内存加载，不使用缓存
            doWork();
        }
        System.out.println("Worker stopped.");
    }

    private void doWork() { /* ... */ }
}

// 使用
Worker worker = new Worker();
Thread t = new Thread(worker);
t.start();

Thread.sleep(1000);
worker.stop();  // 保证 t 线程能看到修改，循环正常退出
```
### 场景二：双重检查锁（DCL）单例

这是 volatile 最著名的应用场景之一。instance = new Singleton() 在字节码层面是三步：
1. 分配内存空间
2. 初始化对象
3. 将引用赋值给 instance

CPU 可能将步骤 2 和 3 重排（先赋值再初始化），导致其他线程拿到一个**未初始化完成的对象引用**。

```java
public class Singleton {
    // ❌ 不加 volatile：步骤3和2可能重排，其他线程看到非null但未初始化的对象
    // private static Singleton instance;

    // ✅ 加 volatile：禁止指令重排，保证初始化完成后才赋值
    private static volatile Singleton instance;

    private Singleton() {}

    public static Singleton getInstance() {
        if (instance == null) {              // 第一次检查，避免每次加锁
            synchronized (Singleton.class) {
                if (instance == null) {      // 第二次检查，防止重复创建
                    instance = new Singleton();
                }
            }
        }
        return instance;
    }
}
```
---

## 五、volatile vs synchronized vs Atomic

| 维度 | volatile | synchronized | AtomicXxx |
|------|-----------|----------------|-------------|
| 可见性 | ✅ | ✅ | ✅ |
| 有序性 | ✅ | ✅ | ✅ |
| 原子性 | ❌ | ✅ | ✅（CAS） |
| 阻塞 | 不阻塞 | 阻塞 | 不阻塞（自旋） |
| 适用场景 | 状态标志、一写多读 | 复合操作、临界区 | 计数器、累加器 |
| 性能 | 最轻量 | 中等（JDK6+ 优化） | 高并发下优于 synchronized |

**选择原则**：
- 变量写操作**不依赖当前值**（非 i++），且变量不与其他变量组成不变约束 → volatile
- 需要原子性的**复合操作** → synchronized 或 Lock
- 单变量的**原子累加/更新** → AtomicInteger 等（底层 CAS，无锁）

---

## 六、常见坑点与最佳实践

### 坑 1：volatile 不能保证复合操作的原子性

```java
private volatile int count = 0;

// ❌ 非原子！count++ 等于 read -> modify -> write，三步之间可被抢占
public void increment() {
    count++;
}

// ✅ 正确：使用 AtomicInteger
private final AtomicInteger count = new AtomicInteger(0);
public void increment() {
    count.incrementAndGet();
}
```
### 坑 2：long/double 的非原子读写

JMM 允许将 64 位的 long/double 的读写分为两次 32 位操作，在 32 位 JVM 上可能读到"撕裂"的值。解决方案：加 volatile 或改用 AtomicLong。

### 坑 3：volatile 数组 ≠ 数组元素 volatile

```java
volatile int[] arr = new int[10];
arr[0] = 1;  // ❌ 数组引用 arr 是 volatile 的，但数组元素不是！
             //    其他线程不一定能看到 arr[0] 的修改

// ✅ 使用 AtomicIntegerArray
AtomicIntegerArray arr = new AtomicIntegerArray(10);
arr.set(0, 1);
```
### 坑 4：误用 volatile 替代锁

```java
// ❌ 两个 volatile 变量的组合操作没有原子性
private volatile boolean hasData = false;
private volatile String data = null;

// 生产者
data = "content";      // 步骤1
hasData = true;        // 步骤2

// 消费者检查 hasData 时 data 可能还是 null（步骤1步骤2之间被抢占）
// 此场景需要 synchronized 保证两步操作的整体原子性
```
---

## 七、总结与延伸

**核心要点**：
- JMM 通过主内存/工作内存模型屏蔽了底层 CPU 缓存差异，定义了可见性、原子性、有序性三个保证目标
- happens-before 是 JMM 的核心机制，定义了操作之间的可见性保证关系
- volatile 通过内存屏障实现可见性和有序性，但不保证原子性
- DCL 单例必须加 volatile，防止未初始化对象引用被其他线程读到
- 复合操作的原子性需要 synchronized、Lock 或 Atomic 系列，不能用 volatile

**延伸阅读方向**：
- synchronized 的锁升级机制（偏向锁→轻量锁→重量锁）：理解 JDK 6+ 的锁优化
- AQS（AbstractQueuedSynchronizer）：ReentrantLock、CountDownLatch 的底层框架
- CPU 缓存一致性协议（MESI）：JMM 的硬件基础
- Java 9+ 的 VarHandle：更细粒度的 volatile 语义控制
