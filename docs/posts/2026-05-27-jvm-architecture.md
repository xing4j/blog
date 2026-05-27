# JVM-01 JVM 架构总览：类加载、字节码执行与运行时内存

<div class="post-meta">📅 2026-05-27 &nbsp;·&nbsp; 🏷️ <span class="tag">JVM</span></div>

> 📚 **本文属于「JVM 原理与调优实战」系列**
> - 👉 **JVM-01 JVM 架构总览：类加载、字节码执行与运行时内存（本文）**
> - [JVM-02 JVM 内存区域详解：六种 OOM 场景与排查实战](posts/2026-05-27-jvm-memory-areas.md)
> - [JVM-03 JVM 垃圾回收器详解：从 CMS 到 ZGC 的演进](posts/2024-05-27-jvm-gc-collectors.md)
> - [JVM-04 JVM 调优实战：参数配置、GC 日志与 Heap Dump 分析](posts/2024-07-09-jvm-tuning-heapdump.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 20 分钟｜**分类**：Java 核心

同样是 Java 程序员，有人能看懂 GC 日志、快速定位内存泄漏，有人遇到 OOM 只能重启祈祷。差距不在经验多少，而在于**有没有建立 JVM 运行机制的整体认知**。本文从架构全景切入，串联类加载、字节码执行、内存管理三条主线，为后续调优篇奠定基础。

---

## 一、背景：为什么需要 JVM

Java 的核心口号是 **"Write Once, Run Anywhere"**（一次编写，到处运行）。这个承诺背后的关键是 JVM（Java Virtual Machine，Java 虚拟机）——它在操作系统之上建立了一个**统一的运行环境**，让同一份字节码能在 Windows、Linux、macOS 上运行，无需重新编译。

与 C/C++ 程序直接编译成目标平台机器码不同，Java 编译器（javac）只生成**平台无关的字节码**（.class 文件），由各平台的 JVM 负责解释执行或编译成本地机器码：

```
  Java Source (.java)           C/C++ Source (.c/.cpp)
         |  javac                      |  gcc/clang
         v                             v
  Bytecode (.class) -> JVM ->    Machine Code (x86/ARM)
  (platform neutral)   (per OS)  (platform specific)
```

> **说明**：字节码是平台无关的（同一份 .class 可在任意 JVM 上运行），JVM 本身是平台相关的（每个操作系统有对应的 JVM 实现）。

这种设计带来了额外的好处：JVM 可以在运行时做很多 C/C++ 做不到的事，比如**自动内存管理（GC）**、**运行期类型检查**、**JIT 代码优化**等。代价是启动和热身时间比原生程序长，不过对于长期运行的服务端程序来说，这个代价几乎可以忽略。

---

## 二、JVM 整体架构

JVM 规范将运行时划分为三大核心子系统，加上底层的本地接口层：

```
+------------------------------------------------------+
|              Java Bytecode (.class files)            |
+------------------------------------------------------+
                          |
                          v
+======================================================+
|                     JVM Runtime                      |
|                                                      |
|  +--------------------+  +------------------------+  |
|  |  Class Loading     |  |  Runtime Data Areas    |  |
|  |  Subsystem         |  |                        |  |
|  |                    |  |  +---------+ +-------+ |  |
|  |  [Load]            |  |  |  Heap   | |  Meta | |  |
|  |  [Verify]          |  |  | Young+  | | space | |  |
|  |  [Prepare]    -----+->|  | Old Gen | +-------+ |  |
|  |  [Resolve]         |  |  +---------+           |  |
|  |  [Init]            |  |  +-------+  +--------+ |  |
|  +--------------------+  |  | Stack |  | PC Reg | |  |
|                          |  +-------+  +--------+ |  |
|  +--------------------+  +------------------------+  |
|  |  Execution Engine  |                              |
|  |  [Interpreter]     |--> Machine Code              |
|  |  [JIT Compiler]    |                              |
|  |  [GC]              |                              |
|  +--------------------+                              |
|                                                      |
|  +--------------------+                              |
|  |  Native Interface  |                              |
|  |       (JNI)        |--> Native Libraries (.so)    |
|  +--------------------+                              |
+======================================================+
                          |
                          v
+------------------------------------------------------+
|               Operating System                       |
+------------------------------------------------------+
```

三大子系统各司其职：

| 子系统 | 职责 | 关键概念 |
|--------|------|---------|
| 类加载子系统 | 把 .class 文件加载进内存，完成链接和初始化 | ClassLoader、双亲委派 |
| 运行时数据区 | 程序运行期间的内存空间 | 堆、栈、方法区、PC 寄存器 |
| 执行引擎 | 执行字节码，驱动 GC，做 JIT 优化 | 解释器、JIT、垃圾回收 |

---

## 三、类加载子系统

类加载是 JVM 把 .class 文件中的二进制数据读入内存，并转换成堆中 `java.lang.Class` 对象的过程。

### 3.1 触发时机

JVM 采用**懒加载（Lazy Loading）**策略，只在真正需要时才加载并初始化类。以下六种情况会强制触发初始化（称为"主动引用"）：

1. `new` 一个类的实例，或读写类的静态字段/调用静态方法
2. 使用反射：`Class.forName("com.example.Foo")`
3. 初始化子类时，父类尚未初始化
4. JVM 启动时，包含 `main()` 方法的主类
5. JDK 7+ 的 `MethodHandle` 解析到 `REF_getstatic`/`REF_invokestatic` 等
6. 接口定义了 default 方法，其实现类初始化时

仅仅声明一个引用（`Foo foo;`）、或通过子类引用父类静态字段，**不会**触发子类初始化——这类操作属于"被动引用"。

### 3.2 加载的五个阶段

```
[Load] --> [Verify] --> [Prepare] --> [Resolve] --> [Init]
  加载        验证          准备           解析          初始化
```

| 阶段 | 做了什么 | 关键细节 |
|------|---------|---------|
| **Load（加载）** | ClassLoader 读取 .class 字节流，在方法区创建类的内部表示 | 生成堆中的 Class 对象 |
| **Verify（验证）** | 检查字节码格式合法，防止恶意代码破坏 JVM | 失败抛 `VerifyError` |
| **Prepare（准备）** | 为**静态变量**分配内存并赋**默认值**（0/null/false） | 不是代码里写的初始值 |
| **Resolve（解析）** | 把常量池中的符号引用替换成直接引用（内存地址） | 可延迟到使用时 |
| **Init（初始化）** | 执行 `<clinit>()`，按顺序执行静态赋值和静态代码块 | 静态变量获得最终值 |

**关键易错点**：Prepare 阶段赋的是**默认值**，不是代码中的初始值。

```java
// JDK 17
static int timeout = 5000;
static {
    System.out.println(timeout); // 此处已在 Init 阶段，输出 5000
}
// 但 Prepare 阶段结束后，timeout 的值是 0
// 有赖于声明顺序，以下写法会输出 0：
static {
    System.out.println(timeout); // 输出 0，因为 static 块在 timeout 赋值语句之前
}
static int timeout = 5000;
```

### 3.3 双亲委派模型

ClassLoader 形成一条委派链，加载类时**自底向上委托**，只有父加载器找不到才由自己加载：

```
BootstrapClassLoader       (JDK 核心库: java.lang.*, java.util.*)
         ^
         | parent
ExtClassLoader / PlatformCL (JDK 扩展库: javax.*, jdk.*)
         ^
         | parent
AppClassLoader              (应用 classpath)
         ^
         | parent
CustomClassLoader           (Tomcat WebAppCL, OSGi, Spring DevTools...)
```

这保证了 `java.lang.String` 等核心类不会被应用层代码覆盖替换。当需要破坏双亲委派（如 SPI、热部署）时，需要自定义 ClassLoader 并重写 `loadClass()`——这也是 Tomcat、Dubbo、Spring Boot DevTools 的实现基础，详见系列后续文章。

---

## 四、字节码执行引擎

### 4.1 解释执行 vs JIT 编译

JVM 启动时默认用**解释器**逐行翻译字节码。对于**热点代码**（Hot Spot Code），JIT 编译器（Just-In-Time Compiler）会将其编译成**本地机器码**并缓存：

```
冷代码（首次调用）：
  bytecode --> Interpreter --> per-instruction machine ops  (慢)

热点代码（调用 N 次后触发 JIT）：
  bytecode --> JIT Compiler --> native code (cached)
  后续调用  --> native code 直接执行                          (快)
```

热点探测阈值（JDK 17 Server 模式默认值）：

```bash
# 方法调用计数器：方法被调用 10000 次触发编译
-XX:CompileThreshold=10000

# 开启分层编译后，上述阈值降低为约 2000（C1）和 15000（C2）
-XX:+TieredCompilation  # JDK 7+ 默认开启
```

> **为什么 Java 启动后越跑越快？** 正是因为 JIT 需要收集运行时数据（方法调用次数、分支走向、类型信息）才能做出更激进的优化。通常 JVM 需要运行 30 秒到 2 分钟才能达到"热身"状态，这在性能基准测试时必须注意。

### 4.2 分层编译（Tiered Compilation）

HotSpot JVM 有两个 JIT 编译器，通过分层编译协同工作：

| 编译器 | 级别 | 特点 | 典型场景 |
|--------|------|------|---------|
| C1（Client Compiler） | L1~L3 | 编译速度快，优化少，附加 Profiling 埋点 | 启动阶段、短生命周期方法 |
| C2（Server Compiler） | L4 | 编译慢，优化激进，依赖 C1 收集的 Profile | 长期热点方法 |

分层流转路径（多数方法的轨迹）：

```
Interpreter --> C1 (L1, no profiling) --> C1 (L3, full profiling) --> C2 (L4)
```

实际中调用频率极低的方法可能永远停在解释执行，调用量很高的简单方法会被 C2 充分内联。

### 4.3 JIT 的关键优化手段

| 优化技术 | 说明 | 实际效果 |
|---------|------|---------|
| 方法内联（Method Inlining） | 把小方法的代码嵌入调用处，消除方法调用开销 | 最常见也最重要的优化，可减少 50%+ 调用开销 |
| 逃逸分析（Escape Analysis） | 证明对象不会逃逸出方法/线程，则分配在栈上，无需 GC | 减少堆分配，降低 GC 压力 |
| 锁消除（Lock Elision） | 对不会逃逸的对象消除 synchronized 加锁 | 减少同步开销 |
| 去虚化（Devirtualization） | 单态/双态调用点直接内联虚方法 | 减少动态分派开销 |

**逃逸分析示例**：

```java
// JDK 17 — 以下代码，JIT 可能直接在栈上分配 Point 对象，完全不触发 GC
public int sumCoord(int x, int y) {
    Point p = new Point(x, y); // p 不会逃逸出此方法
    return p.x + p.y;          // JIT: 可能内联后直接 return x + y，p 被消除
}
```

通过 `-XX:+PrintEscapeAnalysis -XX:+PrintEliminateAllocations`（JDK 8 调试参数）可以观察逃逸分析决策。

---

## 五、运行时数据区概览

JVM 规范定义的内存区域分为**线程私有**和**线程共享**两类，各区域详细说明见本系列 **[JVM-02 JVM 内存区域详解](posts/2026-05-27-jvm-memory-areas.md)**：

```
+------------------------------------------------+
|              JVM Memory Layout                 |
|                                                |
|  Thread-Private (one per thread):              |
|  +------------+  +------------------+          |
|  | PC Register|  |   JVM Stack      |          |
|  | (bytecode  |  | [Frame][Frame].. |          |
|  |  pointer)  |  | (local vars,     |          |
|  +------------+  |  operand stack)  |          |
|                   +------------------+          |
|                   +------------------+          |
|                   | Native Method    |          |
|                   | Stack            |          |
|                   +------------------+          |
|                                                |
|  Thread-Shared:                                |
|  +------------------------------------------+ |
|  |                  Heap                    | |
|  |  +-------------------+  +-------------+ | |
|  |  |    Young Gen      |  |   Old Gen   | | |
|  |  | [Eden][S0][S1]    |  |             | | |
|  |  +-------------------+  +-------------+ | |
|  +------------------------------------------+ |
|  +------------------------------------------+ |
|  |   Metaspace (off-heap, native memory)    | |
|  |   (class metadata, method bytecodes)     | |
|  +------------------------------------------+ |
|  +------------------------------------------+ |
|  |   Direct Memory (off-heap)               | |
|  |   (NIO ByteBuffer, Netty)                | |
|  +------------------------------------------+ |
+------------------------------------------------+
```

| 区域 | 线程私有 | 会 OOM | JVM 参数 |
|------|---------|--------|---------|
| 程序计数器 | 是 | 否 | — |
| 虚拟机栈 | 是 | SOE / OOM | `-Xss` |
| 本地方法栈 | 是 | OOM | — |
| 堆 | 否（共享）| 是 | `-Xmx`, `-Xms` |
| 元空间 | 否（共享）| 是 | `-XX:MaxMetaspaceSize` |
| 直接内存 | 否（共享）| 是 | `-XX:MaxDirectMemorySize` |

---

## 六、踩坑总结

**❌ 错误：-Xss 设置过大，导致线程栈占用内存爆炸**

```bash
# 错误示例：每个线程分配 8MB 栈空间
-Xss8m

# 风险：应用有 500 个线程时，仅线程栈就占 500 × 8MB = 4GB
# 极易触发 OOM: unable to create new native thread
```

✅ **正确**：`-Xss` 默认值约 512KB，大多数场景足够。只有深递归（递归层数 > 1000）或大量局部变量时才考虑增大，建议设置 `-Xss512k` 或 `-Xss1m`。

---

**❌ 错误：认为 static 变量在类加载后立即赋初始值**

```java
// 错误理解：以为 MyConfig 一被加载，TIMEOUT 就是 3000
class MyConfig {
    static int TIMEOUT = 3000;
}
```

✅ **正确**：Prepare 阶段赋的是类型默认值（`int` 的默认值是 0）。要等到 Init 阶段执行 `<clinit>()` 方法后，TIMEOUT 才被赋值为 3000。若有静态代码块依赖此值，需注意**声明顺序**（静态代码块和静态赋值语句按出现顺序执行）。

---

**❌ 错误：JVM 刚启动就做性能测试，把冷跑结果当基准**

```java
// 错误：第一次执行拿到的是解释执行的耗时，不具代表性
long start = System.nanoTime();
for (int i = 0; i < 100; i++) doHeavyWork(data);
System.out.println(System.nanoTime() - start);
```

✅ **正确**：用 [JMH（Java Microbenchmark Harness）](https://github.com/openjdk/jmh) 做基准测试，框架会自动处理预热（warmup）和多轮测量。至少先预热 10000 次调用，再采集数据。

---

## 七、文章小结

- JVM 在操作系统之上建立统一运行环境，字节码平台无关，JVM 本身平台相关；自动内存管理（GC）是 JVM 带来的核心额外能力
- 类加载分五个阶段；**Prepare 阶段赋默认值，Init 阶段才执行代码中的赋值语句**；双亲委派保护核心类不被覆盖
- JIT 通过热点探测将高频代码编译成机器码；分层编译（C1→C2）兼顾启动速度和峰值性能；性能测试必须充分预热
- 逃逸分析是 JIT 的重要优化基础，能把不逃逸的对象从堆移到栈，大幅降低 GC 压力
- 运行时数据区分线程私有（PC 寄存器、JVM 栈）和线程共享（堆、元空间）；每个区域的 OOM 需针对该区域的参数调优

## 参考资料

- [The Java Virtual Machine Specification, Java SE 21](https://docs.oracle.com/javase/specs/jvms/se21/html/index.html) — Oracle（权威规范，适用 JDK 21）
- 《深入理解 Java 虚拟机（第 3 版）》—— 周志明，机械工业出版社（适用 JDK 11/12）
- [HotSpot Tiered Compilation](https://wiki.openjdk.org/display/HotSpot/Tiered+Compilation) — OpenJDK Wiki
- [JEP 295: Ahead-of-Time Compilation](https://openjdk.org/jeps/295) — 了解 AOT vs JIT 的设计取舍
- [JMH（Java Microbenchmark Harness）](https://github.com/openjdk/jmh) — OpenJDK 官方基准测试框架
