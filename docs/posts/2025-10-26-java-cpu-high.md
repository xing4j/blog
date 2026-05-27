# Java 服务 CPU 飙高排查实战：从现象到根因

<div class="post-meta">📅 2025-10-26 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">性能</span></div>

凌晨两点，告警响起：某服务 CPU 使用率飙到 95% 并持续不降，接口 P99 超过 10 秒。留给你的时间不多——你需要在 5 分钟内定位是 GC 风暴、死循环还是锁竞争，然后决策是重启还是在线修复。本文还原这套排查流程，并分析三类最常见的 CPU 高根因。

---

## 一、背景：CPU 飙高的三类根因

Java 服务 CPU 飙高，根因 90% 落在这三类：

| 根因 | 特征 | 排查手段 |
|------|------|---------|
| **GC 风暴** | CPU 高且伴随频繁 Full GC，内存告警 | GC 日志 + jstat |
| **死循环/热点代码** | CPU 高，某线程长期占用 | jstack + CPU 采样 |
| **锁竞争/死锁** | CPU 不算极高但响应慢，线程大量 BLOCKED | jstack 分析 |

---

## 二、5 步排查 SOP

### Step 1：确认是哪个进程/服务占用 CPU

```bash
# 找出 CPU 最高的进程
top -c
# 或按 CPU 排序查看
ps aux --sort=-%cpu | head -10

# 记录 Java 进程的 PID，假设为 12345
```
### Step 2：找出进程内占用 CPU 最高的线程

```bash
# 找出进程 12345 中 CPU 最高的线程（TID）
top -H -p 12345
# 按 P 键排序（按 CPU），找出 TID（假设 TID=12350）

# 将十进制 TID 转换为十六进制（jstack 中用 16 进制表示 nid）
printf "%x\n" 12350
# 输出：0x303e
```
### Step 3：获取线程 dump，找到对应线程

```bash
# 导出当前所有线程的调用栈
jstack 12345 > /tmp/thread_dump.txt

# 在 dump 中搜索对应的 nid（16进制）
grep -A 30 "nid=0x303e" /tmp/thread_dump.txt
```
### Step 4：分析线程调用栈，定位根因

**GC 线程占用高**（GC 风暴）：

```bash
# Step 2 中发现多个 "GC task thread" 占用 CPU
# 用 jstat 确认 GC 状态
jstat -gcutil 12345 1000 10
# 输出示例：
#  S0     S1     E      O      M     CCS    YGC   YGCT    FGC   FGCT     GCT
#  0.00  99.99  99.00  99.00  94.1  91.1    180   15.6     8    40.2   55.8
#                             ^Eden满  ^Old满       ^FGC 8次，占用 40s

# 结论：Old Gen 满了，触发频繁 Full GC，CPU 都在 GC
# 应急：增大堆（-Xmx），同时排查内存泄漏
```
**业务线程死循环**：

```bash
# jstack 输出示例：
"http-nio-8080-exec-1" #25 daemon prio=5 os_prio=0 tid=0x... nid=0x303e runnable
  java.lang.Thread.State: RUNNABLE
    at com.example.OrderService.calculateDiscount(OrderService.java:156)
    at com.example.OrderService.processOrder(OrderService.java:89)
    # ^ 持续 RUNNABLE，多次 dump 都在同一位置
    # 很可能是 calculateDiscount 方法中存在死循环或极慢的循环
```
**锁竞争/死锁**：

```bash
# jstack 输出示例（大量线程 BLOCKED）：
"http-nio-8080-exec-3" State: BLOCKED (on object monitor)
  waiting to lock <0x00000007b9c03b40> (a java.util.HashMap)
  held by "http-nio-8080-exec-1"

"http-nio-8080-exec-1" State: BLOCKED (on object monitor)
  waiting to lock <0x00000007b9c04a20> (a com.example.UserCache)
  held by "http-nio-8080-exec-3"

# ^ 典型死锁：线程1持有 HashMap 锁，等 UserCache 锁
#             线程3持有 UserCache 锁，等 HashMap 锁
# jstack 末尾会有 "Found 1 deadlock" 自动提示
```
### Step 5：在线分析工具（Arthas）

