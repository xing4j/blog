# JVM-07 类加载机制与双亲委派：破坏场景、热部署与 Metaspace 泄漏

<div class="post-meta">📅 2026-05-28 &nbsp;·&nbsp; 🏷️ <span class="tag">JVM</span></div>

> 📚 **本文属于「JVM 原理与调优实战」系列**
> - [JVM-01 JVM 架构总览：类加载、字节码执行与运行时内存](posts/2026-05-27-jvm-architecture.md)
> - [JVM-02 JVM 内存区域详解：六种 OOM 场景与排查实战](posts/2026-05-27-jvm-memory-areas.md)
> - [JVM-03 JVM 垃圾回收器详解：从 CMS 到 ZGC 的演进](posts/2024-05-27-jvm-gc-collectors.md)
> - [JVM-04 JVM 调优实战：参数配置、GC 日志与 Heap Dump 分析](posts/2024-07-09-jvm-tuning-heapdump.md)
> - [JVM-05 内存泄漏排查实战：ThreadLocal、静态集合与监听器三大模式](posts/2026-05-28-jvm-memory-leak.md)
> - [JVM-06 线程 Dump 实战分析：死锁、线程饥饿与线程泄漏识别](posts/2026-05-28-jvm-thread-dump.md)
> - 👉 **JVM-07 类加载机制与双亲委派：破坏场景、热部署与 Metaspace 泄漏（本文）**
> - [JVM-08 JVM 诊断工具全景：JFR/JMC、Arthas、async-profiler 选型与实战速查](posts/2026-05-28-jvm-profiling-tools.md)

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 35 分钟｜**分类**：Java 核心

Tomcat 能同时部署多个 War 包，每个应用有自己的 `log4j` 版本互不干扰；Spring Boot 的 `devtools` 修改代码后几百毫秒就热重载；OSGi 框架能在运行时安装和卸载模块——这些能力的底层全部依赖**类加载机制的定制化**。本文从双亲委派模型的原理出发，讲清楚三类主动打破它的场景，再深入 Metaspace 泄漏这个因自定义 ClassLoader 引发的高频生产问题。

---

## 一、类加载的五个阶段

### 1.1 加载流程全景

一个 `.class` 文件从磁盘到可执行，经历以下阶段：

```
+----------+   +-----------+   +----------+   +----------+   +----------+
|  Loading  |-> | Verifying |-> | Preparing|-> | Resolving|-> |Initializ.|
| (加载)    |   | (验证)    |   | (准备)   |   | (解析)   |   | (初始化) |
+----------+   +-----------+   +----------+   +----------+   +----------+
     |                               |                              |
  读取字节码                     static 变量                   执行 <clinit>
  创建 Class 对象                分配内存=默认值              static 块 & 赋值
```

各阶段要点：

| 阶段 | 做什么 | 关键细节 |
|------|--------|---------|
| **加载** | 读取字节流，创建 `Class<?>` 对象 | 可来自文件/网络/动态生成 |
| **验证** | 检查字节码合法性 | 防止恶意字节码破坏 JVM |
| **准备** | `static` 变量分配内存，赋**零值** | `static int x = 5;` 此时 x=0 |
| **解析** | 符号引用 -> 直接引用 | 可以延迟到首次使用时（懒解析） |
| **初始化** | 执行 `<clinit>`（static 块 + static 变量赋值） | 触发条件见下文 |

### 1.2 初始化的触发条件（主动使用）

以下 6 种情况触发类初始化（**有且仅有**）：

1. `new` 创建实例、访问 `static` 字段（非常量）、调用 `static` 方法
2. 反射调用（`Class.forName()`）
3. 初始化子类时，触发父类初始化
4. JVM 启动时，主类（含 `main()` 的类）
5. `MethodHandle` / `VarHandle` 解析对应类
6. JDK 11+ 接口有 `default` 方法时，实现类初始化触发接口初始化

