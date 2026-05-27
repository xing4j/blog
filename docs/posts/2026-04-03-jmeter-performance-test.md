# JMeter 性能测试实战

<div class="post-meta">📅 2026-04-03 &nbsp;·&nbsp; 🏷️ <span class="tag">性能测试</span> <span class="tag">JMeter</span></div>

JMeter 是最流行的开源性能测试工具，支持 HTTP/HTTPS、数据库、消息队列等多种协议。

---

## 一、核心概念

```
测试计划（Test Plan）
  +-- 线程组（Thread Group）--- 模拟并发用户
        +-- 设置：
        |     虚拟用户数（Threads）= 100
        |     Ramp-Up（爬升时间）= 30s  -> 每0.3s启动1个用户
        |     循环次数（Loop Count）= 10
        |
        +-- HTTP 请求采样器（Sampler）
        +-- 断言（Assertion）---- 验证响应是否正确
        +-- 监听器（Listener）--- 收集结果（聚合报告等）
        +-- 配置元件（Config）--- CSV 数据文件、HTTP 头管理器
```

---

## 二、创建基础 HTTP 测试

```
1. 右键 Test Plan -> Add -> Threads -> Thread Group
   - Number of Threads: 50（并发用户）
   - Ramp-Up: 10（10秒内启动所有用户）
   - Loop Count: 100（每用户循环100次）

2. 右键 Thread Group -> Add -> Sampler -> HTTP Request
   - Server Name: api.example.com
   - Port: 443
   - Protocol: https
   - Method: POST
   - Path: /api/orders
   - Body Data: {"productId": 1, "quantity": 1}

3. 添加 HTTP Header Manager（右键 -> Add -> Config -> HTTP Header Manager）
   - Content-Type: application/json
   - Authorization: Bearer ${token}

4. 添加响应断言（右键 -> Add -> Assertions -> Response Assertion）
   - Response Code: 200
   - Response Body contains: "orderId"

5. 添加聚合报告（右键 -> Add -> Listener -> Summary Report）
```

---

## 三、参数化（CSV 数据驱动）

```
# test-users.csv
username,password
user001,pass001
user002,pass002
...
user100,pass100

配置 CSV Data Set Config：
- Filename: /path/to/test-users.csv
- Variable Names: username,password
- Delimiter: ,
- Sharing Mode: All threads（线程共享，每个用户取不同数据）

HTTP 请求中使用变量：
Body: {"username": "${username}", "password": "${password}"}
```

---

## 四、关联（提取动态值）

```
场景：登录接口返回 token，后续请求需要使用该 token

1. 在登录请求后添加 JSON Extractor：
   右键 -> Add -> Post Processors -> JSON Extractor
   - Variable Names: token
   - JSON Path: $.data.token
   - Match No: 1

2. 后续请求的 Header 中使用：
   Authorization: Bearer ${token}
```

---

## 五、命令行运行（CI/CD 集成）

```bash
# 无 GUI 模式运行（推荐，节省资源）
jmeter -n \
  -t /path/to/test.jmx \
  -l /path/to/results.jtl \
  -e \
  -o /path/to/report \
  -Jthreads=100 \
  -Jrampup=30 \
  -Jduration=300  # 自定义属性

# 生成 HTML 报告
jmeter -g results.jtl -o /path/to/html-report

# Docker 运行
docker run --rm \
  -v $(pwd):/tests \
  justb4/jmeter \
  -n -t /tests/test.jmx -l /tests/results.jtl
```

---

## 六、关键性能指标解读

```
聚合报告各列含义：

Label    | # Samples | Average | Min | Max | P90 | P95 | P99 | Error% | Throughput
------------------------------------------------------------------------------------
/api/order| 50000    | 245ms  | 12  | 3200| 680 | 890 | 1560| 0.12% | 234.5/sec

- Average：平均响应时间（受极值影响大，参考价值有限）
- P90/P95/P99：90%/95%/99% 的请求在此时间内完成（更有意义）
- Error%：错误率（生产级 SLA 通常要求 < 0.1%）
- Throughput：每秒请求数（TPS/QPS）

性能基准参考：
- P99 < 500ms：优秀
- P99 < 1000ms：良好
- P99 < 3000ms：可接受
- Error% < 0.1%：达标
```

---

## 七、常见性能瓶颈定位

```
测试中 TPS 上不去？排查顺序：

1. JMeter 本身成为瓶颈
   -> 分布式压测（多台 JMeter Slave）
   -> JMeter heap 调大：HEAP="-Xms4g -Xmx4g"

2. 应用服务器 CPU/内存
   -> 配合 arthas profiler 分析热点

3. 数据库慢查询
   -> 开启慢查询日志，分析 EXPLAIN

4. 连接池耗尽
   -> 监控 HikariCP 指标：hikaricp.connections.pending > 0

5. JVM GC 压力
   -> jstat -gcutil PID 查看 GC 频率
```

---

## 总结

| 场景 | 建议 |
|------|------|
| 基准测试 | 单用户，确认功能正常 |
| 负载测试 | 预期并发用户数，验证 SLA |
| 压力测试 | 逐步加压至系统崩溃，找瓶颈 |
| 稳定性测试 | 正常负载持续 72 小时 |
| 参数化 | CSV 驱动，避免缓存干扰 |
| 结果指标 | P95/P99 + 错误率，而非平均值 |
