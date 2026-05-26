# Spring MVC 请求处理：DispatcherServlet 与九大组件

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> - 👉 **SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件（本文）**
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](posts/2026-05-24-spring-boot-startup.md)
> - [SB-08 Spring Boot 自动装配原理深度解析](posts/2024-10-27-spring-boot-autoconfigure.md)
> - [SB-09 Spring Boot 配置体系详解](posts/2026-05-16-spring-boot-config-priority.md)
> - [SB-10 Spring Boot 条件装配：@Conditional 体系](posts/2026-05-24-spring-boot-conditional.md)
> - [SB-11 Spring 循环依赖：三级缓存的设计原理](posts/2026-05-24-spring-circular-dependency.md)
> - [SB-12 Filter、Interceptor、AOP 三者对比与选型](posts/2026-05-24-spring-filter-interceptor-aop.md)
> - [SB-13 Spring 事件驱动：ApplicationEvent 与监听器](posts/2026-05-24-spring-events.md)
> - [SB-14 Spring @Async 异步编程：原理与线程池配置](posts/2026-05-24-spring-async.md)
> - [SB-15 Spring 扩展点：BPP、BFPP 与 ImportSelector](posts/2026-05-24-spring-extension-points.md)
> - [SB-16 Spring Boot 全局异常处理与参数校验](posts/2026-05-24-spring-exception-handler.md)
> - [SB-17 Spring Boot 多数据源：动态路由与跨库事务](posts/2026-05-24-spring-boot-multi-datasource.md)
> - [SB-18 Spring Boot Actuator：健康检查与自定义端点](posts/2026-05-24-spring-boot-actuator.md)
> - [SB-19 Spring Boot 自定义 Starter：从设计到发布](posts/2026-05-24-spring-boot-custom-starter.md)
> - [SB-20 Spring Security 认证授权完整流程](posts/2024-12-23-spring-security-auth.md)
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](posts/2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](posts/2026-05-24-spring-boot-testing.md)

**深度等级**：⭐ 入门｜**阅读时长**：约 18 分钟｜**分类**：Spring 生态

---

## 导读

一个 HTTP 请求从进入 Tomcat 到最终返回 JSON 响应，中间经历了什么？DispatcherServlet 为什么叫"前端控制器"？本文拆解 Spring MVC 请求处理的完整链路，逐一介绍九大组件的职责，并说明 `@RequestMapping`、参数绑定、拦截器、异常处理各自在哪个环节介入。

---

## 一、DispatcherServlet 的定位

Spring MVC 的设计核心是**前端控制器模式（Front Controller Pattern）**：所有请求都先到达 `DispatcherServlet`，再由它分发给具体处理器。

```
Browser
  |
  | HTTP Request
  v
Tomcat (Servlet Container)
  |
  v
DispatcherServlet  (Front Controller)
  |
  |-- HandlerMapping -> find Handler
  |-- HandlerAdapter -> invoke Handler
  |-- ViewResolver   -> resolve View
  |
  v
@Controller / @RestController
  |
  v
HTTP Response
```

`DispatcherServlet` 本身是一个 `Servlet`（继承自 `HttpServlet`），Tomcat 将所有请求委托给它。它持有 `WebApplicationContext`，从中取出九大组件来完成请求处理。

---

## 二、请求处理完整流程

```
HTTP Request
    |
    v
[1] DispatcherServlet.doDispatch()
    |
    |-- [2] HandlerMapping.getHandler()
    |        -> HandlerExecutionChain（包含 Handler + Interceptors）
    |
    |-- [3] HandlerAdapter.supports(handler)
    |        -> 找到能处理该 Handler 的适配器
    |
    |-- [4] HandlerInterceptor.preHandle()
    |        -> 拦截器前置处理（返回 false 则终止）
    |
    |-- [5] HandlerAdapter.handle()
    |        -> 调用 @Controller 方法
    |        -> 参数绑定（HandlerMethodArgumentResolver）
    |        -> 返回值处理（HandlerMethodReturnValueHandler）
    |
    |-- [6] HandlerInterceptor.postHandle()
    |        -> 拦截器后置处理
    |
    |-- [7] processDispatchResult()
    |        -> 异常处理（HandlerExceptionResolver）
    |        -> View 渲染 / JSON 序列化
    |
    |-- [8] HandlerInterceptor.afterCompletion()
    |        -> 请求完成回调（无论成功/异常）
    |
    v
HTTP Response
```

---

## 三、九大组件详解

### 3.1 HandlerMapping — 请求路由

