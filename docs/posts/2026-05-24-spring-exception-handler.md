# Spring Boot 全局异常处理与参数校验工程化设计

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](2024-08-22-spring-aop-proxy.md)
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](2026-05-24-spring-boot-startup.md)
> - [SB-08 Spring Boot 自动装配原理深度解析](2024-10-27-spring-boot-autoconfigure.md)
> - [SB-09 Spring Boot 配置体系详解](2026-05-16-spring-boot-config-priority.md)
> - [SB-10 Spring Boot 条件装配：@Conditional 体系](2026-05-24-spring-boot-conditional.md)
> - [SB-11 Spring 循环依赖：三级缓存的设计原理](2026-05-24-spring-circular-dependency.md)
> - [SB-12 Filter、Interceptor、AOP 三者对比与选型](2026-05-24-spring-filter-interceptor-aop.md)
> - [SB-13 Spring 事件驱动：ApplicationEvent 与监听器](2026-05-24-spring-events.md)
> - [SB-14 Spring @Async 异步编程：原理与线程池配置](2026-05-24-spring-async.md)
> - [SB-15 Spring 扩展点：BPP、BFPP 与 ImportSelector](2026-05-24-spring-extension-points.md)
> - 👉 **SB-16 Spring Boot 全局异常处理与参数校验工程化设计（本文）**
> - [SB-17 Spring Boot 多数据源：动态路由与跨库事务](2026-05-24-spring-boot-multi-datasource.md)
> - [SB-18 Spring Boot Actuator：健康检查与自定义端点](2026-05-24-spring-boot-actuator.md)
> - [SB-19 Spring Boot 自定义 Starter：从设计到发布](2026-05-24-spring-boot-custom-starter.md)
> - [SB-20 Spring Security 认证授权完整流程](2024-12-23-spring-security-auth.md)
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](2026-05-24-spring-boot-testing.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 22 分钟｜**分类**：Spring 生态

---

## 导读

生产级 API 需要两件事：统一的响应格式让前端好对接，清晰的错误信息让调用方知道哪里出了问题。本文构建一套完整的异常处理与参数校验方案：统一响应体 `R<T>` 设计、业务异常体系、`@ControllerAdvice` 全局捕获、JSR-303 参数校验与分组校验，以及多模块项目中的复用策略。

---

## 一、统一响应体设计

```java
// Spring Boot 3.2 + JDK 17
// 通用响应体：泛型 + 静态工厂方法
@Data
@NoArgsConstructor
@AllArgsConstructor
public class R<T> {
    private int code;      // 业务状态码
    private String msg;    // 提示信息
    private T data;        // 响应数据

    // 成功
    public static <T> R<T> ok(T data) {
        return new R<>(200, "success", data);
    }
    public static <T> R<T> ok() {
        return ok(null);
    }

    // 失败
    public static <T> R<T> fail(int code, String msg) {
        return new R<>(code, msg, null);
    }
    public static <T> R<T> fail(ErrorCode errorCode) {
        return new R<>(errorCode.getCode(), errorCode.getMsg(), null);
    }
}

// 统一错误码枚举
@Getter
@AllArgsConstructor
public enum ErrorCode {
    // 通用
    PARAM_ERROR(400, "参数校验失败"),
    UNAUTHORIZED(401, "未登录或登录已过期"),
    FORBIDDEN(403, "无权限访问"),
    NOT_FOUND(404, "资源不存在"),
    SYSTEM_ERROR(500, "系统内部错误"),
    // 业务
    ORDER_NOT_FOUND(1001, "订单不存在"),
    INSUFFICIENT_STOCK(1002, "库存不足"),
    ORDER_ALREADY_PAID(1003, "订单已支付，请勿重复操作");

    private final int code;
    private final String msg;
}
```

---

## 二、业务异常体系

```java
// 业务异常基类：携带错误码，不打印堆栈（性能优化）
public class BusinessException extends RuntimeException {
    private final ErrorCode errorCode;

    public BusinessException(ErrorCode errorCode) {
        super(errorCode.getMsg(), null, true, false); // fillInStackTrace = false
        this.errorCode = errorCode;
    }

    public BusinessException(ErrorCode errorCode, String detail) {
        super(detail, null, true, false);
        this.errorCode = errorCode;
    }

    public ErrorCode getErrorCode() {
        return errorCode;
    }
}

// 具体业务异常
public class OrderNotFoundException extends BusinessException {
    public OrderNotFoundException(Long orderId) {
        super(ErrorCode.ORDER_NOT_FOUND, "订单 " + orderId + " 不存在");
    }
}

// 使用
public Order getOrder(Long id) {
    return orderRepo.findById(id)
        .orElseThrow(() -> new OrderNotFoundException(id));
}
```

---

## 三、@ControllerAdvice 全局异常处理

```java
// Spring Boot 3.2 + JDK 17
@RestControllerAdvice // = @ControllerAdvice + @ResponseBody
@Slf4j
public class GlobalExceptionHandler {

    // 1. 业务异常：已知异常，不打堆栈，只记录 WARN 日志
    @ExceptionHandler(BusinessException.class)
    public R<Void> handleBusinessException(BusinessException ex) {
        log.warn("Business exception: code={}, msg={}", ex.getErrorCode().getCode(), ex.getMessage());
        return R.fail(ex.getErrorCode());
    }

    // 2. 参数校验失败（@RequestBody + @Validated 触发）
    @ExceptionHandler(MethodArgumentNotValidException.class)
    public R<Void> handleValidationException(MethodArgumentNotValidException ex) {
        // 提取第一个校验失败的字段和消息
        String msg = ex.getBindingResult().getFieldErrors().stream()
            .map(fe -> fe.getField() + ": " + fe.getDefaultMessage())
            .collect(Collectors.joining("; "));
        log.warn("Validation failed: {}", msg);
        return R.fail(400, msg);
    }

    // 3. 参数校验失败（@RequestParam / @PathVariable 触发）
    @ExceptionHandler(ConstraintViolationException.class)
    public R<Void> handleConstraintViolation(ConstraintViolationException ex) {
        String msg = ex.getConstraintViolations().stream()
            .map(v -> v.getPropertyPath() + ": " + v.getMessage())
            .collect(Collectors.joining("; "));
        return R.fail(400, msg);
    }

    // 4. 请求方法不匹配（如 POST 接口收到 GET 请求）
    @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
    public R<Void> handleMethodNotSupported(HttpRequestMethodNotSupportedException ex) {
        return R.fail(405, "请求方法不支持: " + ex.getMethod());
    }

    // 5. 兜底：未知异常，打完整堆栈，返回 500
    @ExceptionHandler(Exception.class)
    public R<Void> handleUnknownException(Exception ex, HttpServletRequest request) {
        log.error("Unexpected error on [{}] {}", request.getMethod(), request.getRequestURI(), ex);
        return R.fail(ErrorCode.SYSTEM_ERROR);
    }
}
```

---

## 四、JSR-303 参数校验

### 4.1 常用校验注解

```java
// Spring Boot 3.2 + JDK 17 + spring-boot-starter-validation
@Data
public class CreateOrderRequest {
    @NotNull(message = "用户 ID 不能为空")
    private Long userId;

    @NotEmpty(message = "商品列表不能为空")
    @Size(max = 20, message = "单次最多购买 20 种商品")
    private List<@Valid OrderItemRequest> items;

    @NotBlank(message = "收货地址不能为空")
    @Length(max = 200, message = "收货地址不超过 200 字")
    private String address;

    @Pattern(regexp = "^1[3-9]\\d{9}$", message = "手机号格式不正确")
    private String phone;
}

@Data
public class OrderItemRequest {
    @NotNull
    private Long productId;

    @Min(value = 1, message = "购买数量最少为 1")
    @Max(value = 100, message = "单次购买最多 100 件")
    private Integer qty;
}

// Controller 中开启校验
@PostMapping("/orders")
public R<Order> createOrder(@RequestBody @Validated CreateOrderRequest request) {
    // 如果校验失败，MethodArgumentNotValidException 由全局处理器捕获
    return R.ok(orderService.create(request));
}
```

### 4.2 分组校验

创建和更新场景校验规则不同（创建时 ID 为空，更新时 ID 必须非空）：

```java
// 定义分组接口
public interface CreateGroup {}
public interface UpdateGroup {}

@Data
public class UserRequest {
    @Null(groups = CreateGroup.class, message = "创建时 ID 必须为空")
    @NotNull(groups = UpdateGroup.class, message = "更新时 ID 不能为空")
    private Long id;

    @NotBlank(groups = {CreateGroup.class, UpdateGroup.class})
    private String name;

    @Email(groups = CreateGroup.class) // 仅创建时校验格式
    private String email;
}

// Controller 指定分组
@PostMapping
public R<User> create(@RequestBody @Validated(CreateGroup.class) UserRequest req) {
    return R.ok(userService.create(req));
}

@PutMapping
public R<User> update(@RequestBody @Validated(UpdateGroup.class) UserRequest req) {
    return R.ok(userService.update(req));
}
```

### 4.3 自定义校验注解

```java
// 自定义手机号校验注解
@Target(ElementType.FIELD)
@Retention(RetentionPolicy.RUNTIME)
@Constraint(validatedBy = PhoneValidator.class)
public @interface Phone {
    String message() default "手机号格式不正确";
    Class<?>[] groups() default {};
    Class<? extends Payload>[] payload() default {};
}

// 实现校验器
public class PhoneValidator implements ConstraintValidator<Phone, String> {
    private static final Pattern PHONE_PATTERN = Pattern.compile("^1[3-9]\\d{9}$");

    @Override
    public boolean isValid(String value, ConstraintValidatorContext context) {
        if (value == null) return true; // null 由 @NotNull 处理
        return PHONE_PATTERN.matcher(value).matches();
    }
}
```

---

## 五、踩坑总结

❌ **`@Validated` 加在 Controller 方法参数上校验不生效，加在 Service 方法上也无效**

✅ 两个场景原因不同：①方法参数 `@RequestParam` 校验：需要在 Controller **类**上加 `@Validated`（而非方法参数），并在方法参数上加约束注解；`MethodArgumentNotValidException` 只针对 `@RequestBody`。②Service 方法校验：需要在 Service 类上加 `@Validated` 并开启 `MethodValidationPostProcessor`（Spring Boot 3.x 已自动配置）。

❌ **全局异常处理捕获了 Exception 打日志，但生产上 400 错误也出现了大量 ERROR 日志，告警泛滥**

✅ `@ExceptionHandler(Exception.class)` 兜底处理应只记录 ERROR 日志。已知业务异常（`BusinessException`、`MethodArgumentNotValidException`）应记录 WARN 或 INFO，不应触发告警。合理分级：业务异常 WARN，未知异常 ERROR。

---

## 六、文章小结

- 统一响应体 `R<T>` + 错误码枚举是 API 工程化的基础，使前后端对接标准化
- 业务异常继承 `RuntimeException` 并设 `fillInStackTrace = false`，避免不必要的堆栈生成
- `@RestControllerAdvice` + `@ExceptionHandler` 按异常类型优先级匹配，兜底 `Exception.class` 处理未知异常
- JSR-303 分组校验解决同一 DTO 在不同场景下校验规则不同的问题
- `@Validated` 在 Controller 类级别和方法参数上使用的位置和触发的异常类型不同，需区分

---

## 七、思考题

1. `@ControllerAdvice` 捕获的异常有哪些无法捕获？如何处理 Filter 层或 404 错误？

2. 参数校验失败时，如何返回所有字段的错误信息（而不只是第一个）？如何让前端能按字段名快速定位？

---

## 参考资料

> 1. [Spring MVC 官方文档 - @ControllerAdvice](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-advice.html)
> 2. [Jakarta Bean Validation 3.0 规范](https://jakarta.ee/specifications/bean-validation/3.0/)
> 3. [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](2026-05-24-spring-mvc-dispatcher.md)
> 4. [SB-12 Filter、Interceptor、AOP 三者对比与选型](2026-05-24-spring-filter-interceptor-aop.md)
