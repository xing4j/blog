# Spring Security 认证授权全流程实战

<div class="post-meta">📅 2024-12-23 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring Security</span></div>

Spring Security 认证授权流程复杂，本文以 JWT 实战为主线，串联完整的认证链路，并实现方法级权限控制和自定义异常处理。

---

## 一、认证核心流程

```
HTTP 请求
    │
    ▼
FilterChainProxy（Security 过滤器链）
    │
    ├─ UsernamePasswordAuthenticationFilter（表单/JSON 登录）
    │       │ 提取用户名密码，构造 UsernamePasswordAuthenticationToken
    │       ▼
    │  AuthenticationManager（ProviderManager）
    │       │
    │       └─ DaoAuthenticationProvider
    │               │ loadUserByUsername()
    │               ▼
    │          UserDetailsService ← 你实现这个接口
    │               │ 返回 UserDetails（含密码、权限）
    │               ▼
    │          密码比对（PasswordEncoder）
    │               │
    │       认证成功 → SecurityContextHolder.setContext()
    │       认证失败 → AuthenticationFailureHandler
    │
    ├─ JwtAuthenticationFilter（自定义，验证 JWT Token）
    │
    └─ ExceptionTranslationFilter（统一异常处理）
```

---

## 二、项目依赖

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-security</artifactId>
</dependency>
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-api</artifactId>
    <version>0.11.5</version>
</dependency>
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-impl</artifactId>
    <version>0.11.5</version>
    <scope>runtime</scope>
</dependency>
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-jackson</artifactId>
    <version>0.11.5</version>
    <scope>runtime</scope>
</dependency>
```

---

## 三、UserDetailsService 实现

```java
@Service
@RequiredArgsConstructor
public class UserDetailsServiceImpl implements UserDetailsService {

    private final UserRepository userRepository;

    @Override
    public UserDetails loadUserByUsername(String username) throws UsernameNotFoundException {
        User user = userRepository.findByUsername(username)
            .orElseThrow(() -> new UsernameNotFoundException("用户不存在: " + username));

        // 将用户权限字符串转换为 GrantedAuthority
        List<GrantedAuthority> authorities = user.getRoles().stream()
            .map(role -> new SimpleGrantedAuthority("ROLE_" + role.getName()))
            .collect(Collectors.toList());

        return org.springframework.security.core.userdetails.User.builder()
            .username(user.getUsername())
            .password(user.getPassword()) // BCrypt 加密后的密码
            .authorities(authorities)
            .accountLocked(user.isLocked())
            .build();
    }
}
```

---

## 四、JWT 工具类

```java
@Component
public class JwtTokenProvider {

    @Value("${jwt.secret}")
    private String secret;

    @Value("${jwt.expiration:86400000}") // 默认1天
    private long expiration;

    private SecretKey getSigningKey() {
        byte[] keyBytes = Decoders.BASE64.decode(secret);
        return Keys.hmacShaKeyFor(keyBytes);
    }

    /** 生成 Token */
    public String generateToken(UserDetails userDetails) {
        Map<String, Object> claims = new HashMap<>();
        claims.put("roles", userDetails.getAuthorities().stream()
            .map(GrantedAuthority::getAuthority)
            .collect(Collectors.toList()));

        return Jwts.builder()
            .setClaims(claims)
            .setSubject(userDetails.getUsername())
            .setIssuedAt(new Date())
            .setExpiration(new Date(System.currentTimeMillis() + expiration))
            .signWith(getSigningKey(), SignatureAlgorithm.HS256)
            .compact();
    }

    /** 解析 Token */
    public Claims parseToken(String token) {
        return Jwts.parserBuilder()
            .setSigningKey(getSigningKey())
            .build()
            .parseClaimsJws(token)
            .getBody();
    }

    /** 验证 Token 有效性 */
    public boolean validateToken(String token) {
        try {
            parseToken(token);
            return true;
        } catch (JwtException | IllegalArgumentException e) {
            return false;
        }
    }

    public String getUsernameFromToken(String token) {
        return parseToken(token).getSubject();
    }
}
```

---

## 五、JWT 认证过滤器

```java
@Component
@RequiredArgsConstructor
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    private final JwtTokenProvider jwtTokenProvider;
    private final UserDetailsServiceImpl userDetailsService;

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain)
            throws ServletException, IOException {

        String token = extractToken(request);

        if (token != null && jwtTokenProvider.validateToken(token)) {
            String username = jwtTokenProvider.getUsernameFromToken(token);
            UserDetails userDetails = userDetailsService.loadUserByUsername(username);

            UsernamePasswordAuthenticationToken authentication =
                new UsernamePasswordAuthenticationToken(
                    userDetails, null, userDetails.getAuthorities()
                );
            authentication.setDetails(new WebAuthenticationDetailsSource().buildDetails(request));

            // 设置到 SecurityContext，后续过滤器可读取
            SecurityContextHolder.getContext().setAuthentication(authentication);
        }

        filterChain.doFilter(request, response);
    }

    private String extractToken(HttpServletRequest request) {
        String bearerToken = request.getHeader("Authorization");
        if (StringUtils.hasText(bearerToken) && bearerToken.startsWith("Bearer ")) {
            return bearerToken.substring(7);
        }
        return null;
    }
}
```

---

## 六、Security 配置类

```java
@Configuration
@EnableWebSecurity
@EnableMethodSecurity(prePostEnabled = true) // 开启方法级权限
@RequiredArgsConstructor
public class SecurityConfig {

