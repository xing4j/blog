# ReentrantLock vs synchronized 深度对比

<div class="post-meta">📅 2024-09-14 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">并发</span></div>

Java 提供了两套加锁机制：内置的 `synchronized` 关键字和 JUC 包的 `ReentrantLock`。了解它们的差异，才能在不同场景做出正确选择。

---

## 一、基本用法对比

```java
// synchronized：隐式加锁/解锁
public synchronized void syncMethod() {
    // 临界区
}

// 或对象级
synchronized (lockObject) {
    // 临界区
}

// ReentrantLock：显式加锁/解锁（必须在 finally 中释放）
private final ReentrantLock lock = new ReentrantLock();

public void lockMethod() {
    lock.lock();
    try {
        // 临界区
    } finally {
        lock.unlock(); // 必须！
    }
}
```

---

## 二、核心差异对比

| 特性 | synchronized | ReentrantLock |
|------|-------------|--------------|
| **实现层** | JVM 内置（monitorenter/monitorexit 字节码）| Java 代码（AQS 框架）|
| **可重入** | ✅ | ✅ |
| **公平锁** | ❌（非公平）| ✅（可选公平/非公平）|
| **可中断等待** | ❌ | ✅ `lockInterruptibly()` |
| **超时尝试** | ❌ | ✅ `tryLock(timeout)` |
| **非阻塞尝试** | ❌ | ✅ `tryLock()` |
| **多条件变量** | 1个（wait/notify）| 多个 `Condition` |
| **锁绑定多条件** | ❌ | ✅ |
| **自动释放** | ✅（异常自动释放）| ❌（需 finally）|
| **性能（低竞争）** | JDK 6+ 偏向锁优化，接近 | 接近 |
| **性能（高竞争）** | 较优 | 较优 |

---

## 三、ReentrantLock 独有功能详解

### 3.1 可中断等待

```java
// 场景：线程等待锁时，可以响应中断（避免死等）
lock.lockInterruptibly(); // 等待过程中可被 interrupt()
try {
    // 临界区
} finally {
    lock.unlock();
}

// 用途：任务取消、超时控制
```

### 3.2 超时尝试加锁

```java
// 尝试 3 秒，获取不到就放弃（避免死锁）
if (lock.tryLock(3, TimeUnit.SECONDS)) {
    try {
        doWork();
    } finally {
        lock.unlock();
    }
} else {
    log.warn("获取锁超时，执行降级逻辑");
    fallback();
}
```

### 3.3 多条件变量（替代 wait/notify）

```java
// 经典生产者-消费者模型
private final ReentrantLock lock = new ReentrantLock();
private final Condition notFull  = lock.newCondition(); // 队列未满
private final Condition notEmpty = lock.newCondition(); // 队列非空

// 生产者
lock.lock();
try {
    while (queue.isFull()) notFull.await();   // 等待"未满"信号
    queue.add(item);
    notEmpty.signal();  // 通知消费者
} finally { lock.unlock(); }

// 消费者
lock.lock();
try {
    while (queue.isEmpty()) notEmpty.await(); // 等待"非空"信号
    Item item = queue.poll();
    notFull.signal();   // 通知生产者
} finally { lock.unlock(); }
```

### 3.4 公平锁

```java
// 按等待顺序获取锁，避免线程饥饿
ReentrantLock fairLock = new ReentrantLock(true);

// 注意：公平锁吞吐量低于非公平锁，因为需要维护队列顺序
// 通常只在有严格公平需求时使用
```

---

## 四、底层实现原理

### synchronized 锁升级（JDK 6+）

```
无锁 → 偏向锁 → 轻量级锁 → 重量级锁
        ↑           ↑           ↑
    首次访问    CAS 自旋      操作系统互斥量
   无竞争时     轻度竞争       激烈竞争
```

- **偏向锁**：对象头 Mark Word 记录线程 ID，同一线程重入无需 CAS
- **轻量级锁**：通过 CAS 操作将 Mark Word 复制到线程栈帧，失败则自旋
- **重量级锁**：升级为操作系统 Mutex，线程挂起，上下文切换开销大

### ReentrantLock 基于 AQS

```
AQS（AbstractQueuedSynchronizer）
  ├─ state：锁的状态（0=未锁，>0=重入次数）
  ├─ exclusiveOwnerThread：当前持锁线程
  └─ 等待队列：CLH 变体双向链表
      Thread1(head) ← Thread2 ← Thread3(tail)
```

---

## 五、选型原则

**优先使用 synchronized**：
- 代码简单，不会忘记释放锁
- JDK 6+ 锁升级优化后性能已很好
- 绝大多数普通同步场景

**选择 ReentrantLock**：
- 需要**可中断**的锁等待
- 需要**超时**获取锁（防死锁）
- 需要**非阻塞**尝试加锁
- 需要**多个条件变量**（如生产者-消费者）
- 需要**公平锁**

---

## 总结

`synchronized` 简洁安全，是首选；`ReentrantLock` 功能强大，在需要可中断、超时、多条件等高级特性时才值得引入。两者性能差异在现代 JVM 上已不显著，选择的核心依据是**功能需求**。
