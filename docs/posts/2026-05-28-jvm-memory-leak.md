# JVM-05 内存泄漏排查实战：ThreadLocal、静态集合与监听器三大模式

<div class="post-meta">📅 2026-05-28 &nbsp;·&nbsp; 🏷️ <span class="tag">JVM</span></div>

> 📚 **本文属于「JVM 原理与调优实战」系列**
> - [JVM-01 JVM 架构总览：类加载、字节码执行与运行时内存](posts/2026-05-27-jvm-architecture.md)
> - [JVM-02 JVM 内存区域详解：六种 OOM 场景与排查实战](posts/2026-05-27-jvm-memory-areas.md)
> - [JVM-03 JVM 垃圾回收器详解：从 CMS 到 ZGC 的演进](posts/2024-05-27-jvm-gc-collectors.md)
> - [JVM-04 JVM 调优实战：参数配置、GC 日志与 Heap Dump 分析](posts/2024-07-09-jvm-tuning-heapdump.md)
> - 👉 **JVM-05 内存泄漏排查实战：ThreadLocal、静态集合与监听器三大模式（本文）**
> - [JVM-06 线程 Dump 实战分析：死锁、线程饥饿与线程泄漏识别](posts/2026-05-28-jvm-thread-dump.md)
> - [JVM-07 类加载机制与双亲委派：破坏场景、热部署与 Metaspace 泄漏](posts/2026-05-28-jvm-classloading.md)
> - [JVM-08 JVM 诊断工具全景：JFR/JMC、Arthas、async-profiler 选型与实战速查](posts/2026-05-28-jvm-profiling-tools.md)

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 35 分钟｜**分类**：Java 核心

服务上线后内存持续增长，Full GC 越来越频繁，重启能恢复——但几小时后又原样。这是内存泄漏的典型症状。与 C++ 的直接泄漏不同，Java 内存泄漏的根因是**对象被意外持有引用，GC 无法回收**。本文聚焦三类最高频的泄漏模式：ThreadLocal 未清理、静态集合无限增长、监听器/回调未注销，配合 MAT + Arthas 的完整排查流程，从堆转储到根因定位一步步讲清楚。

---

## 一、什么是 Java 内存泄漏

Java 有 GC，为什么还会泄漏？核心原因是：**GC 只回收"不可达"对象，但泄漏的对象仍然"可达"——只是业务上已经不需要了**。

```
GC Root (线程栈 / 静态变量 / JNI 引用)
    |
    +-- 长生命周期对象（如 static Map、线程池）
            |
            +-- 业务对象 A（已不再使用，但引用链未断）
                    |
                    +-- 大对象 / 集合 ...  <- GC 无法回收
```

表现特征：

| 特征 | 说明 |
|------|------|
| 内存持续爬升 | 每次 GC 后 Old Gen 基线越来越高 |
| Full GC 频率增加 | 但回收量越来越少（对象存活率高） |
| 重启能恢复 | 说明是运行时积累，不是配置问题 |
| Heap Dump 中有大量"意外"对象 | 某个业务类实例数异常多 |

---

## 二、泄漏模式一：ThreadLocal 未清理

### 2.1 泄漏原理

`ThreadLocal` 的底层是 `Thread` 对象内部的 `ThreadLocalMap`，Map 的 key 是 `ThreadLocal` 实例（`WeakReference`），value 是存入的对象（**强引用**）。

```
Thread
  └── ThreadLocalMap
        ├── Entry[0]: key=WeakRef(ThreadLocal1) -> value=Object1  (强引用!)
        └── Entry[1]: key=WeakRef(ThreadLocal2) -> value=Object2
```

当 `ThreadLocal` 变量本身没有强引用后，key 会被 GC 回收变成 `null`，但 **value 仍然是强引用**，Entry 留在 Map 里无法回收。

在**线程池场景**下问题尤为突出：线程池中的线程生命周期与应用相同，`ThreadLocalMap` 永远不会被清理。每次请求进来都往 `ThreadLocal` 放入新数据，如果不手动 `remove()`，旧 value 就堆积在线程的 Map 里。

### 2.2 复现代码

```java
// JDK 17 + Spring Boot 3.2
@RestController
public class ThreadLocalLeakController {

    // 模拟请求上下文：每次请求放入一个 1MB 的数据
    private static final ThreadLocal<byte[]> CONTEXT = new ThreadLocal<>();

    @GetMapping("/leak")
    public String leak() {
        // 每次请求放入 1MB 数据，但没有 remove()
        CONTEXT.set(new byte[1024 * 1024]); // ❌ 未 remove
        return "ok";
    }
}
```

