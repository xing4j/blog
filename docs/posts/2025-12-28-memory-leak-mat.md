# 内存泄漏排查：MAT 实战

<div class="post-meta">📅 2025-12-28 &nbsp;·&nbsp; 🏷️ <span class="tag">性能</span> <span class="tag">JVM</span></div>

Java 内存泄漏通常表现为 OOM 或频繁 Full GC，MAT（Eclipse Memory Analyzer）是分析堆 dump 的最强工具。

---

## 一、获取堆 dump

```bash
# 方式1：OOM 时自动生成（推荐，提前配置）
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/opt/dumps/heap.hprof

# 方式2：手动触发（不停应用，适合排查内存缓慢增长）
jmap -dump:format=b,live,file=/tmp/heap.hprof <PID>
# live：只 dump 存活对象（先触发 Full GC）

# 方式3：arthas
heapdump /tmp/heap.hprof

# 方式4：jcmd（JDK 9+）
jcmd <PID> GC.heap_dump /tmp/heap.hprof
```

---

## 二、MAT 安装与基础分析

```
下载：https://eclipse.dev/mat/downloads.php

打开 .hprof 文件后，关键功能：

1. Overview
   - Heap Size：总堆大小
   - Number of Objects：对象数量
   - 点击 "Leak Suspects"（泄漏嫌疑报告）-> 自动分析最可能泄漏的对象

2. Dominator Tree（支配树）
   - 按对象占用内存从大到小排列
   - "Retained Heap" 列 = 该对象被GC后能释放的内存
   - 重点关注 Retained Heap 最大的 TOP 10 对象

3. Histogram（类直方图）
   - 按类型统计对象数量和内存
   - 过滤自定义类（com.example.*）
   - 数量异常多的对象 -> 泄漏候选

4. OQL（类似 SQL 的查询语言）
   SELECT * FROM java.util.HashMap$Entry WHERE key.toString().startsWith("session:")
```

---

## 三、常见泄漏模式

### ThreadLocal 泄漏

```java
// 漏洞：使用线程池时，ThreadLocal 未清理
private static ThreadLocal<UserContext> userContext = new ThreadLocal<>();

// 线程池中使用后，线程被复用，ThreadLocal 数据残留
userContext.set(new UserContext(userId));
doSomething();
// 忘记 remove()！线程归还线程池后，UserContext 无法被 GC

// 修复：finally 块中清理
try {
    userContext.set(new UserContext(userId));
    doSomething();
} finally {
    userContext.remove();  // 必须清理
}
```

### 静态集合无限增长

```java
// 漏洞：static Map 持续 put，无清理策略
public class CacheManager {
    private static final Map<String, Object> CACHE = new HashMap<>();  // ❌
    
    public static void put(String key, Object value) {
        CACHE.put(key, value);  // 只进不出，内存泄漏
    }
}

// 修复：使用 Guava Cache 或 Caffeine，设置最大容量和过期时间
private static final Cache<String, Object> CACHE = Caffeine.newBuilder()
    .maximumSize(10000)
    .expireAfterWrite(Duration.ofMinutes(30))
    .build();
```

### 监听器/回调未取消注册

```java
// 漏洞：注册监听器但不取消
eventBus.register(this);  // ❌ 没有对应的 unregister

// 修复：实现 Closeable 并在 close() 中取消注册
@PreDestroy
public void destroy() {
    eventBus.unregister(this);
}
```

### 数据库连接未关闭

```java
// 漏洞（古老写法）：Connection 未关闭
Connection conn = dataSource.getConnection();
PreparedStatement ps = conn.prepareStatement("SELECT...");
ResultSet rs = ps.executeQuery();
// 忘记关闭！连接泄漏，最终耗尽连接池

// 修复：使用 try-with-resources
try (Connection conn = dataSource.getConnection();
     PreparedStatement ps = conn.prepareStatement("SELECT...");
     ResultSet rs = ps.executeQuery()) {
    // 自动关闭
}
```

---

## 四、MAT 分析实战

```
案例：发现 HashMap$Entry 对象数量异常（Histogram 显示100万+）

步骤：
1. Histogram -> 过滤 "Entry" -> 发现 HashMap$Entry 占用 2GB
2. 右键 -> "List Objects" -> with incoming references（谁引用了它）
3. 发现被 com.example.SessionCache 持有
4. Dominator Tree -> 找到 SessionCache -> 展开 -> 看里面是什么

定位：SessionCache 使用 HashMap 存储 Session，key 是 sessionId
问题：Session 过期后没有从 Map 中移除，导致无限增长

修复：改用 Caffeine Cache 设置 expireAfterAccess(30, MINUTES)
```

---

## 五、内存泄漏预防

```java
// 1. 缓存使用弱引用
WeakHashMap<Key, Value> cache = new WeakHashMap<>();
// Key 没有强引用时，GC 会自动清理

// 2. 设置最大连接池大小
spring:
  datasource:
    hikari:
      maximum-pool-size: 50
      connection-timeout: 30000
      idle-timeout: 600000
      max-lifetime: 1800000

// 3. 定期监控堆内存
// 告警：老年代使用率 > 85% 持续5分钟
```

---

## 总结

| 场景 | 排查方法 |
|------|---------|
| OOM 崩溃 | 分析自动生成的 heap.hprof |
| 内存缓慢增长 | 定时 jmap dump，对比分析 |
| MAT 快速定位 | Leak Suspects + Dominator Tree |
| 常见原因 | ThreadLocal未清理、静态集合、监听器未注销 |
| 预防 | Caffeine Cache + 连接池配置 + 弱引用 |