`HandlerMapping` 根据请求 URL、Method 等找到处理器（Handler）。Spring MVC 内置多种实现：

| 实现类 | 适用场景 |
|--------|---------|
| `RequestMappingHandlerMapping` | `@RequestMapping` 注解方法（最常用）|
| `RouterFunctionMapping` | WebFlux 函数式路由 |
| `SimpleUrlHandlerMapping` | 静态资源（`/static/**`）|

`RequestMappingHandlerMapping` 在初始化时扫描所有 `@Controller`，将 `@RequestMapping` 信息（路径、方法、消费/生产类型）注册到内部的 `MappingRegistry`。

### 3.2 HandlerAdapter — 适配执行

Handler 可能是 `@Controller` 方法、`HttpRequestHandler`、`Servlet` 等不同类型，`HandlerAdapter` 屏蔽这些差异。

| 实现类 | 处理的 Handler 类型 |
|--------|-------------------|
| `RequestMappingHandlerAdapter` | `@RequestMapping` 注解方法 |
| `HttpRequestHandlerAdapter` | `HttpRequestHandler` 接口实现 |
| `SimpleControllerHandlerAdapter` | `Controller` 接口实现 |

核心：`RequestMappingHandlerAdapter.invokeHandlerMethod()` 负责：
1. 参数解析（`HandlerMethodArgumentResolver` 列表，逐个尝试，谁支持就谁处理）
2. 方法调用（反射）
3. 返回值处理（`HandlerMethodReturnValueHandler`）

### 3.3 HandlerExceptionResolver — 异常处理

| 实现类 | 作用 |
|--------|------|
| `ExceptionHandlerExceptionResolver` | 处理 `@ExceptionHandler` 方法 |
| `ResponseStatusExceptionResolver` | 处理 `@ResponseStatus` 注解异常 |
| `DefaultHandlerExceptionResolver` | 处理 Spring MVC 内置异常（如 400/405/415）|

三个实现按优先级顺序尝试，如果都处理不了则抛出给 Servlet 容器。
`@ControllerAdvice` + `@ExceptionHandler` 是生产中最常用的统一异常处理方式（详见 [SB-16](posts/2026-05-24-spring-exception-handler.md)）。

### 3.4 ViewResolver 与 MessageConverters

**ViewResolver**：将逻辑视图名解析为实际 `View` 对象（Thymeleaf、Freemarker 等）。对于 `@RestController` + JSON 的场景，返回值由 `HttpMessageConverter` 直接序列化写入响应体，不走 ViewResolver。

**HttpMessageConverter**（消息转换器）：完成 Java 对象与 HTTP Body 之间的序列化/反序列化。

| 转换器 | 处理类型 |
|--------|---------|
| `MappingJackson2HttpMessageConverter` | `application/json` ↔ Java 对象 |
| `StringHttpMessageConverter` | `text/plain` ↔ `String` |
| `ByteArrayHttpMessageConverter` | `application/octet-stream` ↔ `byte[]` |

### 3.5 其余组件

| 组件接口 | 职责 |
|---------|------|
| `MultipartResolver` | 解析文件上传请求（`multipart/form-data`）|
| `LocaleResolver` | 解析请求的 Locale（用于国际化）|
| `ThemeResolver` | 解析主题（现代应用很少使用）|

---

## 四、参数绑定原理

`@RequestMapping` 方法的参数，为什么加了 `@RequestParam` 就能自动绑定？

`HandlerMethodArgumentResolver` 是关键接口，Spring MVC 内置了 30+ 个实现：

```java
public interface HandlerMethodArgumentResolver {
    boolean supportsParameter(MethodParameter parameter);
    Object resolveArgument(MethodParameter parameter,
                           ModelAndViewContainer mavContainer,
                           NativeWebRequest webRequest,
                           WebDataBinderFactory binderFactory) throws Exception;
}
```

常见解析器：

| 解析器 | 处理的参数注解 |
|--------|--------------|
| `RequestParamMethodArgumentResolver` | `@RequestParam` |
| `RequestBodyMethodArgumentResolver` | `@RequestBody` |
| `PathVariableMethodArgumentResolver` | `@PathVariable` |
| `RequestHeaderMethodArgumentResolver` | `@RequestHeader` |
| `ModelMethodProcessor` | `Model`、`ModelMap` 参数 |
| `ServletRequestMethodArgumentResolver` | `HttpServletRequest` 等 Servlet 类型 |

---

## 五、实战示例：自定义 HandlerMethodArgumentResolver