用线程池处理请求（Tomcat 默认线程数 200），200 个线程各持有 1 MB，就是 200 MB 无法回收。

### 2.3 正确做法

```java
@GetMapping("/no-leak")
public String noLeak() {
    try {
        CONTEXT.set(new byte[1024 * 1024]);
        // 业务逻辑...
        return "ok";
    } finally {
        CONTEXT.remove(); // ✅ finally 块中强制清理
    }
}
```

或者使用 Spring 的 `HandlerInterceptor` 统一清理：

```java
// JDK 17 + Spring Boot 3.2
@Component
public class ThreadLocalCleanupInterceptor implements HandlerInterceptor {

    @Override
    public void afterCompletion(HttpServletRequest req, HttpServletResponse res,
                                Object handler, Exception ex) {
        CONTEXT.remove(); // 每个请求结束后统一清理，不依赖业务代码
    }
}
```

### 2.4 MAT 排查步骤

触发 `jmap -dump:format=b,file=heap.hprof <pid>` 后，在 MAT 中：

1. **Histogram** → 按 `Retained Heap` 降序排列
2. 找到 `byte[]` 或业务对象实例数异常（如 `byte[1048576]` 有几百个）
3. 右键 → **List objects → with incoming references**
4. 追溯引用链，会看到 `ThreadLocalMap$Entry` → `Thread`

```
byte[1048576] x 200
  <- ThreadLocalMap$Entry.value
  <- ThreadLocalMap.table[N]
  <- Thread.threadLocals
  <- "http-nio-8080-exec-1" (thread)
```

---

## 三、泄漏模式二：静态集合无限增长

### 3.1 泄漏原理

`static` 变量是 GC Root，静态集合（`Map`、`List`、`Set`）持有的对象永远可达。如果只往里放不清理，就是典型泄漏。

常见场景：
- 缓存没有 LRU/TTL 淘汰策略
- 事件总线（EventBus）注册后忘记注销
- 单例服务持有业务对象引用（如租户上下文）

### 3.2 复现代码

```java
// JDK 17
public class StaticCacheLeakDemo {

    // ❌ 无界缓存：只进不出
    private static final Map<String, byte[]> CACHE = new HashMap<>();

    public static void addToCache(String key) {
        // 每次调用放入 100KB，key 不重复时永远增长
        CACHE.put(key, new byte[100 * 1024]);
    }

    // 模拟定时任务：每秒生成 100 个不同 key
    @Scheduled(fixedDelay = 10)
    public void scheduledTask() {
        for (int i = 0; i < 100; i++) {
            addToCache(UUID.randomUUID().toString());
        }
    }
}
```

### 3.3 正确做法

```java
// ✅ 方案一：使用 Caffeine 带 TTL 和容量上限的缓存
@Bean
public Cache<String, byte[]> localCache() {
    return Caffeine.newBuilder()
            .maximumSize(1000)           // 最多 1000 个 entry
            .expireAfterWrite(10, TimeUnit.MINUTES) // 写入后 10 分钟过期
            .build();
}

// ✅ 方案二：使用 LinkedHashMap 实现 LRU
private static final Map<String, byte[]> LRU_CACHE =
    Collections.synchronizedMap(new LinkedHashMap<>(200, 0.75f, true) {
        @Override
        protected boolean removeEldestEntry(Map.Entry<String, byte[]> eldest) {
            return size() > 1000; // 超过 1000 个时移除最旧的
        }
    });
```

### 3.4 Arthas 在线排查

不需要重启，用 Arthas 直接检查运行中的 JVM：

```bash
# 连接目标进程
java -jar arthas-boot.jar <pid>

# 查看 StaticCacheLeakDemo 类中 CACHE 字段的大小
ognl "@com.example.StaticCacheLeakDemo@CACHE.size()"
# 输出：@Integer[98432]  <- 9 万多个 entry，明显异常

# 查看 Map 的内存占用（单位：字节）
ognl "@com.example.StaticCacheLeakDemo@CACHE.entrySet().stream()
    .mapToLong(e -> ((byte[])e.getValue()).length).sum()"
```

---

## 四、泄漏模式三：监听器/回调未注销

### 4.1 泄漏原理

发布-订阅模式中，如果事件发布者持有对监听器的强引用，而监听器又持有业务对象引用，就形成一条从 GC Root 到业务对象的强引用链。

```
EventBus (static / 长生命周期)
  └── listeners: List<EventListener>
        └── MyListener (注册但从未注销)
              └── this.userContext (业务对象，应当已释放)
                    └── byte[] data (大对象)
```

