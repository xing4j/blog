# Spring 中的设计模式实战

<div class="post-meta">📅 2025-10-11 &nbsp;·&nbsp; 🏷️ <span class="tag">设计模式</span> <span class="tag">Spring</span></div>

Spring 框架本身大量运用设计模式，理解这些模式有助于写出更优雅的业务代码。

---

## 一、策略模式（Strategy）

```java
// 场景：支付方式多样，消除大量 if-else
public interface PaymentStrategy {
    void pay(BigDecimal amount);
    String getType();
}

@Component
public class AlipayStrategy implements PaymentStrategy {
    @Override
    public void pay(BigDecimal amount) { /* 调用支付宝接口 */ }
    @Override
    public String getType() { return "alipay"; }
}

@Component
public class WechatPayStrategy implements PaymentStrategy {
    @Override
    public void pay(BigDecimal amount) { /* 调用微信支付接口 */ }
    @Override
    public String getType() { return "wechat"; }
}

// 策略工厂（利用 Spring 自动注入所有实现类）
@Component
public class PaymentStrategyFactory {
    private final Map<String, PaymentStrategy> strategies;

    public PaymentStrategyFactory(List<PaymentStrategy> list) {
        strategies = list.stream()
            .collect(Collectors.toMap(PaymentStrategy::getType, s -> s));
    }

    public PaymentStrategy getStrategy(String type) {
        PaymentStrategy strategy = strategies.get(type);
        if (strategy == null) throw new IllegalArgumentException("不支持的支付方式：" + type);
        return strategy;
    }
}

// 使用
paymentStrategyFactory.getStrategy(order.getPayType()).pay(order.getAmount());
```

---

## 二、模板方法模式（Template Method）

```java
// 场景：数据导出流程固定，但每种格式处理不同
@Component
public abstract class DataExporter<T> {

    // 模板方法：定义固定流程
    public final void export(ExportRequest req, HttpServletResponse response) {
        List<T> data = fetchData(req);        // 1. 查数据
        validate(data);                        // 2. 校验
        List<String[]> rows = transform(data); // 3. 转换
        writeToResponse(rows, response);       // 4. 写出
    }

    protected abstract List<T> fetchData(ExportRequest req);
    protected abstract List<String[]> transform(List<T> data);

    // 默认实现，子类可覆盖
    protected void validate(List<T> data) {
        if (data.size() > 100000) {
            throw new BusinessException("导出数据不能超过10万条");
        }
    }

    protected abstract void writeToResponse(List<String[]> rows, HttpServletResponse response);
}

@Component
public class UserExcelExporter extends DataExporter<User> {
    @Override
    protected List<User> fetchData(ExportRequest req) { return userService.list(); }
    @Override
    protected List<String[]> transform(List<User> data) {
        return data.stream().map(u -> new String[]{u.getName(), u.getEmail()}).toList();
    }
    // ...
}
```

---

## 三、观察者模式（Spring Events）

```java
// 场景：订单创建后触发积分、通知等多个动作（解耦）

// 事件定义
public class OrderCreatedEvent extends ApplicationEvent {
    private final Order order;
    public OrderCreatedEvent(Object source, Order order) {
        super(source);
        this.order = order;
    }
    public Order getOrder() { return order; }
}

// 发布事件
@Service
public class OrderService {
    @Autowired
    private ApplicationEventPublisher publisher;

    @Transactional
    public Order createOrder(OrderRequest req) {
        Order order = saveOrder(req);
        publisher.publishEvent(new OrderCreatedEvent(this, order));
        return order;
    }
}

// 监听器1：发放积分
@Component
public class PointsListener {
    @EventListener
    @Async  // 异步处理
    public void onOrderCreated(OrderCreatedEvent event) {
        pointsService.addPoints(event.getOrder().getUserId(), ...);
    }
}

// 监听器2：发送通知
@Component
public class NotificationListener {
    @EventListener
    @Async
    public void onOrderCreated(OrderCreatedEvent event) {
        smsService.send(event.getOrder().getPhone(), "您的订单已创建");
    }
}
```

---

## 四、装饰器模式（Decorator）

```java
// 场景：给 UserService 动态添加缓存、日志等功能

public interface UserService {
    User getById(Long id);
}

@Service
@Primary
public class CachedUserService implements UserService {
    private final UserServiceImpl delegate;
    private final Cache cache;

    @Override
    public User getById(Long id) {
        return cache.get(id, () -> delegate.getById(id));
    }
}
```

---

## 五、责任链模式（Filter/Interceptor）

```java
// 场景：请求处理链（权限检查 → 参数校验 → 日志 → 限流）
@Component
public class AuthInterceptor implements HandlerInterceptor {
    @Override
    public boolean preHandle(HttpServletRequest req, ...) {
        // 权限检查，不通过则 return false 终止链
        return checkAuth(req);
    }
}

// 业务场景：工单审批链
public abstract class ApprovalHandler {
    protected ApprovalHandler next;

    public ApprovalHandler setNext(ApprovalHandler next) {
        this.next = next;
        return next;
    }

    public abstract void handle(ApprovalRequest req);
}

// 组合：组长 → 经理 → 总监
groupLeader.setNext(manager).setNext(director);
groupLeader.handle(request);
```

---

## 六、建造者模式（Builder）

```java
// Lombok @Builder 最简实践
@Builder
@Data
public class UserQuery {
    private String username;
    private String email;
    private Integer status;
    @Builder.Default
    private int pageSize = 20;
    @Builder.Default
    private int pageNum = 1;
}

// 使用
UserQuery query = UserQuery.builder()
    .username("alice")
    .status(1)
    .pageSize(50)
    .build();
```

---

## 总结

| 设计模式 | Spring 体现 | 业务场景 |
|---------|-----------|---------|
| 策略模式 | 注入所有实现 + Map | 支付方式、导出格式 |
| 模板方法 | AbstractXxx | 导入导出、数据同步 |
| 观察者模式 | ApplicationEvent | 订单创建后解耦处理 |
| 装饰器 | @Primary 包装 | 动态添加缓存/日志 |
| 责任链 | Interceptor/Filter | 审批流、请求处理 |
| 建造者 | @Builder | 复杂对象构造 |
