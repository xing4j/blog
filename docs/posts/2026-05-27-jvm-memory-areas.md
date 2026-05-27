# JVM-02 JVM 内存区域详解：六种 OOM 场景与排查实战

<div class="post-meta">📅 2026-05-27 &nbsp;·&nbsp; 🏷️ <span class="tag">JVM</span></div>

> 📚 **本文属于「JVM 原理与调优实战」系列**
> - [JVM-01 JVM 架构总览：类加载、字节码执行与运行时内存](posts/2026-05-27-jvm-architecture.md)
> - 👉 **JVM-02 JVM 内存区域详解：六种 OOM 场景与排查实战（本文）**
> - [JVM-03 JVM 垃圾回收器详解：从 CMS 到 ZGC 的演进](posts/2024-05-27-jvm-gc-collectors.md)
> - [JVM-04 JVM 调优实战：参数配置、GC 日志与 Heap Dump 分析](posts/2024-07-09-jvm-tuning-heapdump.md)

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 30 分钟｜**分类**：Java 核心

OOM 告警触发，第一反应是"加内存"——这个直觉在大多数情况下都是错的。`Java heap space`、`Metaspace`、`Direct buffer memory`、`unable to create new native thread`，每种 OOM 对应不同的内存区域，加堆并不能解决 Metaspace 溢出。本文逐一讲解 JVM 六大内存区域的结构与边界，并用可复现的代码演示每种 OOM 的触发场景和排查思路。

---

## 一、运行时数据区全景

JVM 规范（JVMS）将运行时内存分为以下几个区域，按**线程隔离性**划分为两类：

```
+----------------------------------------------------------+
|                   JVM Memory Layout                      |
|                                                          |
|  Thread-Private (isolated per thread):                   |
|  +---------------+  +-----------------------------+     |
|  |  PC Register  |  |       JVM Stack             |     |
|  | (bytecode idx)|  |  +--------+  +--------+     |     |
|  +---------------+  |  | Frame1 |  | Frame2 |...  |     |
|                      |  | local  |  | local  |     |     |
|  +---------------+   |  | vars   |  | vars   |     |     |
|  | Native Method |   |  +--------+  +--------+     |     |
|  | Stack         |   +-----------------------------+     |
|  +---------------+                                       |
|                                                          |
|  Thread-Shared (all threads):                            |
|  +------------------------------------------------------+|
|  |                       Heap                           ||
|  |  +------------------------+  +------------------+   ||
|  |  |       Young Gen        |  |     Old Gen      |   ||
|  |  | +---------+--+------+  |  |  long-lived obj  |   ||
|  |  | |  Eden   |S0|  S1  |  |  +------------------+   ||
|  |  | +---------+--+------+  |                          ||
|  |  +------------------------+                          ||
|  +------------------------------------------------------+|
|  +------------------------------------------------------+|
|  |    Metaspace  (off-heap, native memory)              ||
|  |    class metadata / method bytecodes / interned str  ||
|  +------------------------------------------------------+|
|  +------------------------------------------------------+|
|  |    Direct Memory  (off-heap)                         ||
|  |    NIO ByteBuffer.allocateDirect / Netty ByteBuf     ||
|  +------------------------------------------------------+|
+----------------------------------------------------------+
```

---

## 二、各区域详解

### 2.1 程序计数器（PC Register）

**是什么**：每条线程独占一个 PC 寄存器，记录当前线程正在执行的字节码指令地址。

**特点**：
- 占用内存极小，生命周期与线程相同
- 执行 Java 方法时存储字节码行号；执行 Native 方法时值为 `undefined`
- **唯一一个不会 OOM 的区域**（JVM 规范明确规定）

### 2.2 虚拟机栈（JVM Stack）

**是什么**：每条线程私有，生命周期与线程相同。每次方法调用创建一个**栈帧（Stack Frame）**，帧内包含：

| 组成部分 | 内容 | 典型大小 |
|---------|------|---------|
| 局部变量表 | 方法参数 + 局部变量（基本类型 + 对象引用）| 编译期确定 |
| 操作数栈 | 字节码指令的运算中间值 | 编译期确定 |
| 动态链接 | 指向运行时常量池中该方法的符号引用 | 固定 |
| 方法返回地址 | 记录调用者的 PC，用于方法返回 | 固定 |

