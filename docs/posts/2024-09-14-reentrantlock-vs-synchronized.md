# ReentrantLock vs synchronized：选对锁，写对代码

<div class="post-meta">📅 2024-09-14 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">并发</span></div>

"直接用 synchronized 就行了"——这句话在大多数场景确实正确。但当你需要超时获取锁、锁等待可被中断、或者一把锁对应多个等待条件时，synchronized 就力不从心了。理解两者的差异，本质上是理解 JVM 内置锁与 AQS 框架的设计取舍。

---

## 一、背景：两种锁机制的由来

synchronized 是 Java 最早的同步机制，直接编译为 monitorenter/monitorexit 字节码，由 JVM 全权管理。JDK 1.5 引入 java.util.concurrent（JUC）包后，ReentrantLock 基于 **AQS（AbstractQueuedSynchronizer）** 框架实现，将锁的等待队列和唤醒逻辑暴露给开发者，提供了 synchronized 无法实现的高级功能。

JDK 6 对 synchronized 做了大幅优化（锁升级、偏向锁、自旋锁），两者的性能差距已基本消除，**功能差异**才是选择的真正依据。

---

## 二、核心差异一览

| 特性 | synchronized | ReentrantLock |
|------|---------------|----------------|
| 实现层 | JVM 内置（字节码指令）| Java 代码（AQS 框架）|
| 可重入 | ✅ | ✅ |
| 公平锁 | ❌（始终非公平）| ✅ 可选（构造参数指定）|
| 可中断等待 | ❌ | ✅ lockInterruptibly() |
| 超时尝试 | ❌ | ✅ tryLock(timeout) |
| 非阻塞尝试 | ❌ | ✅ tryLock() |
| 多条件变量 | 1 个（wait/notify）| 多个（newCondition()）|
| 自动释放 | ✅ 异常时自动释放 | ❌ 必须在 finally 中手动 unlock |
| 低竞争性能 | JDK 6+ 偏向锁，极快 | 略慢（AQS 初始化开销）|
| 高竞争性能 | 相当 | 相当 |

---

## 三、底层原理

### synchronized 的锁升级

JDK 6 引入了**锁升级**机制，synchronized 不再直接进入重量级锁，而是经过以下四个状态渐进升级：

```
无锁 → 偏向锁 → 轻量级锁 → 重量级锁
  │         │            │           │
  │ 1 thread  │ contention  │ OS blocked│
  │  no cost  │ CAS spin    │  OS kernel│
  └─→ MarkWord 中存储持有线程 ID
```
- **偏向锁**：第一个加锁的线程将自己的 ThreadID 写入对象 MarkWord，后续再次加锁仅检查 ID，无 CAS 操作
- **轻量级锁**：多线程竞争时，通过 CAS 将锁记录指针写入 MarkWord，自旋等待，不挂起线程
- **重量级锁**：自旋超过阈值，升级为操作系统 Mutex，线程进入阻塞等待

> JDK 15 起偏向锁默认关闭（启动耗时高，现代多线程场景作用有限）。

### ReentrantLock 基于 AQS

ReentrantLock 内部维护一个 AQS 同步状态（state）和一个 CLH 变体等待队列：

```
state = 0         → 锁未持有
state = 1         → 锁已持有（重入时 state 递增）
state = n（n>1）  → 同一线程重入了 n 次

等待队列（双向链表）：
Head ←→ Node(Thread-A) ←→ Node(Thread-B) ←→ Tail
         （等待中）            （等待中）
```
lock() 首先 CAS 尝试将 state 从 0 改为 1，失败则将当前线程封装为 Node 入队，调用 LockSupport.park() 挂起。unlock() 释放锁后，找到队列中的下一个节点，LockSupport.unpark() 唤醒。

---

## 四、ReentrantLock 独有功能实战

### 4.1 可中断等待：防止死等

```java
ReentrantLock lock = new ReentrantLock();

void cancelableTask() throws InterruptedException {
    // ✅ 等待过程中可以响应 Thread.interrupt()
    lock.lockInterruptibly();
    try {
        doWork();
    } finally {
        lock.unlock();
    }
}

// 主线程取消任务
Thread t = new Thread(() -> {
    try {
        cancelableTask();
    } catch (InterruptedException e) {
        System.out.println("Task cancelled, exiting gracefully.");
    }
});
t.start();
t.interrupt();  // 中断等待，线程收到 InterruptedException
```
### 4.2 超时获取锁：避免死锁

```java
ReentrantLock lockA = new ReentrantLock();
ReentrantLock lockB = new ReentrantLock();

void transferMoney(Account from, Account to, int amount) {
    while (true) {
        // 超时尝试获取锁，避免死锁
        if (lockA.tryLock(50, TimeUnit.MILLISECONDS)) {
            try {
                if (lockB.tryLock(50, TimeUnit.MILLISECONDS)) {
                    try {
                        from.debit(amount);
                        to.credit(amount);
                        return;  // 成功，退出循环
                    } finally {
                        lockB.unlock();
                    }
                }
            } finally {
                lockA.unlock();
            }
        }
        // 两个锁没有同时获取到，随机等待后重试（打破死锁僵局）
        Thread.sleep(ThreadLocalRandom.current().nextInt(10));
    }
}
```
### 4.3 多条件变量：有界阻塞队列

