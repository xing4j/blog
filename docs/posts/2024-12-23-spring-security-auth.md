# Spring Security 认证与授权：从原理到生产落地

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
> - [SB-12 Filter、Interceptor、AOP 三者对比与选型](posts/2026-05-24-spring-filter-interceptor-aop.md)
> - [SB-13 Spring 事件驱动：ApplicationEvent 与监听器](posts/2026-05-24-spring-events.md)
> - [SB-14 Spring @Async 异步编程：原理与线程池配置](posts/2026-05-24-spring-async.md)
> - [SB-15 Spring 扩展点：BPP、BFPP 与 ImportSelector](posts/2026-05-24-spring-extension-points.md)
> - [SB-16 Spring Boot 全局异常处理与参数校验](posts/2026-05-24-spring-exception-handler.md)
> - [SB-17 Spring Boot 多数据源：动态路由与跨库事务](posts/2026-05-24-spring-boot-multi-datasource.md)
> - [SB-18 Spring Boot Actuator：健康检查与自定义端点](posts/2026-05-24-spring-boot-actuator.md)
> - [SB-19 Spring Boot 自定义 Starter：从设计到发布](posts/2026-05-24-spring-boot-custom-starter.md)
> - 👉 **SB-20 Spring Security 认证授权完整流程（本文）**
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](posts/2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](posts/2026-05-24-spring-boot-testing.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 20 分钟｜**分类**：Spring 生态

<div class="post-meta">📅 2024-12-23 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

## 导读

Spring Security 是 Spring 生态中最复杂的模块之一，初学者往往被繁琐的配置劝退。但它的核心模型非常清晰：**一条 Filter 链，认证+授权两件事**。理解这条主线，再结合 JWT 无状态认证的实战，能覆盖大多数企业项目需求。

---

## 一、背景：认证 vs 授权

- **认证（Authentication）**：你是谁？验证身份（用户名/密码/Token）
- **授权（Authorization）**：你能做什么？验证权限（角色/资源/操作）

Spring Security 通过一条 **Filter 链**（SecurityFilterChain）依次处理这两件事：

```
HTTP 请求
    v
UsernamePasswordAuthenticationFilter（认证）
    v
FilterSecurityInterceptor（授权）
    v
Controller
```
---

## 二、核心架构：Filter 链与 SecurityContext

```
SecurityFilterChain（15+ 个 Filter 组成的链）
    v
AuthenticationManager.authenticate(token)
    v
AuthenticationProvider（支持多种认证方式）
    v
UserDetailsService.loadUserByUsername()  <- 开发者实现
    v
返回 Authentication 对象，存入 SecurityContextHolder（ThreadLocal）
```
**核心类关系**：
- SecurityContextHolder：存储当前线程的安全上下文（ThreadLocal）
- Authentication：代表认证主体，包含 principal（用户）、credentials（凭证）、authorities（权限）
- UserDetails：用户信息接口，开发者实现
- UserDetailsService：根据用户名加载用户信息，开发者实现

---

## 三、JWT 无状态认证实战

Session 认证需要服务端存储状态，不适合分布式系统。JWT（JSON Web Token）将用户信息编码在 Token 中，服务端无需存储状态。

### 3.1 JWT 结构

```
eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyMSIsInJvbGVzIjpbIlJPTEVfVVNFUiJdLCJleHAiOjE2...}
    Header（算法）        Payload（用户信息/过期时间）        Signature（签名）
```
### 3.2 完整配置

```java
@Configuration
@EnableWebSecurity
@EnableMethodSecurity  // 启用方法级权限注解（@PreAuthorize 等）
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http, JwtAuthFilter jwtAuthFilter) throws Exception {
        http
            .csrf(csrf -> csrf.disable())                // REST API 禁用 CSRF
            .sessionManagement(sm -> sm.sessionCreationPolicy(SessionCreationPolicy.STATELESS))  // 无状态
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/auth/**").permitAll()   // 登录/注册接口放行
                .requestMatchers("/api/admin/**").hasRole("ADMIN")
                .anyRequest().authenticated()
            )
            .addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter.class);  // 加入 JWT 过滤器
        return http.build();
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();  // 密码加密
    }
}
```
### 3.3 JWT 过滤器

```java
@Component
@RequiredArgsConstructor
public class JwtAuthFilter extends OncePerRequestFilter {
    private final JwtUtils jwtUtils;
    private final UserDetailsService userDetailsService;

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                     HttpServletResponse response,
                                     FilterChain filterChain) throws ServletException, IOException {
        String authHeader = request.getHeader("Authorization");

        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            filterChain.doFilter(request, response);
            return;
        }

        String token = authHeader.substring(7);

        try {
            String username = jwtUtils.extractUsername(token);
            if (username != null && SecurityContextHolder.getContext().getAuthentication() == null) {
                UserDetails userDetails = userDetailsService.loadUserByUsername(username);
                if (jwtUtils.validateToken(token, userDetails)) {
                    UsernamePasswordAuthenticationToken authToken =
                        new UsernamePasswordAuthenticationToken(userDetails, null, userDetails.getAuthorities());
                    authToken.setDetails(new WebAuthenticationDetailsSource().buildDetails(request));
                    SecurityContextHolder.getContext().setAuthentication(authToken);
                }
            }
        } catch (JwtException e) {
            // Token 无效，不设置 SecurityContext，后续过滤器会拒绝请求
        }

        filterChain.doFilter(request, response);
    }
}
```
### 3.4 登录接口

```java
@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {
    private final AuthenticationManager authenticationManager;
    private final JwtUtils jwtUtils;

    @PostMapping("/login")
    public ResponseEntity<TokenResponse> login(@RequestBody LoginRequest request) {
        // 触发 Spring Security 认证流程
        Authentication authentication = authenticationManager.authenticate(
            new UsernamePasswordAuthenticationToken(request.getUsername(), request.getPassword())
        );

        UserDetails userDetails = (UserDetails) authentication.getPrincipal();
        String token = jwtUtils.generateToken(userDetails);
        return ResponseEntity.ok(new TokenResponse(token));
    }
}
```
### 3.5 方法级权限控制

```java
@Service
public class UserService {
    // 需要 ADMIN 角色
    @PreAuthorize("hasRole('ADMIN')")
    public void deleteUser(Long userId) { ... }

    // 需要 USER 角色，且只能操作自己的数据
    @PreAuthorize("hasRole('USER') and #userId == authentication.principal.id")
    public UserVO getUser(Long userId) { ... }

    // 需要特定权限
    @PreAuthorize("hasAuthority('user:write')")
    public void updateUser(User user) { ... }
}
```
---

## 四、对比：Session 认证 vs JWT 认证

| 特性 | Session 认证 | JWT 认证 |
|------|------------|---------|
| 状态存储 | 服务端（Redis/内存）| 客户端（Token 自包含）|
| 扩展性 | 需要共享 Session 存储 | 无状态，天然水平扩展 |
| Token 撤销 | 简单（删 Session）| 复杂（需维护黑名单或短期 Token）|
| 性能 | 每次请求查 Session 存储 | 验证签名，无 IO |
| 安全性 | CSRF 风险（可防） | XSS 风险（Token 泄露）|
| 适用场景 | 传统 Web 应用 | REST API、微服务、移动端 |

---

## 五、常见坑点与最佳实践

### 坑 1：JWT 无法主动失效

```
问题：用户退出登录，但 Token 仍有效期内可用
解决方案：
- 短 Token 有效期（15分钟）+ Refresh Token 刷新机制
- 维护 Token 黑名单（Redis Set 存储已退出的 Token JTI）
- 修改密码时，用密码 Hash 作为 JWT Secret 的一部分（密码改变=旧 Token 自动失效）
```
### 坑 2：密码明文存储

```java
// ❌ 绝对禁止明文存储密码
user.setPassword(password);

// ✅ BCrypt 加密存储（每次 hash 值不同，防彩虹表攻击）
user.setPassword(passwordEncoder.encode(password));

// ✅ 验证时
boolean match = passwordEncoder.matches(rawPassword, encodedPassword);
```
### 坑 3：hasRole vs hasAuthority 的区别

```java
// hasRole("ADMIN") 等价于 hasAuthority("ROLE_ADMIN")
// Spring Security 会自动在 role 前加 ROLE_ 前缀

// 所以数据库存 "ROLE_ADMIN"，用 hasRole("ADMIN") 检查
// 存 "user:write"，用 hasAuthority("user:write") 检查
```
---

## 六、踩坑总结

❌ **JWT Token 失效（用户修改密码）后，旧 Token 仍可访问接口**

✅ JWT 是无状态的，服务端没有存储 Token，无法主动使之失效。生产方案：①维护 Redis Token 黑名单，注销时将 Token 的 JTI（JWT ID）写入黑名单，每次请求检查；②将密码 Hash 的一部分作为签名密钥，密码修改后旧 Token 签名验证失败；③设置较短的 Access Token 有效期（15分钟）+ Refresh Token 刷新机制。

❌ **`hasRole("ADMIN")` 权限判断不生效，数据库中角色存的是 `ROLE_ADMIN` 也不行**

✅ 数据库中存储的是 `ROLE_ADMIN`，加载到 `UserDetails.getAuthorities()` 时必须保留 `ROLE_` 前缀。`hasRole("ADMIN")` 等价于 `hasAuthority("ROLE_ADMIN")`，Spring Security 在 `hasRole` 调用时自动补 `ROLE_` 前缀。如果调用 `hasAuthority("ADMIN")`（不加前缀）则要求数据库存的就是 `ADMIN`。统一约定：角色用 `ROLE_` 前缀存储，代码用 `hasRole`；权限（如 `user:read`）不加前缀，代码用 `hasAuthority`。

---

## 七、文章小结

- Spring Security 本质是一条 Filter 链，核心流程：认证（Filter 验证 Token）→ 存入 SecurityContextHolder（ThreadLocal）→ 授权（检查权限）
- JWT 无状态认证适合 REST API 和微服务，Token 失效需要引入黑名单或短有效期+刷新机制
- `@PreAuthorize` 实现方法级细粒度权限控制，支持 SpEL 表达式（如 `@PreAuthorize("@permissionService.hasPermission(#id)")`）
- 密码必须使用 BCrypt 等自适应哈希算法（`PasswordEncoder`），禁止明文存储
- `hasRole("X")` 自动补 `ROLE_` 前缀，`hasAuthority("X")` 精确匹配，两者适用于不同的权限模型

---

## 八、思考题

1. 微服务场景下，多个服务都需要验证 JWT Token，如何避免每个服务都重复实现解析验证逻辑？网关层统一验证有什么优缺点？

2. `SecurityContextHolder` 默认使用 `ThreadLocal` 存储认证信息，当使用 `@Async` 异步方法时，子线程能获取到当前用户信息吗？如何解决？

---

## 参考资料

> 1. [Spring Security 官方文档](https://docs.spring.io/spring-security/reference/)
> 2. [OWASP - JSON Web Token (JWT) Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html)
> 3. [SB-12 Filter、Interceptor、AOP 三者对比与选型](posts/2026-05-24-spring-filter-interceptor-aop.md)
> 4. [2025-11-20 OWASP Top 10 安全漏洞深度解析](posts/2025-11-20-owasp-top10.md)