```java
// 不触发初始化的典型例子
public class Parent {
    public static int VALUE = 42;
    static { System.out.println("Parent init"); }
}

// 通过子类引用父类静态字段 -> 只触发 Parent 初始化，不触发 Child 初始化
System.out.println(Child.VALUE); // 输出: "Parent init" 但不输出 "Child init"

// 数组创建不触发初始化
Parent[] arr = new Parent[10]; // 不触发 Parent 初始化
```

---

## 二、双亲委派模型

### 2.1 委派关系

JVM 内置三层 ClassLoader，加上应用层形成委派链：

```
Bootstrap ClassLoader (C++ 实现，加载 rt.jar / java.* 核心类)
          ^
          | 委派
Extension/Platform ClassLoader (加载 ext/*.jar / java.se 模块)
          ^
          | 委派
Application ClassLoader (加载 classpath 上的类)
          ^
          | 委派
Custom ClassLoader (用户自定义)
```

**工作流程**：每次加载类请求都先委托给父加载器，父加载器找不到才由自己加载。

### 2.2 为什么要双亲委派

```java
// 假设没有双亲委派：用户在 classpath 写了一个假的 java.lang.String
package java.lang;
public class String {
    // 恶意代码
}
// 这个 String 会被加载，覆盖 JDK 的 String -> JVM 崩溃或被攻击
```

双亲委派保证：
1. **安全**：核心类（`java.lang.*`）永远由 Bootstrap 加载，用户无法伪造
2. **唯一性**：同一个类只被同一个加载器加载一次，避免重复
3. **一致性**：`java.lang.String` 全局唯一，不存在类型不兼容问题

### 2.3 ClassLoader 核心源码（JDK 21）

```java
// JDK 21: java.lang.ClassLoader.loadClass()
// https://github.com/openjdk/jdk/blob/jdk-21+35/src/java.base/share/classes/java/lang/ClassLoader.java#L525
protected Class<?> loadClass(String name, boolean resolve)
        throws ClassNotFoundException {
    synchronized (getClassLoadingLock(name)) {
        // 1. 先检查是否已加载过
        Class<?> c = findLoadedClass(name);
        if (c == null) {
            try {
                // 2. 委托父加载器
                if (parent != null) {
                    c = parent.loadClass(name, false);
                } else {
                    // parent 为 null 表示父加载器是 Bootstrap
                    c = findBootstrapClassOrNull(name);
                }
            } catch (ClassNotFoundException e) {
                // 父加载器找不到，继续往下
            }
            if (c == null) {
                // 3. 父加载器找不到，自己加载
                c = findClass(name); // 子类覆写此方法实现自定义加载逻辑
            }
        }
        if (resolve) { resolveClass(c); }
        return c;
    }
}
```

---

## 三、打破双亲委派的三类场景

### 3.1 场景一：SPI 机制（JDBC、JNDI）

**问题**：`java.sql.Driver` 接口在 Bootstrap 加载器管辖的 `rt.jar` 中，但其实现类（如 `com.mysql.jdbc.Driver`）在应用 classpath 里，Bootstrap 加载器找不到。

**解决**：`Thread Context ClassLoader`（线程上下文加载器）

```java
// JDK 中 DriverManager 的实现（简化）
ServiceLoader<Driver> loadedDrivers =
    ServiceLoader.load(Driver.class);
// load() 内部使用 Thread.currentThread().getContextClassLoader()
// 上下文加载器默认是 AppClassLoader，可以加载 classpath 上的实现类
// 这打破了委派：父加载器（Bootstrap）委托给了子加载器（AppClassLoader）
```

### 3.2 场景二：Tomcat 的 WebApp ClassLoader

Tomcat 多应用隔离要求：不同 War 包中的相同类名（如各自包含的 `log4j`）互不干扰。

```
Bootstrap ClassLoader
      ^
      |
Common ClassLoader (加载 tomcat 公共 jar)
      ^
      |
+-----+-----+
|           |
WebApp1 CL  WebApp2 CL   <- 每个应用独立的 ClassLoader
(WEB-INF/   (WEB-INF/
 lib/*.jar)  lib/*.jar)
```

