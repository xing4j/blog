# Java 并发：ThreadPoolExecutor 参数详解与拒绝策略

<div class="post-meta">📅 2024-08-06 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">并发</span></div>

线程池是 Java 并发编程的基础设施，用好它需要深刻理解其七个核心参数和四种拒绝策略。

---

## 一、ThreadPoolExecutor 七个参数

```java
public ThreadPoolExecutor(
    int corePoolSize,         // 核心线程数
    int maximumPoolSize,      // 最大线程数
    long keepAliveTime,       // 非核心线程空闲存活时间
    TimeUnit unit,            // 时间单位
    BlockingQueue<Runnable> workQueue,   // 任务队列
    ThreadFactory threadFactory,         // 线程工厂
    RejectedExecutionHandler handler     // 拒绝策略
)
```

### 任务提交流程

```
提交任务
   │
   ├─ 当前线程数 < corePoolSize ──→ 创建核心线程执行
   │
   ├─ 当前线程数 >= corePoolSize
   │    ├─ workQueue 未满 ──────→ 任务入队
   │    └─ workQueue 已满
   │         ├─ 当前线程数 < maximumPoolSize → 创建非核心线程执行
   │         └─ 当前线程数 >= maximumPoolSize → 触发拒绝策略
```

### 参数详解

| 参数 | 说明 | 建议 |
|------|------|------|
| `corePoolSize` | 线程池常驻线程数，即使空闲也不销毁 | CPU 密集型：CPU核数+1；IO密集型：CPU核数×2 |
| `maximumPoolSize` | 线程数上限（含核心线程）| 需结合队列容量综合考虑 |
| `keepAliveTime` | 超过核心数的线程空闲多久被回收 | 一般 60s |
| `workQueue` | 任务缓冲队列 | 见下方详述 |
| `threadFactory` | 自定义线程名、优先级、是否守护线程 | 生产必须自定义，便于排查 |
| `handler` | 队列满且线程数达上限时的处理策略 | 见下方详述 |

---

## 二、工作队列类型

| 队列类型 | 容量 | 特点 | 适用场景 |
|---------|------|------|---------|
| `LinkedBlockingQueue` | 默认 Integer.MAX_VALUE（无界）| 不会触发拒绝策略，可能 OOM | 任务量可控时 |
| `ArrayBlockingQueue` | 有界 | 超出即触发拒绝 | 推荐，能感知背压 |
| `SynchronousQueue` | 0（不缓存）| 提交即执行，没有线程则拒绝 | Executors.newCachedThreadPool |
| `PriorityBlockingQueue` | 无界 | 按优先级排序 | 任务有优先级区分 |

> **注意**：`Executors.newFixedThreadPool` 使用无界 `LinkedBlockingQueue`，高负载下可能堆积大量任务导致 OOM，**生产环境建议手动创建线程池**。

---

## 三、四种拒绝策略

```java
// 1. AbortPolicy（默认）：直接抛出 RejectedExecutionException
executor.setRejectedExecutionHandler(new ThreadPoolExecutor.AbortPolicy());

// 2. CallerRunsPolicy：由提交任务的线程自己执行
// 优点：降低提交速度，起到限流效果；缺点：阻塞调用线程
executor.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy());

// 3. DiscardPolicy：静默丢弃，不抛异常（危险，任务丢失）
executor.setRejectedExecutionHandler(new ThreadPoolExecutor.DiscardPolicy());

// 4. DiscardOldestPolicy：丢弃队列中最老的任务，重试提交当前任务
executor.setRejectedExecutionHandler(new ThreadPoolExecutor.DiscardOldestPolicy());
```

**生产推荐**：自定义拒绝策略，记录日志并告警：

```java
executor.setRejectedExecutionHandler((r, pool) -> {
    log.error("线程池已满，任务被拒绝: {}, poolSize={}, queueSize={}",
        r, pool.getPoolSize(), pool.getQueue().size());
    // 可选：写入 MQ 或降级处理
    throw new RejectedExecutionException("系统繁忙，请稍后重试");
});
```

---

## 四、自定义线程工厂（必须）

```java
ThreadFactory namedThreadFactory = new ThreadFactoryBuilder()
    .setNameFormat("order-process-%d")   // 线程名格式（Guava 工具）
    .setDaemon(false)
    .setUncaughtExceptionHandler((t, e) ->
        log.error("线程 {} 发生未捕获异常", t.getName(), e))
    .build();
```

或手动实现：

```java
ThreadFactory factory = new ThreadFactory() {
    private final AtomicInteger counter = new AtomicInteger(1);
    @Override
    public Thread newThread(Runnable r) {
        Thread t = new Thread(r, "biz-pool-" + counter.getAndIncrement());
        t.setDaemon(false);
        return t;
    }
};
```

---

## 五、生产级线程池配置示例

```java
@Configuration
public class ThreadPoolConfig {

    @Bean("orderExecutor")
    public ThreadPoolExecutor orderExecutor() {
        int cpuCount = Runtime.getRuntime().availableProcessors();
        return new ThreadPoolExecutor(
            cpuCount * 2,                          // IO 密集型，核心线程 = 2×CPU
            cpuCount * 4,                          // 最大线程数
            60L, TimeUnit.SECONDS,
            new ArrayBlockingQueue<>(500),          // 有界队列，防 OOM
            new ThreadFactoryBuilder()
                .setNameFormat("order-exec-%d")
                .build(),
            (r, executor) -> {                     // 自定义拒绝策略
                log.error("订单线程池已满，任务被拒绝");
                throw new BizException("系统繁忙");
            }
        );
    }

    @PreDestroy
    public void destroy() {
        orderExecutor().shutdown();                // 优雅关闭
    }
}
```

---

## 六、线程池监控

```java
// 定期打印线程池状态
ScheduledExecutorService monitor = Executors.newSingleThreadScheduledExecutor();
monitor.scheduleAtFixedRate(() -> {
    log.info("线程池状态 - 活跃线程:{} 队列大小:{} 已完成任务:{} 总任务:{}",
        executor.getActiveCount(),
        executor.getQueue().size(),
        executor.getCompletedTaskCount(),
        executor.getTaskCount());
}, 0, 30, TimeUnit.SECONDS);
```

Spring Boot Actuator 也会自动暴露 `@Bean` 注册的线程池指标（需引入 `micrometer`）。

---

## 总结

- 生产环境**禁止使用 Executors 工厂方法**，手动创建并指定有界队列
- 核心线程数：CPU 密集型 ≈ CPU+1，IO 密集型 ≈ CPU×2
- 必须自定义**线程工厂**（命名）和**拒绝策略**（告警 + 降级）
- 通过监控 `activeCount`、`queueSize`、`completedTaskCount` 持续观测线程池健康度
