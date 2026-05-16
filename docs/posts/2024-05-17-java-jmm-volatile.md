# Java 内存模型（JMM）与 volatile 详解

<div class="post-meta">📅 2024-05-17 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">并发</span></div>

Java 内存模型（JMM）定义了多线程程序中共享变量的读写规则，是理解并发 Bug 的理论基础。本文从 JMM 核心概念出发，深入剖析 `volatile` 的语义与实现。

---

## 一、JMM 核心概念

### 主内存与工作内存

JMM 规定所有变量都存储在**主内存**，每个线程有自己的**工作内存**（CPU 缓存抽象）。线程对变量的操作必须在工作内存中进行，不能直接读写主内存。

```
Thread A                Thread B
┌─────────────┐        ┌─────────────┐
│ 工作内存     │        │ 工作内存     │
│  flag=false │        │  flag=?     │
└──────┬──────┘        └──────┬──────┘
       │  read/write          │
       ▼                      ▼
       ┌──────────────────────┐
       │       主内存          │
       │  flag=true           │
       └──────────────────────┘
```

### 三大并发问题

| 问题 | 描述 | 示例 |
|------|------|------|
| **可见性** | 一个线程修改了变量，其他线程看不到最新值 | Thread A 写 flag=true，Thread B 仍读到 false |
| **原子性** | 操作不可分割，中途不会被打断 | `i++` 实际是三步操作，非原子 |
| **有序性** | 指令重排序导致程序执行顺序与代码顺序不符 | 双重检查锁的经典问题 |

---

## 二、happens-before 规则

JMM 用 **happens-before** 定义操作间的可见性保证，若 A happens-before B，则 A 的结果对 B 可见。

主要规则：

1. **程序顺序规则**：同一线程内，前面的操作 happens-before 后面的操作
2. **锁规则**：unlock happens-before 后续对同一锁的 lock
3. **volatile 规则**：volatile 写 happens-before 后续对同一变量的读
4. **线程启动规则**：`Thread.start()` happens-before 线程内任意操作
5. **线程终止规则**：线程所有操作 happens-before `Thread.join()` 返回
6. **传递性**：A hb B，B hb C，则 A hb C

---

## 三、volatile 语义

`volatile` 提供两个保证：

### 3.1 可见性保证

写 `volatile` 变量时，JMM 强制将工作内存中的值**刷新到主内存**；读 `volatile` 变量时，强制从主内存**重新加载**。

```java
// 经典用法：用 volatile 做状态标志
public class StopThread {
    private volatile boolean stopped = false;

    public void stop() {
        stopped = true;          // 写操作：立即刷新到主内存
    }

    public void run() {
        while (!stopped) {       // 读操作：每次从主内存读
            doWork();
        }
    }
}
```

### 3.2 有序性保证（禁止指令重排序）

通过**内存屏障**（Memory Barrier）实现：

| 屏障类型 | 作用 |
|---------|------|
| LoadLoad | 禁止上面的 Load 与下面的 Load 重排 |
| StoreStore | 禁止上面的 Store 与下面的 Store 重排 |
| LoadStore | 禁止上面的 Load 与下面的 Store 重排 |
| StoreLoad | 全能屏障，禁止所有重排（开销最大）|

JMM 规定：
- volatile **写**前加 `StoreStore` 屏障，写后加 `StoreLoad` 屏障
- volatile **读**后加 `LoadLoad` 和 `LoadStore` 屏障

---

## 四、双重检查锁（DCL）中的 volatile

经典单例模式中，不加 `volatile` 存在指令重排序风险：

```java
// ❌ 错误写法：instance 可能是未初始化完成的对象引用
public class Singleton {
    private static Singleton instance;

    public static Singleton getInstance() {
        if (instance == null) {
            synchronized (Singleton.class) {
                if (instance == null) {
                    instance = new Singleton(); // 3步：分配内存→初始化→赋值
                    // 可能重排为：分配内存→赋值→初始化
                    // 另一个线程看到非null但未初始化完成的对象
                }
            }
        }
        return instance;
    }
}

// ✅ 正确写法：加 volatile 禁止重排序
public class Singleton {
    private static volatile Singleton instance;
    // ... 同上
}
```

---

## 五、volatile vs synchronized

| 维度 | volatile | synchronized |
|------|---------|-------------|
| 可见性 | ✅ | ✅ |
| 有序性 | ✅ | ✅ |
| 原子性 | ❌（复合操作不保证）| ✅ |
| 阻塞 | 不会阻塞 | 会阻塞 |
| 适用场景 | 状态标志、一写多读 | 需要原子性的复合操作 |

**何时用 volatile**：
- 变量写操作不依赖当前值（非 `i++` 这类）
- 变量不与其他变量共同参与不变约束
- 访问变量不需要加锁

---

## 六、常见误区

```java
// ❌ volatile 不能保证复合操作的原子性
private volatile int count = 0;
count++; // 非原子！等同于 count = count + 1，读-改-写三步

// ✅ 需要原子性时使用 AtomicInteger
private AtomicInteger count = new AtomicInteger(0);
count.incrementAndGet();
```

---

## 总结

- JMM 通过**主内存/工作内存**模型抽象 CPU 缓存，三大问题：可见性、原子性、有序性
- **happens-before** 是 JMM 的核心规则，定义了操作间的可见性保证
- `volatile` 通过内存屏障保证**可见性**和**有序性**，但**不保证原子性**
- DCL 单例必须给 instance 加 `volatile`，防止指令重排序暴露未初始化对象
