# Spring Boot 实用技巧整理

<div class="post-meta">📅 2026-05-10 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">Spring Boot</span></div>

整理一些日常开发中常用但容易遗忘的 Spring Boot 技巧。

## 1. 用 @ConfigurationProperties 代替零散 @Value

```java
@ConfigurationProperties(prefix = "app")
@Component
public class AppProperties {
    private String name;
    private int timeout;
    private List<String> allowedOrigins;
    // getters & setters
}
```

对应 `application.yml`：

```yaml
app:
  name: MyApp
  timeout: 30
  allowed-origins:
    - https://example.com
    - https://api.example.com
```

好处：类型安全、IDE 自动补全、结构清晰。

## 2. 全局统一异常处理

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(ResourceNotFoundException.class)
    public ResponseEntity<ApiError> handleNotFound(ResourceNotFoundException e) {
        return ResponseEntity.status(404)
                .body(new ApiError(404, e.getMessage()));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ApiError> handleValidation(MethodArgumentNotValidException e) {
        String msg = e.getBindingResult().getFieldErrors().stream()
                .map(fe -> fe.getField() + ": " + fe.getDefaultMessage())
                .collect(Collectors.joining("; "));
        return ResponseEntity.badRequest().body(new ApiError(400, msg));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiError> handleGeneral(Exception e) {
        return ResponseEntity.status(500)
                .body(new ApiError(500, "服务器内部错误"));
    }
}
```

## 3. 条件 Bean 注册

```java
// 只在配置项为 true 时注册
@Bean
@ConditionalOnProperty(name = "feature.cache.enabled", havingValue = "true")
public CacheService redisCacheService() {
    return new RedisCacheService();
}

// 仅在缺少某个 Bean 时作为默认实现
@Bean
@ConditionalOnMissingBean(CacheService.class)
public CacheService inMemoryCacheService() {
    return new InMemoryCacheService();
}
```

## 4. 异步方法

```java
// 启动类加 @EnableAsync
@Async("taskExecutor")
public CompletableFuture<Void> sendEmailAsync(String to, String content) {
    emailService.send(to, content);
    return CompletableFuture.completedFuture(null);
}
```

```java
// 自定义线程池（避免默认 SimpleAsyncTaskExecutor 无限创建线程）
@Bean("taskExecutor")
public Executor taskExecutor() {
    ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
    executor.setCorePoolSize(4);
    executor.setMaxPoolSize(16);
    executor.setQueueCapacity(200);
    executor.setThreadNamePrefix("async-");
    executor.initialize();
    return executor;
}
```

## 5. 接口幂等性 —— 用 @Idempotent 自定义注解

```java
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface Idempotent {
    long expireSeconds() default 60;
}
```

配合 AOP 拦截，对相同 `idempotencyKey`（来自请求头）在 Redis 中做去重，60 秒内重复请求直接返回缓存结果。

## 6. 优雅停机

```yaml
# application.yml
server:
  shutdown: graceful

spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s
```

Spring Boot 2.3+ 内置支持，收到 SIGTERM 后等待正在处理的请求完成（最多 30s），然后退出。

---

> 持续更新中...
