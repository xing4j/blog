# SC-08 微服务安全：Gateway + JWT 统一鉴权方案

> 📚 **本文属于「Spring Cloud 微服务实战」系列**
> - [SC-01 Spring Cloud 微服务全景：架构演进与组件选型](2025-06-27-spring-cloud-overview.md)
> - [SC-02 Nacos 服务注册与配置中心实战](2025-02-15-nacos-registry-config.md)
> - [SC-03 Spring Cloud Gateway：路由、过滤器与灰度发布](2026-05-26-spring-cloud-gateway.md)
> - [SC-04 OpenFeign 深度实战：声明式调用、拦截器与熔断](2025-09-06-openfeign-timeout-retry.md)
> - [SC-05 Spring Cloud LoadBalancer：负载均衡原理与自定义策略](2026-05-26-spring-cloud-loadbalancer.md)
> - [SC-06 Sentinel 流量防护：限流、熔断与热点规则](2025-04-26-sentinel-rate-limit.md)
> - [SC-07 分布式链路追踪：Micrometer Tracing + SkyWalking 实战](2026-05-26-spring-cloud-tracing.md)
> - 👉 **SC-08 微服务安全：Gateway + JWT 统一鉴权方案（本文）**
> - [SC-09 Seata 分布式事务：AT/TCC/Saga 三模式对比实战](2025-01-11-seata-distributed-transaction.md)
> - [SC-10 Nacos 配置治理进阶：多环境、灰度与动态刷新](2026-05-26-nacos-config-advanced.md)
> - [SC-11 微服务可观测性：Actuator + Prometheus + Grafana](2026-05-26-spring-cloud-observability.md)
> - [SC-12 微服务最佳实践：接口幂等、版本兼容与蓝绿部署](2026-05-26-microservice-best-practices.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 25 分钟｜**分类**：微服务

## 导读

微服务拆分后，每个服务都独立部署，如何避免每个服务都实现一套登录逻辑？如何防止绕过 Gateway 直接访问内网服务？本文给出一套完整的 Gateway + Auth Service + JWT 统一鉴权方案：网关统一认证、服务间信任调用、内网防绕行，覆盖从登录到权限校验的完整链路。

---

## 一、微服务安全模型

### 1.1 整体架构

```
External Client
      |
      | (携带 JWT Token)
      v
+------------------+
|   API Gateway    |  <- 统一认证：验证 JWT，提取用户信息写入 Header
+--------+---------+
         |  (内网调用，携带 X-User-Id / X-User-Roles Header)
    +---------+---------+
    |         |         |
 Order     Payment    User
 Service   Service    Service
    |
    | (OpenFeign 内部调用)
    v
Inventory Service   <- 验证内部调用签名（防绕行）
```

**分层职责**：
- **Auth Service（认证服务）**：负责登录、颁发 JWT、刷新 Token
- **API Gateway**：验证 JWT 有效性，提取用户标识转发给下游，**不做权限校验**
- **业务服务**：从请求头读取用户信息，做业务级权限判断（如"只能查自己的订单"）
- **内部服务**：验证内部调用签名，拒绝来自外网的直接请求

### 1.2 JWT 结构回顾

JWT（JSON Web Token）由三部分组成，`.` 分隔：

```
Header.Payload.Signature

Header:  {"alg":"HS256","typ":"JWT"}
Payload: {"sub":"user123","roles":"admin,user","exp":1748000000,"iat":1747913600}
Signature: HMACSHA256(base64(Header) + "." + base64(Payload), secret)
```

**注意**：Payload 是 Base64 编码，**不是加密**，不要存储敏感信息（密码、手机号等）。

---

## 二、Auth Service 实现

### 2.1 依赖

```xml
<!-- auth-service/pom.xml  Spring Boot 3.2 -->
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-api</artifactId>
    <version>0.12.5</version>
</dependency>
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-impl</artifactId>
    <version>0.12.5</version>
    <scope>runtime</scope>
</dependency>
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-jackson</artifactId>
    <version>0.12.5</version>
    <scope>runtime</scope>
</dependency>
```

### 2.2 JWT 工具类

```java
// JwtTokenProvider.java  JDK 17 + jjwt 0.12.x
@Component
public class JwtTokenProvider {

    // 从配置读取，生产环境通过 Nacos 或 Vault 注入，不硬编码
    @Value("${jwt.secret}")
    private String jwtSecret;

    @Value("${jwt.access-token-expiry:3600}")   // 默认 1 小时
    private long accessTokenExpirySeconds;

    @Value("${jwt.refresh-token-expiry:604800}") // 默认 7 天
    private long refreshTokenExpirySeconds;

    private SecretKey getSigningKey() {
        return Keys.hmacShaKeyFor(
            Decoders.BASE64.decode(jwtSecret));  // secret 需 Base64 编码
    }

    /** 生成 Access Token */
    public String generateAccessToken(String userId, List<String> roles) {
        return Jwts.builder()
            .subject(userId)
            .claim("roles", String.join(",", roles))
            .claim("type", "access")
            .issuedAt(new Date())
            .expiration(new Date(System.currentTimeMillis()
                + accessTokenExpirySeconds * 1000))
            .signWith(getSigningKey())
            .compact();
    }

    /** 生成 Refresh Token（不含 roles，仅用于换取新 Access Token） */
    public String generateRefreshToken(String userId) {
        return Jwts.builder()
            .subject(userId)
            .claim("type", "refresh")
            .issuedAt(new Date())
            .expiration(new Date(System.currentTimeMillis()
                + refreshTokenExpirySeconds * 1000))
            .signWith(getSigningKey())
            .compact();
    }

    /** 验证并解析 Token，失败抛出 JwtException */
    public Claims parseToken(String token) {
        return Jwts.parser()
            .verifyWith(getSigningKey())
            .build()
            .parseSignedClaims(token)
            .getPayload();
    }
}
```

### 2.3 登录接口

```java
// AuthController.java
@RestController
@RequestMapping("/auth")
public class AuthController {

    @Autowired
    private AuthService authService;

    @PostMapping("/login")
    public ResponseEntity<TokenResponse> login(@RequestBody @Valid LoginRequest req) {
        // 验证用户名密码（从数据库查询，密码 BCrypt 比对）
        UserDetails user = authService.authenticate(req.getUsername(), req.getPassword());

        String accessToken = jwtProvider.generateAccessToken(
            user.getId(), user.getRoles());
        String refreshToken = jwtProvider.generateRefreshToken(user.getId());

        // Refresh Token 存 Redis，支持主动失效
        redisTemplate.opsForValue().set(
            "refresh_token:" + user.getId(), refreshToken,
            7, TimeUnit.DAYS);

        return ResponseEntity.ok(new TokenResponse(accessToken, refreshToken));
    }

    @PostMapping("/refresh")
    public ResponseEntity<TokenResponse> refresh(
            @RequestHeader("X-Refresh-Token") String refreshToken) {
        Claims claims = jwtProvider.parseToken(refreshToken);

        // 验证 Redis 中的 Refresh Token 是否有效（防止已注销的 Token 被复用）
        String stored = redisTemplate.opsForValue()
            .get("refresh_token:" + claims.getSubject());
        if (!refreshToken.equals(stored)) {
            throw new UnauthorizedException("Refresh token invalid or expired");
        }

        // 重新颁发 Access Token
        List<String> roles = userService.getRoles(claims.getSubject());
        String newAccessToken = jwtProvider.generateAccessToken(
            claims.getSubject(), roles);

        return ResponseEntity.ok(new TokenResponse(newAccessToken, refreshToken));
    }

    @PostMapping("/logout")
    public ResponseEntity<Void> logout(
            @RequestHeader(HttpHeaders.AUTHORIZATION) String authorization) {
        String token = authorization.substring(7);
        Claims claims = jwtProvider.parseToken(token);

        // 删除 Refresh Token，使其失效
        redisTemplate.delete("refresh_token:" + claims.getSubject());

        // 将 Access Token 加入黑名单（剩余有效期内拦截）
        long remaining = claims.getExpiration().getTime() - System.currentTimeMillis();
        if (remaining > 0) {
            redisTemplate.opsForValue().set(
                "token_blacklist:" + token, "1",
                remaining, TimeUnit.MILLISECONDS);
        }
        return ResponseEntity.noContent().build();
    }
}
```

---

## 三、Gateway 统一鉴权过滤器

```java
// AuthGlobalFilter.java  在 Gateway 中统一验证 JWT
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 20)
public class AuthGlobalFilter implements GlobalFilter {

    private static final AntPathMatcher PATH_MATCHER = new AntPathMatcher();

    // 白名单：无需鉴权的路径
    private static final List<String> WHITE_LIST = List.of(
        "/api/auth/login",
        "/api/auth/register",
        "/api/auth/refresh",
        "/api/public/**",
        "/actuator/**",
        "/v3/api-docs/**"
    );

    @Autowired
    private JwtTokenProvider jwtProvider;

    @Autowired
    private StringRedisTemplate redisTemplate;

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        String path = exchange.getRequest().getPath().value();

        // 1. 白名单直接放行
        if (WHITE_LIST.stream().anyMatch(p -> PATH_MATCHER.match(p, path))) {
            return chain.filter(exchange);
        }

        // 2. 提取 Authorization Header
        String authorization = exchange.getRequest().getHeaders()
            .getFirst(HttpHeaders.AUTHORIZATION);
        if (authorization == null || !authorization.startsWith("Bearer ")) {
            return buildErrorResponse(exchange, HttpStatus.UNAUTHORIZED,
                "Missing or invalid Authorization header");
        }

        String token = authorization.substring(7);

        // 3. 验证 Token（同步解析，Gateway 基于 WebFlux，避免阻塞操作）
        Claims claims;
        try {
            claims = jwtProvider.parseToken(token);
        } catch (ExpiredJwtException e) {
            return buildErrorResponse(exchange, HttpStatus.UNAUTHORIZED,
                "Token expired");
        } catch (JwtException e) {
            return buildErrorResponse(exchange, HttpStatus.UNAUTHORIZED,
                "Token invalid");
        }

        // 4. 检查黑名单（已注销的 Token）
        Boolean blacklisted = redisTemplate.hasKey("token_blacklist:" + token);
        if (Boolean.TRUE.equals(blacklisted)) {
            return buildErrorResponse(exchange, HttpStatus.UNAUTHORIZED,
                "Token has been revoked");
        }

        // 5. 将用户信息写入请求头，透传给下游服务
        ServerHttpRequest mutated = exchange.getRequest().mutate()
            .header("X-User-Id", claims.getSubject())
            .header("X-User-Roles", claims.get("roles", String.class))
            // 移除原始 Authorization Header，避免 JWT Secret 泄露给内部服务
            .headers(h -> h.remove(HttpHeaders.AUTHORIZATION))
            .build();

        return chain.filter(exchange.mutate().request(mutated).build());
    }

    private Mono<Void> buildErrorResponse(ServerWebExchange exchange,
            HttpStatus status, String message) {
        ServerHttpResponse response = exchange.getResponse();
        response.setStatusCode(status);
        response.getHeaders().setContentType(MediaType.APPLICATION_JSON);
        String body = "{\"code\":" + status.value()
            + ",\"message\":\"" + message + "\"}";
        DataBuffer buffer = response.bufferFactory()
            .wrap(body.getBytes(StandardCharsets.UTF_8));
        return response.writeWith(Mono.just(buffer));
    }
}
```

---

## 四、内网防绕行：内部调用签名

防止攻击者绕过 Gateway 直接访问内部服务：

```java
// InternalCallFilter.java  业务服务中的内部调用验签过滤器
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class InternalCallFilter implements Filter {

    @Value("${internal.call.secret}")
    private String internalSecret;

    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        HttpServletRequest request = (HttpServletRequest) req;
        String path = request.getRequestURI();

        // 内部 API 路径必须携带内部签名
        if (path.startsWith("/internal/")) {
            String timestamp = request.getHeader("X-Internal-Timestamp");
            String sign = request.getHeader("X-Internal-Sign");

            if (timestamp == null || sign == null) {
                ((HttpServletResponse) res).setStatus(403);
                res.getWriter().write("{\"message\":\"Forbidden: internal API\"}");
                return;
            }

            // 验证时间戳（5分钟内有效，防止重放攻击）
            long ts = Long.parseLong(timestamp);
            if (Math.abs(System.currentTimeMillis() - ts) > 5 * 60 * 1000) {
                ((HttpServletResponse) res).setStatus(403);
                res.getWriter().write("{\"message\":\"Timestamp expired\"}");
                return;
            }

            // 验证签名
            String expected = DigestUtils.md5DigestAsHex(
                (timestamp + internalSecret).getBytes());
            if (!expected.equals(sign)) {
                ((HttpServletResponse) res).setStatus(403);
                res.getWriter().write("{\"message\":\"Invalid signature\"}");
                return;
            }
        }
        chain.doFilter(req, res);
    }
}
```

OpenFeign 调用时自动注入签名（在 Gateway 侧通过 RequestSignatureGatewayFilter 完成，参见 SC-03）。

---

## 五、业务服务中获取当前用户

```java
// UserContext.java  从请求头中读取用户信息的工具类
public class UserContext {

    private static final ThreadLocal<UserInfo> CONTEXT = new ThreadLocal<>();

    public static void set(UserInfo userInfo) {
        CONTEXT.set(userInfo);
    }

    public static UserInfo get() {
        return CONTEXT.get();
    }

    public static String getUserId() {
        UserInfo info = CONTEXT.get();
        return info != null ? info.getUserId() : null;
    }

    public static void clear() {
        CONTEXT.remove();
    }
}

// UserContextInterceptor.java  拦截器：从请求头解析用户信息
@Component
public class UserContextInterceptor implements HandlerInterceptor {

    @Override
    public boolean preHandle(HttpServletRequest request,
            HttpServletResponse response, Object handler) {
        String userId = request.getHeader("X-User-Id");
        String roles = request.getHeader("X-User-Roles");
        if (userId != null) {
            UserContext.set(new UserInfo(userId,
                roles != null ? Arrays.asList(roles.split(",")) : List.of()));
        }
        return true;
    }

    @Override
    public void afterCompletion(HttpServletRequest request,
            HttpServletResponse response, Object handler, Exception ex) {
        UserContext.clear();  // 请求结束后清理，防止内存泄漏
    }
}
```

在业务代码中使用：

```java
// OrderService.java
public List<Order> getMyOrders() {
    String userId = UserContext.getUserId();  // 直接获取，无需解析 JWT
    return orderRepository.findByUserId(userId);
}
```

---

## 六、踩坑总结

**❌ 坑 1：JWT Secret 硬编码在代码里**

```yaml
# ❌ 错误：Secret 提交到 Git
jwt:
  secret: myHardcodedSecret123

# ✅ 正确：通过 Nacos 配置中心或环境变量注入，Secret 长度至少 32 字节
jwt:
  secret: ${JWT_SECRET}  # 从环境变量读取
```

**❌ 坑 2：Access Token 无法主动失效**

JWT 无状态，一旦颁发在过期前无法撤销。用户注销后 Token 仍有效：

```java
// ✅ 正确：注销时将 Token 加入 Redis 黑名单，Gateway 过滤器每次验签后检查黑名单
// Access Token 有效期设短（15~30 分钟），Refresh Token 存 Redis 支持主动撤销
```

**❌ 坑 3：Gateway 传递的用户 Header 被客户端伪造**

攻击者直接绕过 Gateway，在请求头中伪造 `X-User-Id`：

```java
// ✅ 正确：Gateway 过滤器中，转发请求前先删除客户端传来的 X-User-Id，再写入验证后的值
ServerHttpRequest mutated = exchange.getRequest().mutate()
    .headers(h -> {
        h.remove("X-User-Id");   // 先删除，防止客户端伪造
        h.remove("X-User-Roles");
    })
    .header("X-User-Id", claims.getSubject())   // 再写入验证过的值
    .header("X-User-Roles", claims.get("roles", String.class))
    .build();
```

---

## 七、文章小结

- 微服务鉴权推荐 **集中认证、分散授权**：Gateway 统一验 Token、提取用户信息，业务服务只做业务级权限判断
- **JWT 无状态**带来注销困难，通过 **短 Access Token（15~30 分钟）+ 长 Refresh Token（7 天，存 Redis）** 平衡安全与体验
- **内网防绕行**是容易被忽视的安全盲区：内部 API 必须验证来自 Gateway 的内部签名，拒绝直接的公网请求
- Gateway 转发时应**主动删除客户端传来的用户 Header**，再写入验证后的值，防止 Header 伪造攻击

## 八、思考题

1. 如果系统有多个 Gateway 实例，Redis 黑名单是共享的，但 JWT 验签在本地完成。如果某台 Gateway 实例宕机重启，新实例能否正确处理之前颁发的 Token？
2. OAuth2 和当前方案有什么本质区别？什么场景下需要引入 OAuth2（如 Spring Authorization Server）？
3. 如何为 WebSocket 长连接实现鉴权？和 HTTP 请求的鉴权方式有何不同？

## 参考资料

- [JWT 规范（RFC 7519）](https://datatracker.ietf.org/doc/html/rfc7519)
- [jjwt 0.12.x 文档](https://github.com/jwtk/jjwt#readme)
- [Spring Security 官方文档](https://docs.spring.io/spring-security/reference/)
- [OWASP JWT Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html)