WebApp ClassLoader 的加载顺序：**先尝试自己加载（WEB-INF/lib）**，找不到才向上委派。这与标准双亲委派顺序相反，目的是让应用自带的 jar 优先于 Tomcat 的 jar。

```java
// Tomcat WebAppClassLoader 的简化逻辑
@Override
public Class<?> loadClass(String name) throws ClassNotFoundException {
    // 1. 检查已加载缓存
    Class<?> clazz = findLoadedClass(name);
    if (clazz != null) return clazz;

    // 2. Java 核心类交给父加载器（不能破坏 java.* 的安全保障）
    if (name.startsWith("java.")) {
        return parent.loadClass(name);
    }

    // 3. ★ 先在 WEB-INF/lib 中找（打破委派：不先委托父）
    clazz = findClass(name); // 在自己的 classpath 找
    if (clazz != null) return clazz;

    // 4. 找不到才向父委派
    return parent.loadClass(name);
}
```

### 3.3 场景三：热部署（Spring Boot DevTools / OSGi）

热部署需要**卸载旧类，加载新类**。JVM 中类的卸载条件极苛刻：该类的 ClassLoader 实例必须被 GC 回收。因此热部署的实现方式是：**丢弃旧 ClassLoader，创建新 ClassLoader 重新加载**。

```
旧 ClassLoader (持有旧版本 MyService.class)
      |
      |  应用模块修改后触发重载
      v
新 ClassLoader (持有新版本 MyService.class)
      |
      v
旧 ClassLoader 无任何强引用 -> GC 回收 -> 旧类被卸载
```

Spring Boot DevTools 实现：

```
RestartClassLoader (DevTools 自定义)
  ├── 监听 classpath 变化
  ├── 检测到变化 -> 丢弃当前 RestartClassLoader
  └── 创建新 RestartClassLoader 重新加载应用上下文
      (基础框架类由父加载器缓存，只重载业务类，约 300ms 完成)
```

---

## 四、Metaspace 泄漏：类加载引发的 OOM

### 4.1 泄漏根因

Metaspace 存储类的元数据（方法字节码、常量池等）。类无法被卸载时，Metaspace 持续增长，最终 OOM：

```
java.lang.OutOfMemoryError: Metaspace
```

触发条件：**ClassLoader 没有被 GC 回收，其加载的所有类无法从 Metaspace 卸载**。

常见场景：
1. 动态代理（CGLib、ASM）每次生成新代理类，用完不丢弃
2. 热部署场景旧 ClassLoader 有残留引用（如 ThreadLocal、静态变量持有）
3. 脚本引擎（Groovy、BeanShell）每次执行脚本都编译新类

### 4.2 复现代码

```java
// JDK 17  -XX:MaxMetaspaceSize=64m
// 每次调用生成一个新的 CGLib 代理类，不复用
public class MetaspaceLeakDemo {
    public void createProxy() {
        Enhancer enhancer = new Enhancer();
        enhancer.setSuperclass(OrderService.class);
        enhancer.setUseCache(false); // ❌ 禁用缓存，每次生成新 Class
        enhancer.setCallback((MethodInterceptor) (obj, method, args, proxy) ->
            proxy.invokeSuper(obj, args));
        enhancer.create(); // 每次创建一个新的代理类，堆积在 Metaspace
    }
}
```

**触发后输出**：

```
Caused by: java.lang.OutOfMemoryError: Metaspace
    at java.lang.ClassLoader.defineClass1(Native Method)
    at java.lang.ClassLoader.defineClass(ClassLoader.java:1012)
    at net.sf.cglib.core.ReflectUtils.defineClass(ReflectUtils.java:459)
    at net.sf.cglib.core.AbstractClassGenerator.generate(AbstractClassGenerator.java:336)
```

### 4.3 MAT 诊断 Metaspace 泄漏

Metaspace 不在 Java Heap 中，普通 Heap Dump 无法直接看到。使用 MAT 的 ClassLoader Explorer：