**两种异常**：
- **StackOverflowError**：线程请求的栈深度超过 JVM 允许的最大深度（无限递归的典型报错）
- **OutOfMemoryError**（较少见）：动态扩展虚拟机栈时内存不足

**控制参数**：`-Xss`，默认值 Linux 512KB，Windows 约 256KB（JDK 版本有差异）。

### 2.3 本地方法栈（Native Method Stack）

与虚拟机栈类似，但服务于 JNI（Java Native Interface）调用的 Native 方法。HotSpot JVM 实现中，虚拟机栈和本地方法栈**合并为同一个栈**，可以用 `-Xss` 统一控制。Native 方法的栈溢出同样抛出 `StackOverflowError`。

### 2.4 堆（Heap）

**是什么**：JVM 中最大的一块内存，所有线程共享，**几乎所有对象实例都在堆上分配**。

堆按**分代**划分：

```
+-----------------------------------------------+
|                    Heap                        |
|  +-----------------------------+               |
|  |         Young Gen (新生代)  |               |
|  |  +----------+  +----+----+  |               |
|  |  |  Eden    |  | S0 | S1 |  |               |
|  |  | (80% YG) |  |10% |10% |  |               |
|  |  +----------+  +----+----+  |               |
|  +-----------------------------+               |
|  +-----------------------------+               |
|  |        Old Gen (老年代)     |               |
|  |  long-lived objects         |               |
|  +-----------------------------+               |
+-----------------------------------------------+
```

> **ZGC/Shenandoah 注意**：JDK 15+ 的 ZGC 和 Shenandoah GC 不再使用分代模型（JDK 21 ZGC 引入了分代模式但属可选）。使用这些 GC 时，堆不再有 Young/Old 的区分。

**分代晋升流程**（G1/Serial/ParallelGC）：
1. 新对象优先在 Eden 区分配
2. Minor GC 后存活对象移入 Survivor（S0 或 S1），年龄 +1
3. 年龄达到阈值（默认 15）或 Survivor 空间不足，晋升到 Old Gen
4. Old Gen 满时触发 Full GC / Major GC

**控制参数**：

```bash
-Xmx4g          # 堆最大值（建议 = -Xms，避免动态扩容触发 Full GC）
-Xms4g          # 堆初始值
-Xmn1g          # Young Gen 大小（G1 不推荐设置，交给 G1 自动调整）
```

### 2.5 方法区与元空间（Metaspace）

**方法区**是 JVM 规范中的概念，存储**类元数据**：

| 存储内容 | 说明 |
|---------|------|
| 类结构信息 | 类名、父类、接口、字段、方法 |
| 方法字节码 | 编译后的字节码指令 |
| 运行时常量池 | 字面量、符号引用 |
| JIT 编译后的代码 | 热点方法的本地机器码（部分实现） |

**实现演进**：

| 版本 | 实现 | 内存位置 | OOM 类型 |
|------|------|---------|---------|
| JDK 7 及以前 | PermGen（永久代）| JVM 堆内 | `OutOfMemoryError: PermGen space` |
| JDK 8+ | Metaspace（元空间）| 本地内存（off-heap）| `OutOfMemoryError: Metaspace` |

PermGen 改为 Metaspace 的动机：PermGen 大小固定（默认 64MB）且难以精确预估，Metaspace 使用本地内存，默认没有上限，更弹性但同样需要设置上限防止无限增长（特别是动态代理/CGLIB 频繁生成类的场景）。

**控制参数**：

```bash
-XX:MetaspaceSize=256m      # 初始大小（同时是触发 Full GC 的阈值）
-XX:MaxMetaspaceSize=512m   # 必须设置上限，防止无限增长
```

### 2.6 直接内存（Direct Memory）

**是什么**：不属于 JVM 规范定义的数据区，而是通过 JDK NIO 的 `ByteBuffer.allocateDirect()` 或 Netty 的 `PooledDirectByteBuf` 在**操作系统本地内存**中分配的缓冲区。