```bash
# 安装并连接到进程
curl -O https://arthas.aliyun.com/arthas-boot.jar
java -jar arthas-boot.jar 12345

# 找出 CPU 占用最高的线程及其调用栈（不需要手动转换 TID）
thread -n 5

# 输出：
# Id   Name                 Group            Priority  State    %cpu
#  25  http-nio-8080-exec-1  main             5         RUNNABLE 89%
#   ^ 直接显示 CPU 占用，并输出完整调用栈

# 查看某个方法被调用的实时统计（调用次数、耗时分布）
trace com.example.OrderService calculateDiscount

# 热点方法火焰图（采样 20 秒）
profiler start
# 等待 20 秒
profiler stop --format html --file /tmp/flame.html
```
---

## 三、三类根因修复方案

### 3.1 GC 风暴

```bash
# 应急：快速扩容/重启，临时缓解
# 根治：排查内存泄漏（见 Heap Dump 分析）

# 调优参数（如果是配置问题）：
-Xms8g -Xmx8g                    # 增大堆，减少 GC 频率
-XX:MaxGCPauseMillis=200          # G1 暂停目标
-XX:InitiatingHeapOccupancyPercent=45  # 更早触发并发 GC
```
### 3.2 死循环修复

```java
// 常见死循环场景：HashMap 在 JDK 7 并发扩容时产生环形链表
// JDK 8 修复了此问题，但仍需注意业务逻辑中的无限循环

// ❌ 条件永远为真的循环
while (retryCount < maxRetry) {
    if (callRemote()) break;
    // 忘记了 retryCount++，变成死循环
}

// ❌ 递归没有终止条件
int calc(int n) {
    return calc(n - 1) + 1;  // 忘了 base case，StackOverflowError
}
```
### 3.3 死锁预防

```java
// 预防死锁的核心原则：固定加锁顺序
// ❌ 两个方法加锁顺序不一致，可能死锁
void methodA() {
    synchronized (lockX) { synchronized (lockY) { ... } }
}
void methodB() {
    synchronized (lockY) { synchronized (lockX) { ... } }  // 顺序反了
}

// ✅ 固定加锁顺序（按对象 ID 排序）
void transfer(Account a, Account b) {
    Account first = a.id < b.id ? a : b;
    Account second = a.id < b.id ? b : a;
    synchronized (first) { synchronized (second) { ... } }  // 始终小 ID 先锁
}
```
---

## 四、常见坑点与最佳实践

### 坑 1：多次 jstack 不连续，容易误判

CPU 飙高时应**连续取 3~5 次** jstack（间隔 3~5 秒），处于 RUNNABLE 且调用栈不变化的线程才是热点，只取一次可能抓到正常的瞬时状态。

### 坑 2：Arthas 的 trace 对高频方法有性能开销

```bash
# ❌ 对极高频方法 trace 会放大性能问题
trace com.example.OrderService processOrder

# ✅ 加条件过滤，减少影响
trace com.example.OrderService processOrder '#cost > 100'  # 只记录耗时 > 100ms
```
### 坑 3：jstack 在 GC 期间可能输出不完整

GC 时 JVM 可能处于 SafePoint，jstack 需要等 GC 完成。如果 GC 频繁，可能需要多试几次。

---

## 五、总结与延伸

**排查 SOP 五步**：
1. top -c 找到 Java 进程 PID
2. top -H -p PID 找到高 CPU 线程 TID
3. 将 TID 转 16 进制，在 jstack 输出中定位线程
4. 分析调用栈：GC 线程 → GC 风暴；RUNNABLE 固定调用栈 → 死循环；大量 BLOCKED → 锁竞争
5. 使用 Arthas thread -n 和 trace 在线定位，无需重启

**延伸阅读方向**：
- Arthas 完整命令手册：watch、ognl、jad（反编译）、retransform（热更新）
- Java Flight Recorder（JFR）：持续性能采集，CPU、内存、IO 全维度
- 火焰图（Flame Graph）解读：快速定位热点函数
- JVM 调优实战：本站 [JVM 调优实战：参数配置与 Heap Dump 分析](posts/2024-07-09-jvm-tuning-heapdump.md)