Swing、Android、Spring ApplicationContext、Guava EventBus、自定义观察者模式都有这个问题。

### 4.2 复现代码

```java
// JDK 17 + Spring Boot 3.2
@Service
public class OrderService {

    @Autowired
    private ApplicationEventPublisher publisher;

    // 每次创建 OrderProcessor 都注册监听器，但没有注销
    public void processOrder(String orderId) {
        OrderProcessor processor = new OrderProcessor(orderId);
        // ❌ 每次都注册一个新的监听器实例，没有对应的注销逻辑
        publisher.publishEvent(new OrderCreatedEvent(processor));
        // processor 方法结束后，局部变量引用消失
        // 但 ApplicationContext 的监听器列表仍持有它
    }
}

// 实现了 ApplicationListener 的业务类
public class OrderProcessor implements ApplicationListener<OrderEvent> {
    private final byte[] cache = new byte[512 * 1024]; // 每个实例 512KB

    @Override
    public void onApplicationEvent(OrderEvent event) { /* ... */ }
}
```

### 4.3 正确做法

```java
// ✅ 方案一：使用 @EventListener 注解（Spring 管理的 Bean，生命周期由容器控制）
@Component
public class OrderEventHandler {
    @EventListener
    public void handleOrderCreated(OrderCreatedEvent event) {
        // Spring 容器管理，不会泄漏
    }
}

// ✅ 方案二：手动管理，在 destroy 时注销
public class OrderProcessor implements ApplicationListener<OrderEvent>,
                                        DisposableBean {
    private final ApplicationEventMulticaster multicaster;

    public OrderProcessor(ApplicationEventMulticaster multicaster) {
        this.multicaster = multicaster;
        multicaster.addApplicationListener(this); // 注册
    }

    @Override
    public void destroy() {
        multicaster.removeApplicationListener(this); // ✅ 销毁时注销
    }
}

// ✅ 方案三：Guava EventBus 使用 WeakReference 包装
EventBus eventBus = new AsyncEventBus(executor);
// 注册时保持强引用（防止被 GC），不再需要时显式 unregister
eventBus.register(listener);
// ...
eventBus.unregister(listener); // ✅ 明确注销
```

---

## 五、完整排查流程：从告警到根因

### 5.1 第一步：确认是内存泄漏

```bash
# 1. 查看 GC 频率与回收量（采样 5 次，间隔 3 秒）
jstat -gcutil <pid> 3000 5

# 输出示例：
#  S0     S1     E      O      M     CCS    YGC     YGCT    FGC    FGCT     GCT
#   0.00  98.12  23.45  72.31  97.85  95.12    1523   15.231    18    4.832   20.063
#   0.00  98.12  41.23  74.89  97.85  95.12    1524   15.241    18    4.832   20.073
#   0.00   0.00  12.34  77.62  97.85  95.12    1525   15.251    19    5.134   20.385
#
# Old Gen (O 列) 每次 Full GC 后基线都在上升 -> 内存泄漏特征
```

Old Gen 回收后基线持续上升是最强信号。

### 5.2 第二步：获取 Heap Dump

```bash
# 方式一：进程运行时生成（推荐，影响小）
jcmd <pid> GC.heap_dump /tmp/heap.hprof

# 方式二：OOM 时自动生成（提前配置）
-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp/oom.hprof

# 方式三：jmap（会触发 Full GC，生产慎用）
jmap -dump:format=b,live,file=/tmp/heap.hprof <pid>
```

### 5.3 第三步：MAT 分析——找到泄漏疑点

打开 MAT（Eclipse Memory Analyzer），执行 **Leak Suspects Report**（自动分析）：

```
Problem Suspect 1
=================
One instance of "java.util.HashMap" loaded by "jdk.internal.loader.ClassLoaders$AppClassLoader"
occupies 856,123,456 (68.4%) bytes.

The memory is accumulated in one instance of "java.util.HashMap$Node[]"
loaded by "<system class loader>", which occupies 856,123,392 bytes.

Keywords: java.util.HashMap, StaticCacheLeakDemo.CACHE
```

然后在 **Dominator Tree** 中找到该对象，右键 → **Path to GC Roots** → **Exclude weak references**，追溯根因。

### 5.4 第四步：Arthas 在线验证（不重启）

```bash
# 连接目标 JVM
java -jar arthas-boot.jar

# 实时监控某个类的实例数量变化（每 5 秒打印一次）
watch com.example.OrderProcessor * "{target}" -n 5 -x 1

# 查看 heap 中某个类的实例数（类似 MAT Histogram）
# Arthas 4.x 支持 heapdump 命令
heapdump --live /tmp/arthas-heap.hprof

# 用 ognl 直接查询静态字段
ognl "@com.example.StaticCacheLeakDemo@CACHE.size()"

# 强制 GC 后再看（排查 GC 是否能回收）
ognl "java.lang.System.gc()"
ognl "@com.example.StaticCacheLeakDemo@CACHE.size()"
```

