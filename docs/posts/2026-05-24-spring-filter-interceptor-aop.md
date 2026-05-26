# Filter、Interceptor、AOP 三者对比与选型

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](posts/2026-05-24-spring-boot-startup.md)
> - [SB-08 Spring Boot 自动装配原理深度解析](posts/2024-10-27-spring-boot-autoconfigure.md)
> - [SB-09 Spring Boot 配置体系详解](posts/2026-05-16-spring-boot-config-priority.md)
> - [SB-10 Spring Boot 条件装配：@Conditional 体系](posts/2026-05-24-spring-boot-conditional.md)
> - [SB-11 Spring 循环依赖：三级缓存的设计原理](posts/2026-05-24-spring-circular-dependency.md)
> - 👉 **SB-12 Filter、Interceptor、AOP 三者对比与选型（本文）**
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

**深度等级**：⭐ 入门｜**阅读时长**：约 16 分钟｜**分类**：Spring 生态

---

## 导读

日志记录、权限校验、接口限流——这些横切关注点用 Filter、Interceptor 还是 AOP 来做？选错了轻则功能不对，重则 Spring 注入失效、事务不生效。本文对比三者的执行链路位置、能力边界和适用场景，给出清晰的选型标准。

---

## 一、执行链路位置

三者处于请求链路的不同层级：

```
HTTP Request
    |
    v
[Servlet Container - Tomcat]
    |
    v
Filter 1 (OncePerRequestFilter)
Filter 2 (CharacterEncodingFilter)
    |
    v
DispatcherServlet
    |
    v
Interceptor.preHandle()
    |
    v
HandlerAdapter -> @Controller Method
              |
              AOP Advice (Around/Before/After)
              |
              actual method body
    |
    v
Interceptor.postHandle()
    |
    v
ViewResolver / MessageConverter
    |
    v
Interceptor.afterCompletion()
    |
    v
Filter (doFilter chain continues)
    |
    v
HTTP Response
```

---

## 二、三者核心对比

| 维度 | Filter（过滤器）| Interceptor（拦截器）| AOP（切面）|
|------|--------------|---------------------|-----------|
| 所属规范 | Servlet 规范 | Spring MVC | Spring AOP |
| 作用层级 | Servlet 容器层 | DispatcherServlet 层 | Spring Bean 方法层 |
| 触发时机 | 进入 DispatcherServlet 之前 | Handler 执行前后 | 方法调用时 |
| 能否访问 Spring Bean | ✅（Spring Boot 中可以注入）| ✅ | ✅ |
| 能否访问 @Controller 方法参数 | ❌ | ✅（HandlerMethod）| ✅ |
| 能否访问返回值 | ❌（只能包装响应流）| ✅（postHandle 中 ModelAndView）| ✅（@AfterReturning）|
| 能否修改请求/响应 Body | ✅（包装 Request/Response）| ⚠️ 困难 | ❌ |
| 拦截非 Spring MVC 请求 | ✅ | ❌ | ❌ |
| 拦截范围 | URL 路径 | URL 路径 | 任意 Spring Bean 方法（注解/切点表达式）|
| 是否受 AOP 代理影响 | ❌ | ❌ | ✅（同类调用无效）|

---

## 三、Filter 详解与实战

### 3.1 适用场景

- 请求/响应内容包装（读取 Body 不丢失流、压缩/解压）
- 跨域处理（CORS）
- 安全过滤（SQL 注入检测、XSS 过滤）
- 全局日志追踪 ID 注入（在 Filter 最早处注入 TraceId）

### 3.2 实战：基于 Filter 注入请求追踪 ID

```java
// Spring Boot 3.2 + JDK 17
@Component
@Order(1) // 最高优先级
public class TraceIdFilter extends OncePerRequestFilter {

    private static final String TRACE_ID_HEADER = "X-Trace-Id";

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain)
            throws ServletException, IOException {
        // 从请求头获取，或生成新的 TraceId
        String traceId = Optional.ofNullable(request.getHeader(TRACE_ID_HEADER))
            .filter(StringUtils::hasText)
            .orElse(UUID.randomUUID().toString().replace("-", "").substring(0, 16));

        // 存入 MDC（Mapped Diagnostic Context），日志框架自动携带
        MDC.put("traceId", traceId);
        // 写入响应头，便于客户端追踪
        response.setHeader(TRACE_ID_HEADER, traceId);

        try {
            filterChain.doFilter(request, response);
        } finally {
            MDC.clear(); // 必须清理，防止线程池复用时数据污染
        }
    }
}
```

---

## 四、Interceptor 详解与实战

### 4.1 适用场景

- 登录校验（基于 Session 或 Token，能直接访问 Spring Bean）
- 接口权限控制（结合自定义注解，能读取 HandlerMethod 上的注解）
- 请求耗时统计（preHandle 记录开始时间，afterCompletion 计算耗时）
- 国际化处理

