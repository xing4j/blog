# API 签名机制：防篡改与防重放攻击

<div class="post-meta">📅 2026-02-28 &nbsp;·&nbsp; 🏷️ <span class="tag">安全</span> <span class="tag">API</span></div>

API 签名是对外开放接口的安全基础，防止参数被篡改和请求被重放。

---

## 一、签名要解决的问题

```
问题1：参数篡改
  正常请求：amount=100
  攻击者拦截后修改：amount=1  → 以 1 元购买 100 元商品

问题2：重放攻击
  攻击者截获"转账 1000 元"的合法请求
  重复发送 N 次 → 转账 N×1000 元

解决：
  签名  → 防篡改（任何参数修改都会导致签名验证失败）
  时间戳 + nonce → 防重放（超时拒绝，已用 nonce 拒绝）
```

---

## 二、签名流程

```
客户端签名步骤：
1. 收集参数：appId + timestamp + nonce + 业务参数
2. 按字典序排列所有参数名
3. 拼接：key1=val1&key2=val2&...&appSecret=xxx
4. HMAC-SHA256 计算签名
5. 将 appId, timestamp, nonce, sign 放入请求头

服务端验证步骤：
1. 检查 timestamp 是否在5分钟内（防重放）
2. 检查 nonce 是否已使用（防重放，Redis 存储）
3. 用相同算法计算签名
4. 对比签名是否一致
```

---

## 三、Spring Boot 实现

### 客户端签名工具

```java
public class ApiSignatureUtil {
    
    public static String sign(Map<String, String> params, String appSecret) throws Exception {
        // 1. 过滤掉 sign 字段
        TreeMap<String, String> sortedParams = new TreeMap<>(params);
        sortedParams.remove("sign");
        
        // 2. 按字典序拼接
        StringBuilder sb = new StringBuilder();
        sortedParams.forEach((k, v) -> {
            if (v != null && !v.isEmpty()) {
                sb.append(k).append("=").append(v).append("&");
            }
        });
        sb.append("appSecret=").append(appSecret);
        
        // 3. HMAC-SHA256
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(appSecret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        byte[] raw = mac.doFinal(sb.toString().getBytes(StandardCharsets.UTF_8));
        return HexFormat.of().formatHex(raw).toUpperCase();
    }
    
    // 构建请求头
    public static Map<String, String> buildHeaders(Map<String, String> params, 
                                                    String appId, String appSecret) throws Exception {
        Map<String, String> allParams = new HashMap<>(params);
        allParams.put("appId", appId);
        allParams.put("timestamp", String.valueOf(System.currentTimeMillis() / 1000));
        allParams.put("nonce", UUID.randomUUID().toString().replace("-", ""));
        
        String sign = sign(allParams, appSecret);
        return Map.of(
            "X-App-Id", appId,
            "X-Timestamp", allParams.get("timestamp"),
            "X-Nonce", allParams.get("nonce"),
            "X-Sign", sign
        );
    }
}
```

### 服务端验证过滤器

```java
@Component
@Order(1)
public class SignatureFilter implements Filter {
    
    private static final long TIMESTAMP_EXPIRE = 300; // 5分钟
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    @Autowired
    private AppKeyRepository appKeyRepository;

    @Override
    public void doFilter(ServletRequest req, ServletResponse resp, FilterChain chain) 
            throws IOException, ServletException {
        HttpServletRequest request = (HttpServletRequest) req;
        
        // 只对需要签名的接口验证
        if (!request.getRequestURI().startsWith("/api/open/")) {
            chain.doFilter(req, resp);
            return;
        }
        
        try {
            verifySignature(request);
            chain.doFilter(req, resp);
        } catch (SignatureException e) {
            sendError((HttpServletResponse) resp, 401, e.getMessage());
        }
    }
    
    private void verifySignature(HttpServletRequest request) {
        String appId = request.getHeader("X-App-Id");
        String timestamp = request.getHeader("X-Timestamp");
        String nonce = request.getHeader("X-Nonce");
        String sign = request.getHeader("X-Sign");
        
        if (Stream.of(appId, timestamp, nonce, sign).anyMatch(StringUtils::isEmpty)) {
            throw new SignatureException("缺少签名参数");
        }
        
        // 1. 验证时间戳（5分钟内）
        long ts = Long.parseLong(timestamp);
        if (Math.abs(System.currentTimeMillis() / 1000 - ts) > TIMESTAMP_EXPIRE) {
            throw new SignatureException("请求已过期");
        }
        
        // 2. 验证 nonce（防重放）
        String nonceKey = "nonce:" + appId + ":" + nonce;
        Boolean isNew = redisTemplate.opsForValue().setIfAbsent(nonceKey, "1", Duration.ofMinutes(10));
        if (!Boolean.TRUE.equals(isNew)) {
            throw new SignatureException("重复请求");
        }
        
        // 3. 获取 appSecret
        String appSecret = appKeyRepository.findSecretByAppId(appId);
        if (appSecret == null) {
            throw new SignatureException("无效的 AppId");
        }
        
        // 4. 重新计算签名
        Map<String, String> params = extractParams(request);
        params.put("appId", appId);
        params.put("timestamp", timestamp);
        params.put("nonce", nonce);
        
        String expectedSign = ApiSignatureUtil.sign(params, appSecret);
        if (!expectedSign.equalsIgnoreCase(sign)) {
            throw new SignatureException("签名验证失败");
        }
    }
}
```

---

## 四、签名防坑

```java
// 坑1：浮点数精度问题
// 不要用 double，金额统一用字符串或 Long（分）
Map.of("amount", "100.50")  // ✅ 字符串
Map.of("amount", 100.50)    // ❌ 可能被序列化为 1.005E2

// 坑2：参数值为空时的处理
// 约定：空值不参与签名，避免 null vs "" 的差异
if (v != null && !v.isEmpty()) {
    sb.append(k).append("=").append(v).append("&");
}

// 坑3：编码问题
// 含特殊字符的参数值在传输时需要 URL 编码
// 签名时用原始值，不要 URL 编码后再签名
```

---

## 总结

| 机制 | 防御目标 |
|------|---------|
| HMAC 签名 | 防参数篡改 |
| 时间戳（5分钟窗口）| 防旧请求重放 |
| Nonce（一次性随机数）| 防相同时间内重放 |
| AppId + AppSecret | 身份认证 + 密钥管理 |
| HTTPS | 防中间人截获（签名的基础）|