**优势**：避免 Java 堆 ↔ 内核缓冲区之间的数据拷贝（零拷贝），NIO/Netty 网络编程的核心优化。

**风险**：不受 GC 管理（由 `Cleaner` 机制或引用队列延迟释放），容易造成物理内存不足。

**控制参数**：

```bash
-XX:MaxDirectMemorySize=2g  # 默认等于 -Xmx，建议显式设置
```

---

## 三、六种 OOM 场景实战排查

### 3.1 StackOverflowError（栈溢出）

**触发条件**：方法递归调用层数超过栈深度上限。

```java
// JDK 17 — 复现：无限递归
public class StackOverflowDemo {
    public static void main(String[] args) {
        recurse(0);
    }

    static void recurse(int depth) {
        // 每次调用创建一个新栈帧（局部变量 depth + 方法返回地址）
        System.out.println("depth: " + depth);
        recurse(depth + 1); // 不设终止条件，无限递归
    }
    // 输出：depth: 0, 1, 2, ... 直到抛出：
    // java.lang.StackOverflowError
}
```

**真实场景**：
- 对象序列化/反序列化遇到循环引用（如 JSON 序列化 `@Entity` 双向关联）
- 递归解析嵌套层数过深的 XML/JSON
- AOP 代理链过长触发的栈帧堆积

**排查**：

```bash
# 1. 看异常堆栈，找到最深处重复出现的方法名
# 2. 判断是逻辑 Bug（无限递归）还是合理递归超限

# 3. 若是合理递归，适当增大栈空间（但要评估线程数）
-Xss2m  # 将栈空间从默认 512k 扩大到 2m
```

✅ **根本解法**：将递归改为迭代（用显式栈 `Deque` 模拟），或限制最大递归深度。

### 3.2 OutOfMemoryError: Java heap space（堆溢出）

**触发条件**：GC 后堆中仍然没有足够空间分配新对象。

```java
// JDK 17 — 复现：不断向 List 中添加对象，持有强引用防止 GC 回收
public class HeapOOMDemo {
    public static void main(String[] args) {
        List<byte[]> data = new ArrayList<>();
        int count = 0;
        try {
            while (true) {
                data.add(new byte[1024 * 1024]); // 每次分配 1MB
                count++;
            }
        } catch (OutOfMemoryError e) {
            System.out.println("OOM after allocating " + count + "MB");
            throw e;
        }
        // 运行参数：-Xmx64m，输出：OOM after allocating 63MB
        // 抛出：java.lang.OutOfMemoryError: Java heap space
    }
}
```

**真实场景**：
- 查询数据库时 `select *` 全表加载进内存
- 缓存容量无限制（`HashMap` 不断 put，从不淘汰）
- 大文件一次性读取到 `byte[]`

**排查流程**：

```bash
# 步骤 1：开启 OOM 时自动 dump（生产必配）
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/tmp/heap.hprof

# 步骤 2：用 jstat 观察 Old Gen 增长趋势
jstat -gcutil <PID> 5000  # 每 5 秒打印一次 GC 统计

# 步骤 3：MAT（Memory Analyzer Tool）分析 heap dump
# 打开 Leak Suspects 报告，找持有最多内存的对象路径
```

### 3.3 OutOfMemoryError: GC overhead limit exceeded

**触发条件**：JVM 花费超过 **98% 的时间**在做 GC，但每次 GC 只回收不到 **2%** 的堆空间，连续发生多次后触发。

本质是**堆空间严重不足**的另一种表现形式——堆没有立刻耗尽，但 GC 效率已极低，服务事实上已不可用。

```java
// JDK 17 — 复现：持续分配生命周期略长的小对象，使 Old Gen 缓慢填满
public class GCOverheadDemo {
    static final Map<String, byte[]> cache = new HashMap<>();

    public static void main(String[] args) {
        int i = 0;
        while (true) {
            // 每个 key 不重复，HashMap 无限膨胀
            cache.put("key-" + i++, new byte[1024]);
            if (i % 10000 == 0) System.out.println("entries: " + i);
        }
        // 运行参数：-Xmx64m，最终抛出：
        // java.lang.OutOfMemoryError: GC overhead limit exceeded
    }
}
```

