# Spring Security 认证与授权：从原理到生产落地

<div class="post-meta">📅 2024-12-23 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

Spring Security 是 Spring 生态中最复杂的模块之一，初学者往往被繁琐的配置劝退。但它的核心模型非常清晰：**一条 Filter 链，认证+授权两件事**。理解这条主线，再结合 JWT 无状态认证的实战，能覆盖大多数企业项目需求。

---

## 一、背景：认证 vs 授权

- **认证（Authentication）**：你是谁？验证身份（用户名/密码/Token）
- **授权（Authorization）**：你能做什么？验证权限（角色/资源/操作）

Spring Security 通过一条 **Filter 链**（SecurityFilterChain）依次处理这两件事：

```
HTTP 请求
    ↓
UsernamePasswordAuthenticationFilter（认证）
    ↓
FilterSecurityInterceptor（授权）
    ↓
Controller
```
---

## 二、核心架构：Filter 链与 SecurityContext

```
SecurityFilterChain（15+ 个 Filter 组成的链）
    ↓
AuthenticationManager.authenticate(token)
    ↓
AuthenticationProvider（支持多种认证方式）
    ↓
UserDetailsService.loadUserByUsername()  ← 开发者实现
    ↓
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

## 六、总结与延伸

**核心要点**：
- Spring Security 本质是一条 Filter 链，SecurityContextHolder（ThreadLocal）传递认证信息
- JWT 无状态认证适合 REST API 和微服务，Session 认证适合传统 Web
- @PreAuthorize 实现细粒度方法级权限控制
- 密码必须使用 BCrypt 等自适应哈希算法加密存储

**延伸阅读方向**：
- OAuth2 / OIDC：spring-security-oauth2-authorization-server，实现企业级 SSO
- Spring Security 与 Keycloak：外部 IdP 集成，统一身份管理
- RBAC 权限模型设计：角色-资源-操作的数据库建模与 Spring Security 集成
- Refresh Token 机制：无感刷新 Token 的前后端协作方案