1. **Window → Heap Dump Details → Class Loaders**
2. 找到实例数异常多的 ClassLoader（如 `sun.reflect.DelegatingClassLoader` 有几千个）
3. 右键 → **Merge Shortest Paths to GC Roots** → 找到是什么强引用持有旧 ClassLoader

也可以用 jcmd 直接查看 Metaspace 占用：

```bash
jcmd <pid> VM.metaspace

# 输出示例：
# Total: 156.8 MB reserved, 98.4 MB committed
# Class space: 20.0 MB reserved, 8.2 MB committed
# Non-class space: 136.8 MB reserved, 90.2 MB committed
# Chunk freelists:
#   Non-class: 2.4 MB
#   Class: 0.2 MB
```

### 4.4 正确做法

```java
// ✅ 复用 Enhancer 实例，启用 CGLib 缓存
@Bean
public OrderService orderServiceProxy() {
    Enhancer enhancer = new Enhancer();
    enhancer.setSuperclass(OrderService.class);
    enhancer.setUseCache(true);  // ✅ 启用缓存，相同配置复用同一 Class
    enhancer.setCallback((MethodInterceptor) (obj, method, args, proxy) ->
        proxy.invokeSuper(obj, args));
    return (OrderService) enhancer.create();
    // Spring Bean 是单例，Enhancer 只生成一次代理类
}

// ✅ Groovy 脚本引擎复用 GroovyClassLoader
// ❌ 错误：每次执行都创建新 GroovyShell（内含新 GroovyClassLoader）
String result = new GroovyShell().evaluate(script);

// ✅ 正确：单例 GroovyShell + 脚本缓存
@Component
public class ScriptEngine {
    private final GroovyShell shell = new GroovyShell(); // 单例
    private final Map<String, Script> scriptCache = new ConcurrentHashMap<>();

    public Object evaluate(String scriptCode) {
        Script script = scriptCache.computeIfAbsent(scriptCode,
            code -> shell.parse(code)); // 相同脚本复用编译结果
        return script.run();
    }
}
```

---

## 五、自定义 ClassLoader 实战

### 5.1 最简自定义 ClassLoader

实现插件热加载：每次插件更新时，用新的 ClassLoader 重新加载：

```java
// JDK 17
public class PluginClassLoader extends ClassLoader {

    private final Path pluginJar;

    public PluginClassLoader(Path pluginJar, ClassLoader parent) {
        super(parent); // 指定父加载器（双亲委派的父节点）
        this.pluginJar = pluginJar;
    }

    @Override
    protected Class<?> findClass(String name) throws ClassNotFoundException {
        // 将类名转换为路径（com.example.Foo -> com/example/Foo.class）
        String path = name.replace('.', '/') + ".class";
        try (JarFile jar = new JarFile(pluginJar.toFile())) {
            JarEntry entry = jar.getJarEntry(path);
            if (entry == null) throw new ClassNotFoundException(name);

            byte[] bytes = jar.getInputStream(entry).readAllBytes();
            return defineClass(name, bytes, 0, bytes.length); // 核心：定义类
        } catch (IOException e) {
            throw new ClassNotFoundException(name, e);
        }
    }
}

// 使用：每次热重载创建新的 PluginClassLoader，旧的丢弃
public void reloadPlugin(Path newJar) {
    // 旧的 classLoader 丢弃，让 GC 回收（同时回收其加载的类）
    this.pluginClassLoader = new PluginClassLoader(newJar, getClass().getClassLoader());
    Class<?> pluginClass = pluginClassLoader.loadClass("com.example.plugin.MyPlugin");
    Plugin plugin = (Plugin) pluginClass.getDeclaredConstructor().newInstance();
    plugin.init();
}
```

### 5.2 防止 ClassLoader 泄漏的关键检查

热重载时，以下几类引用会意外持有旧 ClassLoader，阻止 GC：

