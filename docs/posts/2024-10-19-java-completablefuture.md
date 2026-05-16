# CompletableFuture 异步编排实战

<div class="post-meta">📅 2024-10-19 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">异步</span></div>

`CompletableFuture` 是 Java 8 引入的异步编程利器，支持链式调用、并行聚合、异常处理，极大简化了复杂异步流程的编写。

---

## 一、创建异步任务

```java
// runAsync：无返回值
CompletableFuture<Void> f1 = CompletableFuture.runAsync(() -> {
    System.out.println("异步执行，无返回值");
}, executor);

// supplyAsync：有返回值
CompletableFuture<String> f2 = CompletableFuture.supplyAsync(() -> {
    return "异步结果";
}, executor);

// 建议始终指定线程池，不要用默认的 ForkJoinPool.commonPool()
```

---

## 二、链式处理

```java
CompletableFuture.supplyAsync(() -> queryUserId(token), executor)   // 1. 查用户ID
    .thenApplyAsync(userId -> queryUserInfo(userId), executor)      // 2. 查用户信息（有返回值）
    .thenApplyAsync(user -> buildResponse(user), executor)          // 3. 构建响应
    .thenAccept(resp -> log.info("响应: {}", resp))                 // 4. 消费结果（无返回值）
    .exceptionally(e -> {                                           // 5. 异常处理
        log.error("流程异常", e);
        return null;
    });
```

| 方法 | 说明 |
|------|------|
| `thenApply(fn)` | 转换结果，有返回值 |
| `thenAccept(fn)` | 消费结果，无返回值 |
| `thenRun(fn)` | 不关心结果，直接执行下一步 |
| `thenCompose(fn)` | 返回新的 CompletableFuture（扁平化，类似 flatMap）|
| `thenApplyAsync` | 异步版本，在指定线程池中执行 |

---

## 三、并行聚合

### allOf — 等待全部完成

```java
// 场景：商品详情页，并行查询基本信息、库存、评论
CompletableFuture<ProductInfo> infoFuture    = getProductInfo(id);
CompletableFuture<StockInfo>   stockFuture   = getStockInfo(id);
CompletableFuture<List<Review>> reviewFuture = getReviews(id);

CompletableFuture.allOf(infoFuture, stockFuture, reviewFuture)
    .thenRun(() -> {
        ProductInfo info   = infoFuture.join();   // join() 不抛检查异常
        StockInfo   stock  = stockFuture.join();
        List<Review> reviews = reviewFuture.join();
        buildDetailPage(info, stock, reviews);
    });
```

### anyOf — 任一完成即返回

```java
// 场景：多个数据源查询，取最快返回的结果
CompletableFuture<Object> fastest = CompletableFuture.anyOf(
    queryFromCache(key),
    queryFromDB(key),
    queryFromRemote(key)
);
Object result = fastest.get(3, TimeUnit.SECONDS);
```

---

## 四、异常处理

```java
// exceptionally：发生异常时的降级处理
CompletableFuture<UserInfo> future = getUser(id)
    .exceptionally(e -> {
        log.error("查询用户失败", e);
        return UserInfo.defaultUser(); // 返回默认值
    });

// handle：无论成功失败都会执行（类似 try-catch-finally）
CompletableFuture<String> result = future
    .handle((user, ex) -> {
        if (ex != null) {
            return "降级结果";
        }
        return user.getName();
    });

// whenComplete：监听完成事件，不改变结果
future.whenComplete((user, ex) -> {
    if (ex != null) {
        metrics.recordError();
    } else {
        metrics.recordSuccess();
    }
});
```

---

## 五、超时控制（Java 9+）

```java
// orTimeout：超时则抛 TimeoutException
CompletableFuture<String> future = getRemoteData()
    .orTimeout(3, TimeUnit.SECONDS);

// completeOnTimeout：超时则使用默认值完成
CompletableFuture<String> future2 = getRemoteData()
    .completeOnTimeout("默认值", 3, TimeUnit.SECONDS);
```

---

## 六、实战：电商下单异步流程

```java
public CompletableFuture<OrderResult> createOrder(OrderRequest req) {
    // 并行执行：库存预占 + 优惠券校验
    CompletableFuture<Boolean> stockFuture =
        CompletableFuture.supplyAsync(() -> stockService.reserve(req), bizExecutor);

    CompletableFuture<CouponInfo> couponFuture =
        CompletableFuture.supplyAsync(() -> couponService.validate(req), bizExecutor);

    return CompletableFuture.allOf(stockFuture, couponFuture)
        .thenApplyAsync(v -> {
            // 两者都成功后，创建订单
            boolean stockOk  = stockFuture.join();
            CouponInfo coupon = couponFuture.join();
            if (!stockOk) throw new BizException("库存不足");
            return orderService.create(req, coupon);
        }, bizExecutor)
        .exceptionally(e -> {
            // 任一失败时回滚
            rollback(req);
            throw new CompletionException(e);
        });
}
```

---

## 七、常见踩坑

```java
// ❌ 1. 使用 get() 未设超时，可能永久阻塞
future.get();

// ✅ 总是设置超时
future.get(5, TimeUnit.SECONDS);

// ❌ 2. thenApply 在主线程执行，阻塞调用方
future.thenApply(r -> heavyCompute(r));

// ✅ 用 thenApplyAsync 异步执行
future.thenApplyAsync(r -> heavyCompute(r), executor);

// ❌ 3. 未处理异常，Future 静默失败
future.thenApply(r -> riskyOp(r));

// ✅ 链式末尾加 exceptionally
future.thenApply(r -> riskyOp(r)).exceptionally(e -> fallback());
```

---

## 总结

| 场景 | 推荐方法 |
|------|---------|
| 串行依赖 | `thenApplyAsync` / `thenComposeAsync` |
| 并行聚合 | `allOf` |
| 取最快 | `anyOf` |
| 异常降级 | `exceptionally` / `handle` |
| 超时控制 | `orTimeout` / `completeOnTimeout`（Java 9+）|

`CompletableFuture` 的核心价值在于**将多个异步任务的依赖关系声明式地表达出来**，避免回调地狱，使代码逻辑清晰可维护。