```java
// Spring Boot 3.2 + JDK 17
// 场景：自动从 JWT Token 中解析当前登录用户，注入到 Controller 方法参数

// 1. 自定义注解
@Target(ElementType.PARAMETER)
@Retention(RetentionPolicy.RUNTIME)
public @interface CurrentUser {}

// 2. 实现参数解析器
@Component
public class CurrentUserArgumentResolver implements HandlerMethodArgumentResolver {

    @Override
    public boolean supportsParameter(MethodParameter parameter) {
        // 只处理标注了 @CurrentUser 的 UserInfo 类型参数
        return parameter.hasParameterAnnotation(CurrentUser.class)
            && parameter.getParameterType().equals(UserInfo.class);
    }

    @Override
    public Object resolveArgument(MethodParameter parameter,
                                  ModelAndViewContainer mavContainer,
                                  NativeWebRequest webRequest,
                                  WebDataBinderFactory binderFactory) {
        HttpServletRequest request = (HttpServletRequest) webRequest.getNativeRequest();
        // 从请求上下文中获取（通常由 JWT 拦截器提前放入 ThreadLocal）
        return UserContext.getCurrentUser();
    }
}

// 3. 注册解析器
@Configuration
public class WebMvcConfig implements WebMvcConfigurer {
    @Autowired
    private CurrentUserArgumentResolver currentUserArgumentResolver;

    @Override
    public void addArgumentResolvers(List<HandlerMethodArgumentResolver> resolvers) {
        resolvers.add(currentUserArgumentResolver);
    }
}

// 4. 使用
@RestController
public class OrderController {
    @GetMapping("/orders")
    public List<Order> myOrders(@CurrentUser UserInfo user) { // 自动注入
        return orderService.findByUserId(user.getId());
    }
}
```

---

## 六、踩坑总结

❌ **在 Interceptor 的 `preHandle` 中调用 `response.getWriter().write()`，但 `postHandle` 和 `afterCompletion` 仍然执行**

✅ `preHandle` 返回 `false` 只阻止 Handler 执行，后续的 `postHandle` 不会被调用，但 `afterCompletion` **依然会执行**（已调用过 `preHandle` 的拦截器都会执行 `afterCompletion`）。需要在 `preHandle` 返回 `false` 时手动写完响应并 `flush`，不要依赖后续流程。

❌ **`@ControllerAdvice` 的 `@ExceptionHandler` 无法捕获过滤器（Filter）中抛出的异常**

✅ `@ExceptionHandler` 处于 DispatcherServlet 层，过滤器在 DispatcherServlet 之前执行，其中的异常无法被 `HandlerExceptionResolver` 捕获。过滤器异常需要在过滤器内部 `try-catch` 处理，或使用 `@WebFilter` + 自定义错误响应。

---

## 七、文章小结

- `DispatcherServlet` 是 Spring MVC 的前端控制器，持有 `WebApplicationContext`，协调九大组件完成请求处理
- 九大组件各司其职：HandlerMapping 路由、HandlerAdapter 执行、HandlerExceptionResolver 异常、ViewResolver/MessageConverter 响应
- 参数绑定由 `HandlerMethodArgumentResolver` 链完成，自定义解析器可实现参数自动注入（如 @CurrentUser）
- 拦截器执行顺序：`preHandle`（正序） → Handler → `postHandle`（逆序） → `afterCompletion`（逆序）
- `@RestController` 走 MessageConverter 序列化，不走 ViewResolver

---

## 八、思考题

1. Spring MVC 的 `HandlerInterceptor` 和 Servlet `Filter` 都能拦截请求，两者的执行顺序是什么？实现原理有什么本质区别？（提示：见 [SB-12](posts/2026-05-24-spring-filter-interceptor-aop.md)）

2. 当同一个路径有多个 `@RequestMapping` 方法（比如 `@GetMapping` 和 `@PostMapping`），`RequestMappingHandlerMapping` 是如何精确匹配的？如果路径相同、Method 也相同会怎样？

---

## 参考资料

> 1. [Spring MVC 官方文档 - DispatcherServlet](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-servlet.html)
> 2. Spring Framework 源码：`DispatcherServlet`、`RequestMappingHandlerAdapter`（版本：6.1）
> 3. [SB-12 Filter、Interceptor、AOP 三者对比与选型](posts/2026-05-24-spring-filter-interceptor-aop.md)
> 4. [SB-16 Spring Boot 全局异常处理与参数校验](posts/2026-05-24-spring-exception-handler.md)
