# 高并发秒杀系统设计

<div class="post-meta">📅 2026-01-25 &nbsp;·&nbsp; 🏷️ <span class="tag">高并发</span> <span class="tag">系统设计</span></div>

秒杀系统是高并发场景的典型案例，核心挑战是：瞬间流量洪峰 + 库存超卖 + 数据一致性。

---

## 一、核心挑战

```
问题：
- 10万人抢1000件商品 → 10:1 甚至100:1 的并发比
- 库存超卖（并发 CAS 失败）
- 数据库被打垮（接口响应超时）
- 机器人刷单

目标：
- 不超卖（正确性）
- 系统不崩溃（可用性）
- 响应快（用户体验）
```

---

## 二、分层防护架构

```
          客户端
            │
      ① CDN 静态资源（页面/图片不走服务器）
            │
      ② Nginx 限流（令牌桶，单 IP 限速）
            │
      ③ 网关层（Gateway 全局限流 + 黑名单过滤）
            │
      ④ Redis 预检（库存预扣减，快速失败）
            │
      ⑤ MQ 异步下单（削峰，保护数据库）
            │
      ⑥ 数据库扣减库存（最终一致）
```

---

## 三、Redis 库存预扣减（核心）

```java
// 秒杀开始前，将库存加载到 Redis
redisTemplate.opsForValue().set("seckill:stock:" + itemId, 1000);

// 使用 Lua 脚本保证原子性
String script = """
    local stock = tonumber(redis.call('get', KEYS[1]))
    if stock == nil or stock <= 0 then
        return -1  -- 库存不足
    end
    redis.call('decr', KEYS[1])
    return 1  -- 预扣成功
""";

Long result = redisTemplate.execute(
    new DefaultRedisScript<>(script, Long.class),
    Collections.singletonList("seckill:stock:" + itemId)
);

if (result == -1) {
    return Result.fail("商品已售罄");
}
// 预扣成功，发送 MQ 消息异步创建订单
mqProducer.send(new SeckillOrderMessage(userId, itemId));
```

---

## 四、防超卖：数据库乐观锁

```sql
-- 扣减库存（带版本号，防并发超卖）
UPDATE seckill_stock
SET stock = stock - 1,
    version = version + 1
WHERE item_id = #{itemId}
  AND stock > 0         -- 关键：stock > 0 防止超卖
  AND version = #{version};

-- 影响行数为 0 = 库存不足或版本冲突 → 下单失败
```

```java
// 分段锁：将1000件库存分散到10个记录，降低锁竞争
// 每个段 100 件，随机选一段
int segment = ThreadLocalRandom.current().nextInt(10);
int updated = stockMapper.decrStock(itemId, segment);
if (updated == 0) {
    // 尝试其他段
    for (int i = 0; i < 10; i++) {
        updated = stockMapper.decrStock(itemId, i);
        if (updated > 0) break;
    }
}
```

---

## 五、限流防刷

```java
// Nginx 层限流（nginx.conf）
// limit_req_zone $binary_remote_addr zone=seckill:10m rate=10r/s;
// limit_req zone=seckill burst=20 nodelay;

// Gateway 层全局限流（Redis + 令牌桶）
@Component
public class SeckillRateLimitFilter implements GlobalFilter {
    @Autowired
    private ReactiveRedisTemplate<String, Long> redisTemplate;

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        String userId = getUserId(exchange);
        String key = "seckill:user:" + userId;

        // 用户维度：每秒最多1次秒杀请求
        return redisTemplate.opsForValue()
            .increment(key)
            .flatMap(count -> {
                if (count == 1) {
                    redisTemplate.expire(key, Duration.ofSeconds(1)).subscribe();
                }
                if (count > 1) {
                    exchange.getResponse().setStatusCode(HttpStatus.TOO_MANY_REQUESTS);
                    return exchange.getResponse().setComplete();
                }
                return chain.filter(exchange);
            });
    }
}
```

---

## 六、MQ 异步削峰

```java
// 消费者：异步处理秒杀订单
@RocketMQMessageListener(topic = "seckill-order", consumerGroup = "seckill-consumer")
@Component
public class SeckillOrderConsumer implements RocketMQListener<SeckillOrderMessage> {

    @Override
    @Transactional
    public void onMessage(SeckillOrderMessage msg) {
        // 幂等检查（防止重复消费）
        if (orderService.existsByIdempotentKey(msg.getIdempotentKey())) {
            return;
        }
        
        // 二次库存检查（数据库扣减）
        int updated = stockService.decrStock(msg.getItemId());
        if (updated == 0) {
            // 库存不足，发送失败通知
            notifyService.notifyOutOfStock(msg.getUserId());
            return;
        }
        
        // 创建订单
        orderService.createOrder(msg);
    }
}
```

---

## 七、接口幂等

```java
// 前端生成唯一秒杀token，服务端用Redis去重
@PostMapping("/seckill")
public Result seckill(@RequestHeader("X-Seckill-Token") String token,
                      @RequestBody SeckillRequest req) {
    String key = "seckill:token:" + token;
    // setIfAbsent = SETNX，只有第一次能设置成功
    Boolean isFirstRequest = redisTemplate.opsForValue()
        .setIfAbsent(key, "1", Duration.ofMinutes(5));
    
    if (!Boolean.TRUE.equals(isFirstRequest)) {
        return Result.fail("请勿重复提交");
    }
    // 正常处理
}
```

---

## 总结

| 层次 | 方案 | 目的 |
|------|------|------|
| 前端 | 按钮置灰、倒计时 | 减少无效请求 |
| CDN | 静态页面加速 | 降低服务器压力 |
| Nginx | 限流 + 黑名单 | IP 防刷 |
| Redis | Lua 原子预扣减 | 快速失败，保护 DB |
| MQ | 异步下单 | 削峰填谷 |
| DB | 乐观锁 / 分段锁 | 防超卖 |
| 幂等 | SETNX Token | 防重复下单 |