    private final JwtAuthenticationFilter jwtAuthFilter;
    private final UserDetailsServiceImpl userDetailsService;
    private final JwtAuthEntryPoint jwtAuthEntryPoint;
    private final JwtAccessDeniedHandler jwtAccessDeniedHandler;

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .sessionManagement(session ->
                session.sessionCreationPolicy(SessionCreationPolicy.STATELESS)) // 无状态

            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/auth/**").permitAll()  // 登录注册放行
                .requestMatchers("/api/public/**").permitAll()
                .requestMatchers("/actuator/health").permitAll()
                .anyRequest().authenticated()
            )

            .exceptionHandling(ex -> ex
                .authenticationEntryPoint(jwtAuthEntryPoint)     // 未认证处理
                .accessDeniedHandler(jwtAccessDeniedHandler)      // 无权限处理
            )

            // JWT 过滤器加在 UsernamePasswordAuthenticationFilter 之前
            .addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter.class);

        return http.build();
    }

    @Bean
    public AuthenticationManager authenticationManager(
            AuthenticationConfiguration config) throws Exception {
        return config.getAuthenticationManager();
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }
}
```

---

## 七、登录接口

```java
@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {

    private final AuthenticationManager authenticationManager;
    private final JwtTokenProvider jwtTokenProvider;
    private final UserDetailsServiceImpl userDetailsService;

    @PostMapping("/login")
    public ResponseEntity<LoginResponse> login(@RequestBody @Valid LoginRequest request) {
        // 触发认证（会调用 UserDetailsService.loadUserByUsername）
        Authentication authentication = authenticationManager.authenticate(
            new UsernamePasswordAuthenticationToken(request.getUsername(), request.getPassword())
        );

        UserDetails userDetails = (UserDetails) authentication.getPrincipal();
        String token = jwtTokenProvider.generateToken(userDetails);

        return ResponseEntity.ok(new LoginResponse(token));
    }
}
```

---

## 八、方法级权限控制

```java
@RestController
@RequestMapping("/api/users")
@RequiredArgsConstructor
public class UserController {

    private final UserService userService;

    // 需要 ADMIN 角色
    @GetMapping
    @PreAuthorize("hasRole('ADMIN')")
    public List<User> listAll() {
        return userService.findAll();
    }

    // 需要 ADMIN 角色，或者当前用户只能查自己
    @GetMapping("/{id}")
    @PreAuthorize("hasRole('ADMIN') or #id == authentication.principal.id")
    public User getById(@PathVariable Long id) {
        return userService.findById(id);
    }

    // 需要特定权限（非角色）
    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('user:delete')")
    public void delete(@PathVariable Long id) {
        userService.delete(id);
    }

    // 返回结果过滤
    @GetMapping("/my-profile")
    @PostAuthorize("returnObject.username == authentication.name")
    public User getMyProfile() {
        return userService.findCurrentUser();
    }
}
```

---

## 九、自定义认证失败处理

```java
// 未认证（401）
@Component
public class JwtAuthEntryPoint implements AuthenticationEntryPoint {

    @Override
    public void commence(HttpServletRequest request, HttpServletResponse response,
                         AuthenticationException e) throws IOException {
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.getWriter().write("""
            {"code": 401, "message": "未认证，请先登录"}
            """);
    }
}

// 已认证但无权限（403）
@Component
public class JwtAccessDeniedHandler implements AccessDeniedHandler {

    @Override
    public void handle(HttpServletRequest request, HttpServletResponse response,
                       AccessDeniedException e) throws IOException {
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setStatus(HttpServletResponse.SC_FORBIDDEN);
        response.getWriter().write("""
            {"code": 403, "message": "权限不足"}
            """);
    }
}
```

---

## 十、总结

| 组件 | 职责 |
|------|------|
| `UsernamePasswordAuthenticationFilter` | 提取凭证，触发认证流程 |
| `AuthenticationManager` | 委托给 `AuthenticationProvider` 进行认证 |
| `DaoAuthenticationProvider` | 调用 `UserDetailsService` + 密码比对 |
| `UserDetailsService` | 从数据库加载用户信息 |
| `JwtAuthenticationFilter` | 无状态请求中解析 JWT，恢复认证状态 |
| `SecurityContextHolder` | 存储当前认证信息（ThreadLocal） |
| `@PreAuthorize` | 方法级权限控制，SpEL 表达式 |
| `AuthenticationEntryPoint` | 未认证时的 401 响应 |
| `AccessDeniedHandler` | 已认证但无权限时的 403 响应 |