| 引用来源 | 检查点 |
|---------|--------|
| `ThreadLocal` | 旧类实例放入 ThreadLocal，线程还活着 |
| 静态变量 | 新代码的静态变量仍引用旧类的对象 |
| JDBC Driver | `DriverManager` 持有 Driver 实例（旧类加载器加载的） |
| Shutdown Hook | `Runtime.addShutdownHook()` 注册了旧类加载器加载的线程 |
| Logger | 日志框架的静态 Logger 实例 |

---

## 六、对比：三种打破双亲委派的方式

| 方式 | 典型框架 | 目的 | 实现手段 |
|------|---------|------|---------|
| 线程上下文加载器 | JDBC SPI、JNDI | 父加载器访问子加载器的类 | `Thread.contextClassLoader` |
| 子优先加载 | Tomcat WebApp | 应用隔离，避免依赖冲突 | 覆写 `loadClass`，先 `findClass` |
| 平行类加载器 | OSGi、JPMS 模块系统 | 模块间互相隔离 + 按需可见 | 每个 Bundle/Module 独立加载器 |

---

## 七、踩坑总结

**❌ 错误做法 1**：反射创建对象时用 `Class.forName()` 的无参版本，在 OSGi/多类加载器环境中加载错误

```java
// ❌ 无参 forName 使用调用者的加载器，在 OSGi 中可能找不到目标类
Class<?> clazz = Class.forName("com.example.Plugin");

// ✅ 显式指定加载器
Class<?> clazz = Class.forName("com.example.Plugin", true,
    Thread.currentThread().getContextClassLoader());
```

---

**❌ 错误做法 2**：热重载后同类名不同加载器的实例互转（ClassCastException）

```java
// PluginClassLoader-1 加载的 Foo 和 PluginClassLoader-2 加载的 Foo
// 对 JVM 来说是两个不同的类，强转会抛 ClassCastException
Foo oldFoo = ...; // 由 ClassLoader-1 加载
Foo newFoo = (Foo) classLoader2.loadClass("Foo").newInstance(); // ClassLoader-2 加载
// ❌ oldFoo 和 newFoo 类型不兼容
```

**✅ 正确做法**：热重载的接口/父类必须由共同的父加载器加载，只重载实现类。

---

**❌ 错误做法 3**：Metaspace OOM 后只加 `-XX:MaxMetaspaceSize` 而不查根因

加大 Metaspace 只是推迟问题，根因还是类加载器泄漏。必须用 MAT 找到哪个 ClassLoader 没有被 GC。

---

## 八、文章小结

1. **类加载五阶段**：Loading → Verifying → Preparing → Resolving → Initializing；准备阶段只赋零值，初始化阶段才执行 static 块。
2. **双亲委派**：先委托父加载器，找不到才自己加载；保证核心类安全唯一，防止用户代码伪造 `java.lang.*`。
3. **三大破坏场景**：SPI 用线程上下文加载器反向委托；Tomcat 用子优先加载实现应用隔离；热部署通过丢弃旧 ClassLoader 实现类卸载。
4. **Metaspace 泄漏**根因是旧 ClassLoader 有残留强引用无法被 GC，CGLib 动态代理禁用缓存是最常见触发点。
5. **自定义 ClassLoader** 的核心是覆写 `findClass` 并调用 `defineClass`；热重载场景要格外注意 ThreadLocal / 静态变量 / Shutdown Hook 对旧加载器的意外持有。

---

## 九、参考资料

- [JVM 规范第 5 章：加载、链接与初始化](https://docs.oracle.com/javase/specs/jvms/se21/html/jvms-5.html)（JVM SE 21）
- 《深入理解 Java 虚拟机》第 3 版，第 7 章"虚拟机类加载机制"
- [Tomcat ClassLoader 文档](https://tomcat.apache.org/tomcat-10.1-doc/class-loader-howto.html)（Tomcat 10.1）
- [OpenJDK ClassLoader 源码](https://github.com/openjdk/jdk/blob/jdk-21+35/src/java.base/share/classes/java/lang/ClassLoader.java)（JDK 21）
- [MAT ClassLoader Explorer](https://eclipse.dev/mat/docs/reference/inspections/class_loader_explorer.html)（MAT 1.14+）