### 5.5 第五步：定位代码位置

MAT 中找到问题对象后，在 **Incoming References** 中追溯引用链，通常 3-5 层就能找到是哪个 `ThreadLocal`、哪个静态字段、哪个监听器列表持有它。

```
[Root] Thread "http-nio-8080-exec-5"
  -> Thread.threadLocals (ThreadLocalMap)
    -> ThreadLocalMap$Entry[7]
      -> value: UserContext (你的业务对象)
        -> byte[] data (10MB)
```

---

## 六、三类泄漏对比

| 泄漏模式 | 触发场景 | GC 表现 | MAT 特征 | 修复方式 |
|---------|---------|---------|---------|---------|
| ThreadLocal 未清理 | 线程池 + ThreadLocal | Old Gen 基线爬升 | `ThreadLocalMap$Entry` 链 | finally 中 `remove()` |
| 静态集合无限增长 | 缓存/注册表无上限 | Old Gen 持续增长 | 大 HashMap/ArrayList | 加 LRU/TTL 或容量限制 |
| 监听器未注销 | 观察者模式频繁注册 | 堆中大量监听器实例 | Listener 引用链 | 注销或使用弱引用 |

---

## 七、踩坑总结

**❌ 错误做法 1**：ThreadLocal 放在 try 块但 remove 在 catch 里

```java
try {
    CONTEXT.set(data);
    riskyMethod(); // 可能抛异常
} catch (Exception e) {
    CONTEXT.remove(); // ❌ 只有异常时才清理，正常路径泄漏！
}
```

**✅ 正确做法**：remove 必须在 finally 块

```java
try {
    CONTEXT.set(data);
    riskyMethod();
} finally {
    CONTEXT.remove(); // ✅ 无论是否异常都执行
}
```

---

**❌ 错误做法 2**：缓存 key 用 `Object` 而非基本类型，导致 `hashCode/equals` 失效

```java
// ❌ key 是自定义对象但没有重写 equals/hashCode
Map<Request, Response> cache = new HashMap<>();
cache.put(new Request("user1"), response); // 每次 new Request 是不同 key
// 相同请求会不断插入新 entry，永远不会命中
```

**✅ 正确做法**：用不可变值对象作 key，或用 String ID

---

**❌ 错误做法 3**：以为 `WeakHashMap` 能自动解决所有缓存泄漏

```java
// ❌ 误区：WeakHashMap key 是 WeakReference，但 value 还是强引用
// 如果 value 反向引用了 key，key 就永远不会被回收
Map<MyKey, MyValue> cache = new WeakHashMap<>();
// MyValue 内部持有 MyKey 引用 -> 循环引用 -> key 永远强可达 -> 永远不回收
```

**✅ 正确做法**：真正需要弱缓存时，用 `Caffeine` 的 `weakKeys()` + `weakValues()`

---

## 八、文章小结

1. **Java 内存泄漏 = 对象业务上已无用，但仍有强引用链连接到 GC Root**，GC 无法回收。
2. **ThreadLocal 泄漏**的根因是线程池线程长生命周期 + value 强引用，修复关键是 finally 中必须 `remove()`。
3. **静态集合泄漏**本质是无界数据结构，正确做法是引入 Caffeine 等有淘汰策略的缓存组件。
4. **监听器泄漏**在发布者持有订阅者强引用时发生，Spring `@EventListener` 注解由容器管理，是最安全的方式。
5. **排查流程**：jstat 确认泄漏特征 → jcmd heap_dump 获取快照 → MAT Leak Suspects 定位 → Arthas 在线验证，四步缺一不可。

---

## 九、参考资料

- [Eclipse Memory Analyzer (MAT) 官方文档](https://eclipse.dev/mat/docs/)（适用 MAT 1.14+）
- [Arthas 用户文档](https://arthas.aliyun.com/doc/)（适用 Arthas 3.7+）
- 《深入理解 Java 虚拟机》第 3 版，周志明著，第 3 章"垃圾收集器与内存分配策略"
- [JDK ThreadLocal 源码](https://github.com/openjdk/jdk/blob/master/src/java.base/share/classes/java/lang/ThreadLocal.java)（JDK 21）
- [Caffeine 缓存库](https://github.com/ben-manes/caffeine)（3.x 版本）
