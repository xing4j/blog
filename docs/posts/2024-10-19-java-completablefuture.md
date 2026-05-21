# CompletableFuture 异步编排实战：从回调地狱到优雅流式

<div class="post-meta">📅 2024-10-19 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">并发</span></div>

查询商品详情接口需要并发调用：基本信息、库存、价格、评论四个服务，最后合并结果。用 Future.get() 写出来是四次顺序阻塞等待；用回调则层层嵌套难以维护。CompletableFuture 正是为解决这类异步编排问题而生，本文通过一个完整的电商场景还原其核心用法。

---

## 一、背景：Future 的局限与 CompletableFuture 的诞生

Future<T> 是 JDK 5 引入的异步结果容器，但它有三个根本缺陷：

1. **get() 会阻塞**：没有非阻塞的方式获取结果，只能轮询 isDone() 或无限等待
2. **无法组合**：不能将两个 Future 的结果合并，或在一个完成后触发另一个
3. **无法处理异常**：计算中的异常会被包装为 ExecutionException，只能在 get() 时处理

CompletableFuture<T> 是 JDK 8 引入的增强版，实现了 CompletionStage<T> 接口，提供了 50+ 个方法用于**异步编排、组合、异常处理**。

---

## 二、核心 API 速览

### 2.1 创建

`java
// 有返回值的异步任务（supplyAsync）
CompletableFuture<String> cf1 = CompletableFuture.supplyAsync(() -> {
    return fetchProductName(productId);  // 在 ForkJoinPool 中异步执行
});

// 无返回值的异步任务（runAsync）
CompletableFuture<Void> cf2 = CompletableFuture.runAsync(() -> {
    sendNotification(userId);
});

// 指定线程池（生产必须指定，不用默认 ForkJoinPool）
ExecutorService executor = Executors.newFixedThreadPool(10);
CompletableFuture<String> cf3 = CompletableFuture.supplyAsync(() -> {
    return fetchProductName(productId);
}, executor);

// 直接用已知结果创建（测试/mock 常用）
CompletableFuture<String> completed = CompletableFuture.completedFuture("result");
`

### 2.2 串行转换（thenApply / thenAccept / thenRun）

`java
// thenApply：有输入有输出，类似 Stream.map()
CompletableFuture<Integer> priceFuture = CompletableFuture
    .supplyAsync(() -> fetchProduct(id))           // 返回 Product
    .thenApply(product -> product.getPrice());     // 提取价格，返回 Integer

// thenAccept：有输入无输出（消费结果）
CompletableFuture<Void> logFuture = CompletableFuture
    .supplyAsync(() -> fetchProduct(id))
    .thenAccept(product -> log.info("Product: {}", product));

// thenRun：无输入无输出（纯副作用）
cf.thenRun(() -> System.out.println("Done!"));

// thenApplyAsync：在新线程中执行转换（默认复用同一线程）
cf.thenApplyAsync(v -> transform(v), executor);
`

### 2.3 并发等待所有 / 任意一个

`java
// allOf：等待全部完成（没有合并结果的功能，需要手动 join）
CompletableFuture<String> nameFuture = ...;
CompletableFuture<Integer> priceFuture = ...;
CompletableFuture<Integer> stockFuture = ...;

CompletableFuture.allOf(nameFuture, priceFuture, stockFuture)
    .thenApply(v -> {
        // allOf 完成时，所有子任务都已完成，可以安全 join()（不阻塞）
        String name = nameFuture.join();
        int price = priceFuture.join();
        int stock = stockFuture.join();
        return buildProductVO(name, price, stock);
    });

// anyOf：任意一个完成就继续（用于多数据源竞速）
CompletableFuture<Object> fastest = CompletableFuture.anyOf(
    queryFromCache(key),
    queryFromDB(key)
);
`

### 2.4 两个任务组合

`java
// thenCombine：两个任务都完成后合并结果
CompletableFuture<ProductVO> result = nameFuture.thenCombine(
    priceFuture,
    (name, price) -> new ProductVO(name, price)
);

// thenCompose：串行依赖，类似 Stream.flatMap()
// 场景：根据 userId 先查用户，再根据用户等级查折扣
CompletableFuture<Double> discount = CompletableFuture
    .supplyAsync(() -> fetchUser(userId))
    .thenCompose(user -> fetchDiscount(user.getLevel())); // 返回新的 CF
`

### 2.5 异常处理

`java
// exceptionally：异常恢复，类似 try-catch 中的默认值
CompletableFuture<String> safe = CompletableFuture
    .supplyAsync(() -> fetchFromRemote(id))
    .exceptionally(ex -> {
        log.warn("Remote call failed, using default", ex);
        return "default-value";  // 降级返回
    });

// handle：无论成功失败都执行（类似 finally）
CompletableFuture<String> handled = CompletableFuture
    .supplyAsync(() -> fetchFromRemote(id))
    .handle((result, ex) -> {
        if (ex != null) return "fallback";
        return result.toUpperCase();
    });

// whenComplete：有结果时消费，但不改变结果
cf.whenComplete((result, ex) -> {
    if (ex != null) metrics.recordError();
    else metrics.recordSuccess();
});
`

---

## 三、实战：商品详情页并发聚合