**排查**：同堆溢出（heap dump 分析），通常根因是缓存/集合无限增长。

**关闭此限制**（不推荐）：`-XX:-UseGCOverheadLimit`，只是推迟了必然到来的 OOM。

### 3.4 OutOfMemoryError: Metaspace

**触发条件**：类元数据占用的本地内存超过 `-XX:MaxMetaspaceSize` 限制（未设置则取决于操作系统可用内存）。

**高危场景**：CGLIB/Javassist/ByteBuddy 动态生成大量代理类，每个代理类的元数据都存入 Metaspace。

```java
// JDK 17 — 复现：用 CGLIB 动态生成无限数量的子类
// 依赖：cglib 3.3.0
public class MetaspaceOOMDemo {
    public static void main(String[] args) {
        int count = 0;
        try {
            while (true) {
                Enhancer enhancer = new Enhancer();
                enhancer.setSuperclass(MetaspaceOOMDemo.class);
                // 每次设置不同的 Callback，CGLIB 无法复用已有代理类，每次生成新类
                enhancer.setUseCache(false);
                enhancer.setCallback((MethodInterceptor) (obj, method, args1, proxy) ->
                        proxy.invokeSuper(obj, args1));
                enhancer.create();
                System.out.println("classes generated: " + (++count));
            }
        } catch (OutOfMemoryError e) {
            System.out.println("Metaspace OOM after " + count + " classes");
        }
        // 运行参数：-XX:MaxMetaspaceSize=64m
        // 抛出：java.lang.OutOfMemoryError: Metaspace
    }
}
```

**排查**：

```bash
# 1. 确认是 Metaspace 而非堆（看 OOM 消息中的区域名称）

# 2. 查看 Metaspace 使用量
jcmd <PID> VM.native_memory summary scale=MB | grep Metaspace
# 输出示例：
#   Metaspace (reserved=64MB, committed=58MB)

# 3. 统计已加载类的数量
jmap -clstats <PID>
# 观察 ClassLoader 数量异常增多 -> 指向动态代理泄漏

# 4. MAT 分析：关注 ClassLoader 对象数量和每个 ClassLoader 加载的类
```

**常见根因**：
- Spring Boot 开发环境 DevTools 热重载配合 CGLIB 导致 ClassLoader 堆积
- 未关闭的 Groovy 脚本引擎（每次执行都编译成新类）
- 自定义 ClassLoader 未卸载

### 3.5 OutOfMemoryError: Direct buffer memory

**触发条件**：`ByteBuffer.allocateDirect()` 申请的直接内存超过 `-XX:MaxDirectMemorySize`（默认等于 `-Xmx`）。

```java
// JDK 17 — 复现：持续申请直接内存不释放
// 运行参数：-XX:MaxDirectMemorySize=64m
public class DirectOOMDemo {
    public static void main(String[] args) {
        List<ByteBuffer> buffers = new ArrayList<>();
        int count = 0;
        try {
            while (true) {
                // allocateDirect 分配在 OS 本地内存，不受堆 GC 管理
                buffers.add(ByteBuffer.allocateDirect(1024 * 1024)); // 1MB
                count++;
            }
        } catch (OutOfMemoryError e) {
            System.out.println("Direct OOM after " + count + "MB");
            // 抛出：java.lang.OutOfMemoryError: Direct buffer memory
        }
    }
}
```

**真实场景**：
- Netty 使用 `PooledDirectByteBuf` 做 I/O，连接数过高时池化缓存积压
- NIO 文件传输时 `FileChannel.map()` 内存映射文件过多

**排查**：

```bash
# 1. 查看直接内存使用
jcmd <PID> VM.native_memory summary scale=MB | grep "Internal"

# 2. Arthas：查找持有 DirectByteBuffer 的对象
[arthas]$ heapdump --live /tmp/heap.hprof
# MAT 中搜索 java.nio.DirectByteBuffer 实例及其 GC Root 引用链

# 3. 临时缓解：主动触发 GC（DirectByteBuffer 由 Cleaner 在 GC 时释放）
jcmd <PID> GC.run
```

### 3.6 OutOfMemoryError: unable to create new native thread

