# OpenFeign 调用原理与超时重试配置

<div class="post-meta">📅 2025-09-06 &nbsp;·&nbsp; 🏷️ <span class="tag">OpenFeign</span> <span class="tag">微服务</span></div>

OpenFeign 是 Spring Cloud 中最常用的声明式 HTTP 客户端，屏蔽了底层 HTTP 调用细节，让服务间 RPC 调用像调用本地接口一样简单。本文深入分析动态代理原理、超时配置、重试策略和熔断集成。

---

## 一、OpenFeign 动态代理原理

### 1.1 整体调用链路

```
@FeignClient 接口
       ↓
   JDK 动态代理（FeignInvocationHandler）
       ↓
   方法分派（SynchronousMethodHandler）
       ↓
   请求模板构建（RequestTemplate）
       ↓
   负载均衡（LoadBalancerFeignClient）
       ↓ 从 Nacos/注册中心 获取实例列表
   选择实例（RoundRobinLoadBalancer）
       ↓
   实际 HTTP 调用（OkHttpClient / HttpClient）
       ↓
   响应解码（Decoder）
       ↓
   返回 Java 对象
```

### 1.2 Bean 初始化过程

```java
// 1. @EnableFeignClients 触发扫描
@SpringBootApplication
@EnableFeignClients(basePackages = "com.example.feign")
public class OrderServiceApplication { ... }

// 2. FeignClientsRegistrar 扫描 @FeignClient 注解
//    为每个接口注册 FeignClientFactoryBean

// 3. 应用启动时，FeignClientFactoryBean.getObject() 被调用
//    → Feign.builder().target(interface, url)
//    → JDK 动态代理生成代理对象
//    → 注册到 Spring 容器

// 4. 使用时，代理对象的 invoke() 被调用
//    → 解析方法上的注解（@GetMapping 等）
//    → 构建 HTTP Request
//    → 通过负载均衡选择实例
//    → 发送 HTTP 请求
```

### 1.3 关键源码理解

```java
// FeignInvocationHandler（核心入口）
class FeignInvocationHandler implements InvocationHandler {
    
    private final Map<Method, MethodHandler> dispatch; // 方法 → 处理器
    
    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        // 等价接口：toString/equals/hashCode 直接处理
        if (method.getDeclaringClass() == Object.class) {
            return method.invoke(this, args);
        }
        // 分派给对应的 MethodHandler
        return dispatch.get(method).invoke(args);
    }
}

// SynchronousMethodHandler（实际处理器）
final class SynchronousMethodHandler implements MethodHandler {
    
    @Override
    public Object invoke(Object[] argv) throws Throwable {
        // 1. 构建请求模板（替换路径参数、Query参数）
        RequestTemplate template = buildTemplateFromArgs.create(argv);
        
        // 2. 应用请求拦截器
        for (RequestInterceptor interceptor : requestInterceptors) {
            interceptor.apply(template);
        }
        
        // 3. 执行重试逻辑
        Retryer retryer = this.retryer.clone();
        while (true) {
            try {
                return executeAndDecode(template, options);
            } catch (RetryableException e) {
                retryer.continueOrPropagate(e); // 判断是否继续重试
            }
        }
    }
}
```

---

## 二、基础使用

### 2.1 声明 FeignClient

```java
@FeignClient(
    name = "user-service",                    // 服务名（Nacos 注册名）
    path = "/api/v1",                          // 基础路径（可选）
    fallback = UserServiceFallback.class,      // 降级实现
    configuration = UserFeignConfig.class      // 自定义配置
)
public interface UserFeignClient {
    
    // GET 请求
    @GetMapping("/user/{userId}")
    UserDTO getUserById(@PathVariable("userId") Long userId);
    
    // POST 请求（传递对象）
    @PostMapping("/user")
    UserDTO createUser(@RequestBody CreateUserDTO dto);
    
    // 传递查询参数
    @GetMapping("/user/list")
    PageResult<UserDTO> listUsers(
        @RequestParam("page") int page,
        @RequestParam("size") int size,
        @RequestParam(value = "keyword", required = false) String keyword
    );
    
    // 传递 Header
    @GetMapping("/user/profile")
    UserProfileDTO getProfile(@RequestHeader("Authorization") String token);
    
    // 文件上传
    @PostMapping(value = "/user/avatar", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    String uploadAvatar(@RequestPart("file") MultipartFile file);
}
```

---

## 三、超时配置