synchronized 的 wait/notify 只有一个等待集合，无法区分"等待非空"和"等待非满"两种条件。Condition 可以精确唤醒特定等待集合：

```java
public class BoundedBuffer<T> {
    private final ReentrantLock lock = new ReentrantLock();
    private final Condition notEmpty = lock.newCondition(); // 消费者等待
    private final Condition notFull = lock.newCondition();  // 生产者等待
    private final Queue<T> queue = new ArrayDeque<>();
    private final int capacity;

    public BoundedBuffer(int capacity) { this.capacity = capacity; }

    public void put(T item) throws InterruptedException {
        lock.lock();
        try {
            while (queue.size() == capacity) {
                notFull.await();     // 队列满，生产者等待
            }
            queue.offer(item);
            notEmpty.signal();       // 唤醒一个消费者，精确且高效
        } finally {
            lock.unlock();
        }
    }

    public T take() throws InterruptedException {
        lock.lock();
        try {
            while (queue.isEmpty()) {
                notEmpty.await();    // 队列空，消费者等待
            }
            T item = queue.poll();
            notFull.signal();        // 唤醒一个生产者
            return item;
        } finally {
            lock.unlock();
        }
    }
}
```
> 如果用 synchronized 实现，只能 notifyAll() 唤醒所有等待线程（生产者和消费者都被唤醒），造成大量无效竞争，即"惊群效应"。

### 4.4 公平锁：防止线程饥饿

```java
// 非公平锁（默认）：新来的线程可以插队，吞吐量高但可能有线程长期等待
ReentrantLock unfairLock = new ReentrantLock();

// 公平锁：严格按 FIFO 顺序，防止线程饥饿，但吞吐量略低
ReentrantLock fairLock = new ReentrantLock(true);
```
公平锁适用于：需要严格保证请求顺序、防止某些线程因竞争劣势永远等待的场景（如资源分配系统）。绝大多数场景用非公平锁，性能更好。

---

## 五、如何选择

```
需要可中断等待？                           → ReentrantLock.lockInterruptibly()
需要超时尝试？                             → ReentrantLock.tryLock(timeout)
需要非阻塞尝试？                           → ReentrantLock.tryLock()
需要多个等待条件（精确唤醒）？              → ReentrantLock + Condition
需要公平锁？                               → ReentrantLock(true)
以上都不需要，只需互斥 + 简单等待唤醒？    → synchronized（代码更简洁）
```
**通用建议**：默认用 synchronized，代码简洁、IDE 支持好、不会忘记 unlock。需要以上高级特性时升级为 ReentrantLock。

---

## 六、常见坑点与最佳实践

### 坑 1：忘记在 finally 中 unlock

```java
// ❌ doWork() 抛异常，lock 永远不会 unlock，其他线程全部死锁
lock.lock();
doWork();
lock.unlock();

// ✅ 标准写法：unlock 必须在 finally 块
lock.lock();
try {
    doWork();
} finally {
    lock.unlock();
}
```
### 坑 2：将 lock() 放在 try 外面

```java
// ❌ lock() 本身可能抛出异常（如 OOM），此时 finally 中 unlock() 会抛 IllegalMonitorStateException
try {
    lock.lock();   // 应该在 try 外面！
    doWork();
} finally {
    lock.unlock();
}

// ✅ 标准写法：lock() 调用在 try 块之外
lock.lock();      // lock() 不应在 try 内部
try {
    doWork();
} finally {
    lock.unlock();
}
```
### 坑 3：条件等待不用 while 而用 if

```java
// ❌ 使用 if 检查条件：虚假唤醒（spurious wakeup）后不重新检查，可能直接执行
lock.lock();
try {
    if (queue.isEmpty()) condition.await();  // 醒来后条件可能仍不满足
    queue.poll();
} finally { lock.unlock(); }

// ✅ 始终用 while 循环检查条件
lock.lock();
try {
    while (queue.isEmpty()) condition.await();  // 虚假唤醒后重新检查
    queue.poll();
} finally { lock.unlock(); }
```
---

## 七、总结与延伸

**核心要点**：
- synchronized 经 JDK 6 优化（锁升级）后性能与 ReentrantLock 相当，代码更简洁
- ReentrantLock 提供可中断等待、超时获取、公平锁、多 Condition 四个关键高级特性
- 选锁原则：能用 synchronized 就用，需要高级特性再升级到 ReentrantLock
- ReentrantLock 必须在 finally 中 unlock()，条件等待必须用 while 检查

**延伸阅读方向**：
- StampedLock：Java 8 引入的乐观读锁，适合读多写少场景
- ReadWriteLock（ReentrantReadWriteLock）：读写分离，提升并发读吞吐量
- AQS（AbstractQueuedSynchronizer）源码：理解 CountDownLatch、Semaphore、CyclicBarrier 的共同基础
- Kotlin 协程锁（Mutex）：对比理解协程语境下的同步机制