### 4.2 实战：基于注解的接口权限拦截器

```java
// Spring Boot 3.2 + JDK 17
// 自定义权限注解
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface RequirePermission {
    String value(); // 权限标识，如 "order:read"
}

// 拦截器实现
@Component
public class PermissionInterceptor implements HandlerInterceptor {

    @Autowired
    private PermissionService permissionService;

    @Override
    public boolean preHandle(HttpServletRequest request,
                             HttpServletResponse response,
                             Object handler) throws Exception {
        if (!(handler instanceof HandlerMethod handlerMethod)) {
            return true; // 非 Controller 方法直接放行
        }
        RequirePermission annotation = handlerMethod.getMethodAnnotation(RequirePermission.class);
        if (annotation == null) {
            return true; // 未标注权限注解，放行
        }
        String userId = (String) request.getSession().getAttribute("userId");
        if (!permissionService.hasPermission(userId, annotation.value())) {
            response.setStatus(HttpServletResponse.SC_FORBIDDEN);
            response.getWriter().write("{\"code\":403,\"msg\":\"No permission\"}");
            return false; // 拦截
        }
        return true;
    }
}

// 注册拦截器
@Configuration
public class WebMvcConfig implements WebMvcConfigurer {
    @Autowired
    private PermissionInterceptor permissionInterceptor;

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(permissionInterceptor)
            .addPathPatterns("/api/**")
            .excludePathPatterns("/api/login", "/api/public/**");
    }
}
```

---

## 五、选型指南

| 需求场景 | 推荐方案 | 原因 |
|---------|---------|------|
| 全局请求/响应 Body 包装 | Filter | 最早介入，能包装流 |
| 跨域（CORS）| Filter 或 `@CrossOrigin` | Servlet 层处理最彻底 |
| TraceId / 请求 ID 注入 | Filter | 最早介入 MDC，日志全程携带 |
| Token 解析、登录校验 | Interceptor | 能访问 Spring Bean，能读 HandlerMethod 注解 |
| 接口级权限注解（`@RequirePermission`）| Interceptor | 能访问 HandlerMethod，读方法注解最方便 |
| 方法调用耗时 / 缓存 / 事务 | AOP | 不限 URL，任意 Spring Bean 方法均可 |
| 只有接口没有 URL 的 Service 方法 | AOP | Filter/Interceptor 无法拦截非 HTTP 请求 |
| 异步方法增强 | AOP | 但需注意同类调用失效问题（见 [SB-06](posts/2024-08-22-spring-aop-proxy.md)）|

---

## 六、踩坑总结

❌ **在 Filter 中注入 Spring Bean 失败（NullPointerException），原因是 Filter 在 Spring IoC 容器初始化前被 Tomcat 创建**

✅ Spring Boot 中通过 `@Component` 注册的 Filter 是由 Spring 管理的，可以正常注入。问题通常发生在通过 `web.xml` 或 `@WebFilter` + `@ServletComponentScan` 方式注册的 Filter——此时 Filter 由 Servlet 容器创建，不走 Spring IoC。解决方案：改用 `FilterRegistrationBean` 注册 Filter，Spring Boot 会在 IoC 初始化后注册，保证注入可用。

❌ **在 Interceptor 中修改响应 JSON，但在 `postHandle` 中直接 `response.getWriter().write()` 导致响应乱码或被 Jackson 覆盖**

✅ `postHandle` 在 `HandlerAdapter.handle()` 之后执行，此时 `@RestController` 的返回值已经被 `HttpMessageConverter` 序列化并写入响应流。`postHandle` 中再写入会追加内容或报"already committed"。修改响应 Body 应在 Filter 层用 `ContentCachingResponseWrapper` 包装。

---

## 七、文章小结

- Filter 处于 Servlet 容器层，最先介入请求，适合跨域、Body 包装、TraceId 注入等通用处理
- Interceptor 处于 DispatcherServlet 层，能访问 HandlerMethod 和 Spring Bean，适合登录校验、权限拦截
- AOP 处于 Bean 方法层，不受 URL 限制，适合事务、缓存、日志、耗时统计等横切业务逻辑
- 三者执行顺序：Filter 包裹 DispatcherServlet，Interceptor 包裹 Handler，AOP 包裹方法调用
- 同类方法调用时 AOP 不生效，这是 Spring AOP 基于代理实现的固有限制

---

## 八、思考题

1. `Spring Security` 的认证授权是用 Filter 实现的（`SecurityFilterChain`），而不是用 Interceptor——这个设计决策背后的原因是什么？

2. 如果你需要同时用 Filter 和 AOP 对同一个接口进行日志记录，两者各自能获取到什么信息？应该如何分工？

---

## 参考资料

> 1. [Spring MVC 官方文档 - Interceptors](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-config/interceptors.html)
> 2. [Java EE Servlet 规范 - Filter](https://jakarta.ee/specifications/servlet/6.0/)
> 3. [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> 4. [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