`java
@Service
public class ProductDetailService {

    private final ExecutorService ioPool;

    public ProductDetailService() {
        // 自定义 IO 密集型线程池（不使用 ForkJoinPool）
        this.ioPool = new ThreadPoolExecutor(
                20, 50, 60, TimeUnit.SECONDS,
                new ArrayBlockingQueue<>(200),
                new CustomThreadFactory("product-io"),
                new ThreadPoolExecutor.CallerRunsPolicy()
        );
    }

    /**
     * 并发查询商品详情：基本信息、价格、库存、评论
     * 总耗时 ≈ max(各接口耗时)，而非顺序调用的 sum
     */
    public ProductDetailVO getProductDetail(Long productId) {
        // 四个任务并发执行
        CompletableFuture<ProductBasic> basicFuture =
            CompletableFuture.supplyAsync(() -> productRpc.getBasic(productId), ioPool);

        CompletableFuture<Price> priceFuture =
            CompletableFuture.supplyAsync(() -> priceRpc.getPrice(productId), ioPool);

        CompletableFuture<Stock> stockFuture =
            CompletableFuture.supplyAsync(() -> stockRpc.getStock(productId), ioPool);

        CompletableFuture<List<Comment>> commentFuture =
            CompletableFuture.supplyAsync(() -> commentRpc.getTopComments(productId, 5), ioPool)
                .exceptionally(ex -> {
                    log.warn("Comment service unavailable, skipping", ex);
                    return Collections.emptyList();  // 评论失败不影响主流程
                });

        // 等待全部完成并聚合
        return CompletableFuture.allOf(basicFuture, priceFuture, stockFuture, commentFuture)
            .thenApply(v -> ProductDetailVO.builder()
                    .basic(basicFuture.join())
                    .price(priceFuture.join())
                    .stock(stockFuture.join())
                    .comments(commentFuture.join())
                    .build())
            .get(3, TimeUnit.SECONDS);  // 设置整体超时，避免无限等待
    }
}
`

**性能对比**：假设 4 个接口各耗时 100ms
- 顺序调用：400ms
- CompletableFuture 并发：~100ms（节省 75%）

---

## 四、对比：CompletableFuture vs 其他方案

| 方案 | 适用场景 | 优点 | 缺点 |
|------|---------|------|------|
| Future.get() | 简单单任务 | 简单 | 阻塞，无法组合 |
| CompletableFuture | 多任务编排 | 非阻塞、可组合、可处理异常 | 方法较多，学习成本 |
| @Async（Spring）| Spring 简单异步 | 声明式，简单 | 不支持复杂编排，异常处理弱 |
| RxJava/Reactor | 响应式流（背压）| 功能强大 | 学习成本极高 |
| Virtual Thread（JDK 21）| IO 密集型阻塞代码 | 代码与同步相同，不改接口 | 不适合 CPU 密集型 |

---

## 五、常见坑点与最佳实践

### 坑 1：使用默认 ForkJoinPool 导致 IO 任务阻塞 CPU 任务

`java
// ❌ 危险：ForkJoinPool 是计算密集型任务设计的，被 IO 阻塞后影响 parallelStream
CompletableFuture.supplyAsync(() -> httpClient.get(url));  // 使用了默认 ForkJoinPool

// ✅ 始终为 IO 任务指定独立线程池
CompletableFuture.supplyAsync(() -> httpClient.get(url), ioExecutor);
`

### 坑 2：忘记设置超时，一个下游挂死整个接口

`java
// ❌ 无超时：下游挂死时请求线程永久阻塞
productFuture.get();

// ✅ 设置超时，超时后抛 TimeoutException
productFuture.get(2, TimeUnit.SECONDS);

// ✅ JDK 9+ 的 orTimeout（超时后 CF 以异常完成）
productFuture.orTimeout(2, TimeUnit.SECONDS)
    .exceptionally(ex -> defaultProduct());
`

### 坑 3：thenApply 和 thenCompose 混淆

`java
// ❌ 错误：thenApply 内返回 CompletableFuture，得到 CF<CF<User>>（双层嵌套）
CompletableFuture<CompletableFuture<User>> wrong = orderFuture
    .thenApply(order -> fetchUser(order.getUserId())); // fetchUser 返回 CF<User>

// ✅ 正确：thenCompose 自动 flatten，得到 CF<User>
CompletableFuture<User> correct = orderFuture
    .thenCompose(order -> fetchUser(order.getUserId()));
`

### 坑 4：allOf 不合并结果，需要手动 join

`java
// ❌ allOf 的返回类型是 CF<Void>，不包含各子任务结果
CompletableFuture<Void> all = CompletableFuture.allOf(cf1, cf2, cf3);
// all.get() 得到 null，无法获取 cf1/cf2/cf3 的结果

// ✅ 在 thenApply 中对各 CF 调用 join()（此时已完成，不会阻塞）
all.thenApply(v -> {
    return combine(cf1.join(), cf2.join(), cf3.join());
});
`

---

## 六、总结与延伸

**核心要点**：
- CompletableFuture 解决了 Future 的三大痛点：非阻塞获取、任务组合、异常处理
- IO 密集型任务必须指定独立线程池，不能使用默认 ForkJoinPool
- 串行依赖用 	henCompose，并行聚合用 llOf + join()，任意完成用 nyOf
- 始终设置超时（get(timeout) 或 orTimeout()），避免下游挂死传导

**延伸阅读方向**：
- Project Reactor / RxJava：响应式编程，处理背压和流式数据
- JDK 21 虚拟线程（Virtual Thread）：用同步代码写出异步性能，颠覆异步编程模式
- Spring WebFlux：基于 Reactor 的非阻塞 Web 框架
- CompletableFuture 源码中的 Completion 链式结构