**触发条件**：JVM 无法为新线程申请到操作系统线程资源。

**根因**：操作系统限制了进程可创建的最大线程数（Linux 默认约 1024，由 `ulimit -u` 控制），或进程地址空间不足（32 位 JVM）。

```java
// JDK 17 — 复现：无限创建线程不回收
public class ThreadOOMDemo {
    public static void main(String[] args) {
        int count = 0;
        try {
            while (true) {
                new Thread(() -> {
                    try { Thread.sleep(Long.MAX_VALUE); }  // 线程永不退出
                    catch (InterruptedException ignored) {}
                }).start();
                System.out.println("threads: " + (++count));
            }
        } catch (OutOfMemoryError e) {
            System.out.println("Native thread OOM at: " + count + " threads");
            // 抛出：java.lang.OutOfMemoryError: unable to create new native thread
        }
    }
}
```

**排查与解决**：

```bash
# 1. 查看当前进程线程数
ls /proc/<PID>/task | wc -l         # Linux：统计线程数
jstack <PID> | grep '^"' | wc -l    # 统计 jstack 输出的线程数

# 2. 查看 ulimit 限制
ulimit -u   # 输出：max user processes（线程上限）

# 3. 临时扩大（需 root）
ulimit -u 65535

# 4. 永久修改（/etc/security/limits.conf）
# appuser   soft   nproc   65535
# appuser   hard   nproc   65535
```

**根本解法**：
- 避免无限制创建线程：使用**线程池**（`ThreadPoolExecutor`）控制并发
- 减少 `-Xss` 大小：每个线程栈 512KB 时，相同物理内存可支撑更多线程
- 采用异步非阻塞架构（Netty、WebFlux）减少线程数量

---

## 四、内存参数速查表

| 内存区域 | JVM 参数 | 典型生产值 | 说明 |
|---------|---------|-----------|------|
| 堆最大值 | `-Xmx` | 容器内存的 50~70% | 留余量给 OS、Metaspace、直接内存 |
| 堆初始值 | `-Xms` | = `-Xmx` | 避免堆动态扩容触发 Full GC |
| 新生代大小 | `-Xmn` | 堆的 1/3（G1 不推荐手动设置）| G1 由 `-XX:MaxGCPauseMillis` 自动调 |
| 线程栈大小 | `-Xss` | `512k`~`1m` | 线程多时用小值；深递归用大值 |
| 元空间初始 | `-XX:MetaspaceSize` | `256m` | 触发 Full GC 的阈值 |
| 元空间上限 | `-XX:MaxMetaspaceSize` | `512m` | 动态代理多的应用适当增大 |
| 直接内存 | `-XX:MaxDirectMemorySize` | `1g`~`2g` | Netty/NIO 场景必须显式设置 |
| OOM 自动 dump | `-XX:+HeapDumpOnOutOfMemoryError` | 必开 | 生产环境无条件开启 |
| Dump 路径 | `-XX:HeapDumpPath=/logs/` | — | 指定到有足够空间的目录 |

**完整生产启动参数示例**（JDK 17 + G1GC，4 核 8GB 容器）：

```bash
# JDK 17, G1GC, 8GB container
java \
  -Xms4g -Xmx4g \
  -Xss512k \
  -XX:MetaspaceSize=256m -XX:MaxMetaspaceSize=512m \
  -XX:MaxDirectMemorySize=1g \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  -Xlog:gc*:file=/logs/gc.log:time,level,tags:filecount=10,filesize=50m \
  -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=/logs/ \
  -jar app.jar
```

---

## 五、踩坑总结

**❌ 错误：看到 OOM 就增大 `-Xmx`**

```bash
# 发生了 Metaspace OOM，错误地增大堆
-Xmx8g   # 没有效果，Metaspace 在堆外
```

✅ **正确**：先看清楚 OOM 消息中的区域名称，再对症下药：

| OOM 消息 | 对应区域 | 正确参数 |
|---------|---------|---------|
| `Java heap space` | 堆 | `-Xmx` |
| `GC overhead limit exceeded` | 堆 | `-Xmx` + 排查泄漏 |
| `Metaspace` | 元空间 | `-XX:MaxMetaspaceSize` |
| `Direct buffer memory` | 直接内存 | `-XX:MaxDirectMemorySize` |
| `unable to create new native thread` | OS 线程资源 | `ulimit -u` + 减少线程数 |