### 3.1 全局超时配置

```yaml
# application.yml
feign:
  client:
    config:
      default:                          # 全局默认配置
        connect-timeout: 5000           # 连接超时（ms）
        read-timeout: 10000             # 读取超时（ms）
        logger-level: BASIC             # 日志级别
```

### 3.2 针对特定服务的超时配置

```yaml
feign:
  client:
    config:
      default:
        connect-timeout: 5000
        read-timeout: 10000
      user-service:                     # 针对 user-service 的配置（优先级更高）
        connect-timeout: 2000
        read-timeout: 3000
      payment-service:                  # 支付服务：超时时间更长
        connect-timeout: 5000
        read-timeout: 30000             # 支付接口允许更长的等待
```

### 3.3 代码方式配置（@Bean 优先级低于 yml）

```java
@Configuration
public class UserFeignConfig {
    
    /**
     * 自定义超时选项
     * 注意：代码配置会被 yml 中同名服务配置覆盖
     */
    @Bean
    public Request.Options requestOptions() {
        return new Request.Options(
            2000, TimeUnit.MILLISECONDS,   // 连接超时
            5000, TimeUnit.MILLISECONDS,   // 读取超时
            true                           // followRedirects
        );
    }
}
```

---

## 四、重试策略（Retryer）

### 4.1 默认重试行为

```java
// Feign 默认：Retryer.NEVER_RETRY（不重试）
// Spring Cloud OpenFeign 默认也关闭重试（避免幂等问题）
```

### 4.2 开启重试

```java
@Configuration
public class FeignRetryConfig {
    
    /**
     * 开启重试：最多重试5次，初始间隔100ms，最大间隔1s
     */
    @Bean
    public Retryer retryer() {
        // 参数：period（初始间隔ms）, maxPeriod（最大间隔ms）, maxAttempts（最大尝试次数，含第一次）
        return new Retryer.Default(100, 1000, 5);
    }
}
```

```yaml
# yml 中指定重试配置（服务级别）
feign:
  client:
    config:
      user-service:
        retryer: feign.Retryer.Default  # 使用默认重试器
```

### 4.3 自定义重试策略

```java
/**
 * 自定义重试策略：指数退避 + 最大重试次数
 */
public class ExponentialRetryer implements Retryer {
    
    private final int maxAttempts;
    private final long initialInterval;
    private int attempt = 1;
    private long nextInterval;
    
    public ExponentialRetryer(int maxAttempts, long initialIntervalMs) {
        this.maxAttempts = maxAttempts;
        this.initialInterval = initialIntervalMs;
        this.nextInterval = initialIntervalMs;
    }
    
    @Override
    public void continueOrPropagate(RetryableException e) {
        if (attempt++ >= maxAttempts) {
            throw e; // 超过最大重试次数，抛出异常
        }
        
        long interval = nextInterval;
        nextInterval = Math.min(nextInterval * 2, 5000); // 指数退避，最大5s
        
        try {
            Thread.sleep(interval);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            throw e;
        }
    }
    
    @Override
    public Retryer clone() {
        // 每次调用都返回新实例（重置状态）
        return new ExponentialRetryer(maxAttempts, initialInterval);
    }
}
```

> **注意**：重试只对 `GET` 等幂等接口安全，`POST/PUT/DELETE` 需要接口本身保证幂等后再开启重试。

---

## 五、错误解码（ErrorDecoder）

```java
/**
 * 自定义错误解码器：将 HTTP 错误响应转换为业务异常
 */
@Component
public class GlobalFeignErrorDecoder implements ErrorDecoder {
    
    private final ErrorDecoder defaultDecoder = new ErrorDecoder.Default();
    
    @Override
    public Exception decode(String methodKey, Response response) {
        int status = response.status();
        String body = "";
        
        try {
            if (response.body() != null) {
                body = Util.toString(response.body().asReader(StandardCharsets.UTF_8));
            }
        } catch (IOException e) {
            log.error("读取 Feign 错误响应体失败", e);
        }
        
        switch (status) {
            case 400:
                return new BadRequestException("下游服务参数错误：" + body);
            case 401:
                return new UnauthorizedException("下游服务认证失败");
            case 403:
                return new ForbiddenException("下游服务权限不足");
            case 404:
                return new ResourceNotFoundException("下游资源不存在：" + methodKey);
            case 429:
                // 429 可重试（下游限流）
                return new RetryableException(
                    status, "下游服务限流，稍后重试", 
                    Request.HttpMethod.GET, null, null
                );
            case 500:
            case 502:
            case 503:
                // 5xx 可重试
                return new RetryableException(
                    status, "下游服务内部错误", 
                    Request.HttpMethod.GET, 
                    new Date(System.currentTimeMillis() + 1000L),
                    null
                );
            default:
                return defaultDecoder.decode(methodKey, response);
        }
    }
}
```

