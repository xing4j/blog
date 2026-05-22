# JWT 安全详解：实现、漏洞与最佳实践

<div class="post-meta">📅 2025-09-27 &nbsp;·&nbsp; 🏷️ <span class="tag">安全</span> <span class="tag">JWT</span></div>

JWT（JSON Web Token）是现代认证的主流方案，但也存在多种安全风险。本文深入分析其安全实践。

---

## 一、JWT 结构

```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.   ← Header（Base64）
eyJ1c2VySWQiOjEsInJvbGUiOiJVU0VSIn0.    ← Payload（Base64）
SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c ← Signature（HMAC）

Header:  {"alg": "HS256", "typ": "JWT"}
Payload: {"userId": 1, "role": "USER", "exp": 1749072000}
Signature: HMAC_SHA256(base64(header) + "." + base64(payload), secret)
```

**注意**：Payload 只是 Base64 编码，不是加密！不要存放敏感信息。

---

## 二、Spring Boot JWT 实现

```xml
<dependency>
  <groupId>io.jsonwebtoken</groupId>
  <artifactId>jjwt-api</artifactId>
  <version>0.12.3</version>
</dependency>
<dependency>
  <groupId>io.jsonwebtoken</groupId>
  <artifactId>jjwt-impl</artifactId>
  <version>0.12.3</version>
  <scope>runtime</scope>
</dependency>
<dependency>
  <groupId>io.jsonwebtoken</groupId>
  <artifactId>jjwt-jackson</artifactId>
  <version>0.12.3</version>
  <scope>runtime</scope>
</dependency>
```

```java
@Component
public class JwtTokenProvider {
    // 生产环境：至少256位的强随机密钥，从配置中心读取
    @Value("${jwt.secret}")
    private String secret;
    
    @Value("${jwt.access-token-expire:1800}")  // 默认30分钟
    private long accessTokenExpire;
    
    @Value("${jwt.refresh-token-expire:604800}") // 默认7天
    private long refreshTokenExpire;

    private SecretKey getSigningKey() {
        return Keys.hmacShaKeyFor(Decoders.BASE64.decode(secret));
    }

    // 生成 Access Token
    public String generateAccessToken(Long userId, String username, List<String> roles) {
        return Jwts.builder()
            .subject(String.valueOf(userId))
            .claim("username", username)
            .claim("roles", roles)
            .issuedAt(new Date())
            .expiration(new Date(System.currentTimeMillis() + accessTokenExpire * 1000))
            .signWith(getSigningKey())
            .compact();
    }

    // 验证并解析 Token
    public Claims parseToken(String token) {
        try {
            return Jwts.parser()
                .verifyWith(getSigningKey())
                .build()
                .parseSignedClaims(token)
                .getPayload();
        } catch (ExpiredJwtException e) {
            throw new TokenExpiredException("Token 已过期");
        } catch (JwtException e) {
            throw new InvalidTokenException("Token 无效");
        }
    }
}
```

---

## 三、Access Token + Refresh Token

```java
// 登录时同时颁发 Access Token（短期）和 Refresh Token（长期）
@PostMapping("/login")
public TokenResponse login(@RequestBody @Valid LoginRequest req) {
    // 验证用户名密码...
    String accessToken = jwtProvider.generateAccessToken(user.getId(), ...);
    String refreshToken = jwtProvider.generateRefreshToken(user.getId());
    
    // Refresh Token 存入 Redis（可主动吊销）
    redisTemplate.opsForValue().set(
        "refresh:" + user.getId(), refreshToken,
        Duration.ofDays(7)
    );
    
    return new TokenResponse(accessToken, refreshToken);
}

// 刷新 Token
@PostMapping("/token/refresh")
public TokenResponse refreshToken(@RequestBody RefreshRequest req) {
    Claims claims = jwtProvider.parseToken(req.getRefreshToken());
    Long userId = Long.valueOf(claims.getSubject());
    
    // 校验 Redis 中的 Refresh Token（防止重放）
    String stored = redisTemplate.opsForValue().get("refresh:" + userId);
    if (!req.getRefreshToken().equals(stored)) {
        throw new InvalidTokenException("Refresh Token 已失效");
    }
    
    // 颁发新的 Access Token
    return new TokenResponse(jwtProvider.generateAccessToken(userId, ...), null);
}
```

---

## 四、Token 主动吊销（黑名单机制）

```java
// 退出登录：将 Token 加入黑名单（存入 Redis，过期时间与 Token 一致）
@PostMapping("/logout")
public void logout(HttpServletRequest request) {
    String token = extractToken(request);
    Claims claims = jwtProvider.parseToken(token);
    long ttl = claims.getExpiration().getTime() - System.currentTimeMillis();
    
    if (ttl > 0) {
        redisTemplate.opsForValue().set(
            "blacklist:" + token,
            "1",
            Duration.ofMillis(ttl)
        );
    }
    // 同时删除 Refresh Token
    redisTemplate.delete("refresh:" + claims.getSubject());
}

// 过滤器中检查黑名单
public boolean isTokenBlacklisted(String token) {
    return redisTemplate.hasKey("blacklist:" + token);
}
```

---

## 五、常见安全漏洞

```
1. 算法混淆攻击（alg=none）
   修改 Header 中 alg 为 "none"，服务端不验证签名
   防御：显式指定 verifyWith(signingKey)，拒绝 alg=none

2. 密钥强度不足
   使用 "secret"、"password" 等弱密钥
   防御：使用 256位以上随机密钥（OpenSSL 生成）
   openssl rand -base64 32

3. 敏感信息泄露
   Payload 只是 Base64，将密码/身份证存入 Payload
   防御：JWT 中只存非敏感标识（userId、roles）

4. Token 永不过期
   exp 设置过长或未设置
   防御：Access Token 30分钟，配合 Refresh Token 机制

5. 传输安全
   HTTP 明文传输，Token 被中间人截获
   防御：强制 HTTPS
```

---

## 六、安全配置清单

```yaml
# application.yml 安全配置
jwt:
  # 从环境变量或配置中心读取，不硬编码
  secret: ${JWT_SECRET}
  access-token-expire: 1800    # 30分钟
  refresh-token-expire: 604800  # 7天

server:
  ssl:
    enabled: true
```

```java
// Cookie 存储 Token 的安全配置（比 localStorage 更安全）
ResponseCookie.from("access_token", accessToken)
    .httpOnly(true)   // 防 XSS
    .secure(true)     // 仅 HTTPS
    .sameSite("Strict") // 防 CSRF
    .maxAge(Duration.ofMinutes(30))
    .path("/")
    .build();
```

---

## 总结

| 安全要点 | 措施 |
|---------|------|
| 密钥强度 | 256位随机密钥，从环境变量读取 |
| Token 过期 | Access 30分钟，Refresh 7天 |
| 主动吊销 | 黑名单存 Redis，过期自动清理 |
| 敏感信息 | Payload 只存 userId/roles |
| 传输安全 | 强制 HTTPS |
| Cookie 存储 | httpOnly + Secure + SameSite |

**延伸阅读**：
- [JWT 官方规范 RFC 7519](https://tools.ietf.org/html/rfc7519) — Token 结构与声明字段标准
- [OWASP API Security](https://owasp.org/www-project-api-security/) — API 认证安全最佳实践
- [Spring Security OAuth2](https://spring.io/projects/spring-security) — 完整的授权服务器实现
- 无状态 Token vs Session — 微服务架构下两种认证方案的取舍分析
