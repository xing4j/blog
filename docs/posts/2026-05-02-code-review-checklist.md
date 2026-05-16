# Code Review 清单：Java 代码审查要点

<div class="post-meta">📅 2026-05-02 &nbsp;·&nbsp; 🏷️ <span class="tag">代码质量</span> <span class="tag">Code Review</span></div>

Code Review 是提升代码质量的核心环节。本文整理 Java 后端开发的 Code Review 要点清单。

---

## 一、代码风格与可读性

```java
// ❌ 命名模糊，逻辑无注释
public List<Map<String, Object>> getData(int t, String s) {
    List<Map<String, Object>> result = new ArrayList<>();
    for (int i = 0; i < t; i++) {
        // ...
    }
    return result;
}

// ✅ 命名清晰，方法职责单一
public List<OrderVO> findOrdersByStatus(int pageSize, String status) {
    return orderMapper.selectByStatus(status, pageSize);
}
```

**检查点**：
- 方法名是否准确表达行为（动词+名词）
- 变量名是否有意义（不用 a、b、temp）
- 方法是否过长（建议 < 40 行）
- 是否有重复代码（DRY 原则）

---

## 二、异常处理

```java
// ❌ 吞掉异常，静默失败
try {
    orderService.processOrder(req);
} catch (Exception e) {
    // 什么都不做
}

// ❌ 捕获 Exception 太宽泛
try {
    int price = Integer.parseInt(priceStr);
} catch (Exception e) {  // 只需 NumberFormatException
    log.error("parse error", e);
}

// ✅ 精确捕获，有效处理
try {
    int price = Integer.parseInt(priceStr);
} catch (NumberFormatException e) {
    throw new BusinessException(ErrorCode.INVALID_PARAM, "价格格式错误: " + priceStr);
}
```

**检查点**：
- 是否有空 catch 块？
- 是否仅打印日志但没有实质处理（`log.error` + 继续执行）？
- 自定义异常是否携带足够上下文信息？
- 是否在正确层次处理异常？

---

## 三、并发安全

```java
// ❌ 非线程安全的共享状态
@Service
public class OrderService {
    private List<String> processingOrders = new ArrayList<>();  // 非线程安全！
    
    public void process(String orderId) {
        processingOrders.add(orderId);  // 并发时可能数据丢失/异常
    }
}

// ✅ 线程安全的数据结构
private Set<String> processingOrders = ConcurrentHashMap.newKeySet();

// ❌ 复合操作非原子
if (!map.containsKey(key)) {
    map.put(key, value);  // 两步操作，中间可能被打断
}

// ✅ 原子操作
map.putIfAbsent(key, value);
```

**检查点**：
- Service、Controller 是单例，是否有非 final 的成员变量？
- 共享集合是否使用并发类？
- 是否有 check-then-act 复合操作？
- 是否正确使用了 synchronized/Lock？

---

## 四、数据库与事务

```java
// ❌ 事务中进行远程调用（锁时间过长）
@Transactional
public void createOrder(OrderRequest req) {
    Order order = buildOrder(req);
    orderMapper.insert(order);
    smsService.sendConfirmSMS(req.getPhone());  // 外部调用可能超时！
    stockService.deductStock(req.getProductId()); // 另一个库
}

// ✅ 分离事务和外部调用
@Transactional
public Order createOrder(OrderRequest req) {
    Order order = buildOrder(req);
    orderMapper.insert(order);
    // 只操作当前库
    return order;
}

// 事务外发送短信（通过领域事件或 MQ）
public void createOrderWithNotify(OrderRequest req) {
    Order order = createOrder(req);
    applicationEventPublisher.publishEvent(new OrderCreatedEvent(order));
}
```

**检查点**：
- 事务方法内是否有耗时的外部调用（HTTP/RPC）？
- 是否跨多个数据源（分布式事务问题）？
- 大查询是否分页？
- MyBatis 是否有 `${}`（SQL 注入风险）？

---

## 五、性能隐患

```java
// ❌ N+1 查询
List<Order> orders = orderMapper.selectAll();
for (Order order : orders) {
    User user = userMapper.selectById(order.getUserId());  // N 次查询！
    order.setUserName(user.getName());
}

// ✅ 批量查询
List<Order> orders = orderMapper.selectAll();
List<Long> userIds = orders.stream().map(Order::getUserId).distinct().toList();
Map<Long, User> userMap = userMapper.selectByIds(userIds).stream()
    .collect(Collectors.toMap(User::getId, u -> u));
orders.forEach(o -> o.setUserName(userMap.get(o.getUserId()).getName()));

// ❌ 循环中重复创建对象
for (int i = 0; i < 100000; i++) {
    DateFormat df = new SimpleDateFormat("yyyy-MM-dd");  // 每次 new！
    String date = df.format(new Date());
}

// ✅ 复用（使用 DateTimeFormatter，线程安全）
private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd");
```

**检查点**：
- 是否有 N+1 查询？
- 循环内是否有数据库操作？（应批量处理）
- 是否对大集合进行了不必要的全量加载？
- 正则表达式是否每次都 `Pattern.compile()`？

---

## 六、安全检查

```java
// ❌ 日志打印敏感信息
log.info("用户登录：username={}, password={}", username, password);  // 密码泄露！

// ✅ 脱敏
log.info("用户登录：username={}", username);

// ❌ 接口无权限控制
@GetMapping("/admin/users")
public List<User> getAllUsers() { ... }  // 任何人都能访问！

// ✅ 明确权限注解
@PreAuthorize("hasRole('ADMIN')")
@GetMapping("/admin/users")
public List<User> getAllUsers() { ... }
```

---

## 七、代码审查沟通原则

```
✅ 好的 Review 评论：
"这里如果 order 为 null 会 NPE，建议在第 15 行添加 null 检查"

❌ 差的 Review 评论：
"这代码写的什么"
"为什么不用 XXX？"（没有说明理由）

原则：
- 对事不对人
- 提出问题的同时给出建议方案
- 区分 must fix（必须改）和 suggestion（建议）
- 好的代码也要说出来（正向反馈）
```

---

## 总结 Checklist

| 类别 | 检查要点 |
|------|---------|
| 可读性 | 命名清晰、方法短小、无重复代码 |
| 异常处理 | 无空 catch、异常类型精确、日志包含上下文 |
| 并发安全 | Service 无可变共享状态、并发集合 |
| 事务 | 事务内无远程调用、不跨库 |
| 性能 | 无 N+1、循环内无 DB 操作 |
| 安全 | 日志脱敏、接口有权限控制 |