---

## 六、请求拦截器（RequestInterceptor）

```java
/**
 * 透传请求头（将当前请求的 Token、TraceId 传递给下游）
 */
@Component
public class FeignRequestInterceptor implements RequestInterceptor {
    
    @Override
    public void apply(RequestTemplate template) {
        // 从当前请求上下文获取 Header
        ServletRequestAttributes attributes = 
            (ServletRequestAttributes) RequestContextHolder.getRequestAttributes();
        
        if (attributes != null) {
            HttpServletRequest request = attributes.getRequest();
            
            // 透传认证 Token
            String token = request.getHeader("Authorization");
            if (StringUtils.hasText(token)) {
                template.header("Authorization", token);
            }
            
            // 透传链路追踪 ID
            String traceId = request.getHeader("X-Trace-Id");
            if (StringUtils.hasText(traceId)) {
                template.header("X-Trace-Id", traceId);
            }
        }
        
        // 添加固定 Header
        template.header("X-Source-Service", "order-service");
    }
}
```

---

## 七、日志配置

```java
// 日志级别枚举
// NONE：不记录日志（默认）
// BASIC：请求方法、URL、响应状态码、执行时间
// HEADERS：BASIC + 请求/响应头
// FULL：HEADERS + 请求/响应体

@Configuration
public class FeignLogConfig {
    
    @Bean
    Logger.Level feignLogLevel() {
        return Logger.Level.FULL; // 开发调试用 FULL，生产用 BASIC
    }
}
```

```yaml
# 必须配置 Feign 接口的日志级别为 DEBUG
logging:
  level:
    com.example.feign: DEBUG  # Feign 接口所在包
```

---

## 八、Sentinel 熔断集成

```yaml
feign:
  sentinel:
    enabled: true  # 开启 Feign + Sentinel 集成
```

```java
@FeignClient(
    name = "user-service",
    fallbackFactory = UserFeignFallbackFactory.class  // 使用 FallbackFactory 获取异常
)
public interface UserFeignClient {
    @GetMapping("/user/{userId}")
    UserDTO getUserById(@PathVariable("userId") Long userId);
}

/**
 * FallbackFactory：可以获取导致降级的异常
 */
@Component
public class UserFeignFallbackFactory implements FallbackFactory<UserFeignClient> {
    
    @Override
    public UserFeignClient create(Throwable cause) {
        return new UserFeignClient() {
            @Override
            public UserDTO getUserById(Long userId) {
                log.error("调用用户服务失败，userId={}，原因：{}", userId, cause.getMessage());
                
                // 根据异常类型区分处理
                if (cause instanceof FeignException.ServiceUnavailable) {
                    // 服务不可用：返回缓存数据
                    return userCacheService.getCachedUser(userId);
                }
                // 其他异常：返回默认空对象
                return UserDTO.empty(userId);
            }
        };
    }
}
```

---

## 九、常用配置汇总

| 配置项 | 默认值 | 说明 |
|-------|-------|------|
| `feign.client.config.default.connect-timeout` | 10000 | 连接超时（ms）|
| `feign.client.config.default.read-timeout` | 60000 | 读取超时（ms）|
| `feign.client.config.default.logger-level` | NONE | 日志级别 |
| `feign.sentinel.enabled` | false | 是否开启 Sentinel 集成 |
| `feign.okhttp.enabled` | false | 是否使用 OkHttp（推荐开启）|
| `feign.httpclient.enabled` | true | 是否使用 Apache HttpClient |
| `feign.compression.request.enabled` | false | 请求压缩 |
| `feign.compression.response.enabled` | false | 响应压缩 |

```yaml
# 推荐生产配置
feign:
  okhttp:
    enabled: true           # 使用 OkHttp（性能更好，支持连接池）
  sentinel:
    enabled: true
  compression:
    request:
      enabled: true
      min-request-size: 2048  # 超过2KB才压缩
    response:
      enabled: true
  client:
    config:
      default:
        connect-timeout: 3000
        read-timeout: 10000
        logger-level: BASIC
```