---

**❌ 错误：生产环境没有开启 Heap Dump on OOM**

```
# 没有配置，OOM 发生后进程崩溃，无任何分析材料
java -Xmx4g -jar app.jar
```

✅ **正确**：无论任何生产环境，以下两个参数必须开启：

```bash
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/logs/heap-$(hostname).hprof
```

dump 文件可能几 GB，确保目标路径有足够磁盘空间，并配置定期清理。

---

**❌ 错误：误以为 DirectByteBuffer 对象被 GC 回收后直接内存立即释放**

```java
// 错误认知：buffer 被 GC 回收 -> 直接内存立即释放
ByteBuffer buffer = ByteBuffer.allocateDirect(100 * 1024 * 1024);
buffer = null;  // 不能保证直接内存马上释放
System.gc();    // 只是"建议" GC，不保证触发
```

✅ **正确**：DirectByteBuffer 的直接内存通过 `sun.misc.Cleaner`（一种 PhantomReference 机制）在 GC 发现 DirectByteBuffer 对象不可达时**异步释放**，延迟无法保证。对 NIO/Netty 场景，应：
1. 复用 ByteBuffer（对象池化），而非频繁 allocate/release
2. 使用 Netty 的 `ReferenceCountUtil.release()` 显式释放
3. 设置合理的 `-XX:MaxDirectMemorySize` 上限

---

**❌ 错误：容器环境中不设置 `-Xmx`，依赖 JVM 自动检测内存**

```bash
# Docker 容器限制 2GB，JVM 自动把 Xmx 设为宿主机物理内存的 1/4（如 64GB × 1/4 = 16GB）
# 导致 JVM 实际申请内存远超容器限制，被 OOM Killer 直接 kill
java -jar app.jar
```

✅ **正确**：JDK 11+ 的 JVM 已能识别容器 cgroup 限制（`-XX:+UseContainerSupport` 默认开启），但仍推荐显式设置 `-Xmx`，避免意外情况：

```bash
# 容器 2GB 内存，推荐分配方案：
-Xmx1200m -Xms1200m \
-XX:MaxMetaspaceSize=256m \
-XX:MaxDirectMemorySize=256m
# 留约 300MB 给 OS、线程栈、本地代码等
```

---

## 六、文章小结

- JVM 内存分线程私有（PC 寄存器、虚拟机栈、本地方法栈）和线程共享（堆、元空间、直接内存）；不同区域会抛出**不同类型的 OOM**，排查时先看清楚消息
- 堆（`-Xmx/-Xms`）存放对象实例，堆 OOM 首先排查内存泄漏而非直接加内存
- 元空间（`-XX:MaxMetaspaceSize`）存放类元数据，动态代理/脚本引擎大量生成类时需重点关注
- 直接内存（`-XX:MaxDirectMemorySize`）被 NIO/Netty 使用，不受 GC 管理，需复用而非频繁分配
- 线程 OOM（`unable to create new native thread`）本质是 OS 线程资源耗尽，根本解法是使用线程池和异步模型
- 生产环境必须开启 `-XX:+HeapDumpOnOutOfMemoryError`，出问题时有 dump 文件才能排查根因

## 参考资料

- [The Java Virtual Machine Specification, Java SE 21](https://docs.oracle.com/javase/specs/jvms/se21/html/index.html) — Oracle（权威规范）
- 《深入理解 Java 虚拟机（第 3 版）》—— 周志明，机械工业出版社（适用 JDK 11/12）
- [JEP 387: Elastic Metaspace](https://openjdk.org/jeps/387) — JDK 16，改进了 Metaspace 内存归还机制
- [Eclipse MAT（Memory Analyzer Tool）](https://eclipse.dev/mat/) — 最常用的 heap dump 分析工具
- [Arthas 官方文档](https://arthas.aliyun.com/doc/) — 阿里开源 Java 在线诊断工具（适用 JDK 8+）
