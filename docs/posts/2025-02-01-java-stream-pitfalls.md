# Java Stream 那些坑：写起来优雅，用错了要命

<div class="post-meta">📅 2025-02-01 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span></div>

Stream API 让集合操作变得优雅简洁，但它也暗藏不少陷阱：forEach 的变量修改不生效、parallel() 用错反而更慢、flatMap 中的 
ull 引发 NPE……这些问题在代码 review 和生产事故中反复出现。本文整理 8 个高频坑，每个附有可运行的反例和正解。

---

## 一、背景：Stream 的惰性求值模型

理解 Stream 坑的关键，是先理解它的**惰性求值（Lazy Evaluation）**模型：

```
数据源 → 中间操作（惰性）→ 终止操作（触发执行）
         filter/map/...    forEach/collect/...

中间操作不会立刻执行，只有终止操作被调用时，整条流水线才真正运行。
```
这意味着：
- Stream 只能被消费一次，重复终止操作抛 IllegalStateException
- 中间操作的副作用（修改外部变量）是未定义行为

---

## 二、8 个高频坑

### 坑 1：在 forEach 中修改外部集合

```java
List<String> list = new ArrayList<>(Arrays.asList("a", "b", "c"));
List<String> result = new ArrayList<>();

// ❌ forEach 内修改外部变量，编译提示 "variable should be effectively final"
// 即使绕过编译，并发场景也会 ConcurrentModificationException
list.stream().forEach(s -> result.add(s.toUpperCase())); // 看起来能运行但语义错误

// ✅ 用 collect 收集结果
List<String> result = list.stream()
        .map(String::toUpperCase)
        .collect(Collectors.toList());
```
### 坑 2：Stream 重复消费

```java
Stream<String> stream = list.stream().filter(s -> s.length() > 1);

long count = stream.count();       // ✅ 第一次终止操作
List<String> collected = stream.collect(Collectors.toList()); // ❌ IllegalStateException: stream has already been operated upon or closed
```
**正解**：每次操作从数据源重新创建 Stream，不要持有 Stream 引用复用。

### 坑 3：parallel() 并非总是更快

```java
// ❌ 数据量小 + 操作简单，parallel 的线程切换开销 > 并行收益
list.stream().parallel().map(s -> s.length()).collect(Collectors.toList());

// ❌ IO 操作（数据库查询）使用 parallel，占满 ForkJoinPool，影响其他任务
list.stream().parallel().map(id -> dbService.findById(id)).collect(Collectors.toList());
```
parallel() 适用条件：
- 数据量大（> 10,000 条）
- 操作是 CPU 密集型（纯计算）
- 操作无副作用、无共享状态

```java
// ✅ 大数据量的纯计算任务，且用自定义线程池隔离
ForkJoinPool customPool = new ForkJoinPool(8);
List<Integer> result = customPool.submit(() ->
    bigList.stream().parallel().map(s -> heavyCompute(s)).collect(Collectors.toList())
).get();
```
### 坑 4：flatMap 中不能有 null 元素

```java
List<String> list = Arrays.asList("a,b", null, "c,d");

// ❌ flatMap 中 stream 返回 null 会抛 NullPointerException
List<String> flat = list.stream()
        .flatMap(s -> s == null ? null : Arrays.stream(s.split(","))) // ❌ null → NPE
        .collect(Collectors.toList());

// ✅ 过滤 null 或返回 Stream.empty()
List<String> flat = list.stream()
        .filter(Objects::nonNull)
        .flatMap(s -> Arrays.stream(s.split(",")))
        .collect(Collectors.toList());
```
### 坑 5：Optional 的 orElse 总是执行

```java
// ❌ 即使 Optional 有值，orElse 的参数也会被求值（构造开销浪费）
String result = Optional.of("value")
        .orElse(expensiveDefaultValue()); // expensiveDefaultValue() 总是被调用！

// ✅ 用 orElseGet，只在 Optional 为空时才执行
String result = Optional.of("value")
        .orElseGet(() -> expensiveDefaultValue()); // 惰性求值
```
### 坑 6：Collectors.toMap 遇到重复 key 抛异常

```java
List<User> users = Arrays.asList(
        new User(1, "Alice"),
        new User(1, "Bob")  // key=1 重复！
);

// ❌ 重复 key 时抛 IllegalStateException: Duplicate key 1
Map<Integer, String> map = users.stream()
        .collect(Collectors.toMap(User::getId, User::getName));

// ✅ 提供 merge function，指定重复 key 时的合并策略
Map<Integer, String> map = users.stream()
        .collect(Collectors.toMap(
                User::getId,
                User::getName,
                (existing, newVal) -> existing  // 保留第一个
        ));
```
### 坑 7：用 peek 做调试，勿用于生产副作用

```java
// ✅ peek 的正确用途：调试时查看中间结果
list.stream()
    .filter(s -> s.length() > 2)
    .peek(s -> System.out.println("After filter: " + s))  // 仅调试
    .map(String::toUpperCase)
    .collect(Collectors.toList());

// ❌ 在 peek 中做业务逻辑（如数据库写入）：
//    如果终止操作是 count()、anyMatch() 等短路操作，peek 不一定全部执行
list.stream()
    .peek(s -> db.save(s))   // ❌ 不保证每个元素都被 peek 到
    .anyMatch(s -> s.length() > 5);
```
### 坑 8：sorted + distinct 在大数据量下的性能陷阱

```java
// ❌ distinct() 底层用 HashSet，sorted() 需要全量排序，大量数据时内存压力大
bigList.stream()
       .sorted()     // 需要把所有元素加载到内存再排序
       .distinct()   // 全量去重，内存中维护 HashSet
       .collect(Collectors.toList());

// ✅ 数据库侧处理（ORDER BY / DISTINCT SQL）更合适大数据量场景
// 或者在进入 Stream 之前就先去重/排序
```
---

## 三、Stream vs for 循环选型

| 场景 | 推荐 | 理由 |
|------|------|------|
| 简单遍历 + 修改 | for 循环 | 无须引入 Stream 开销 |
| 多步转换（filter→map→collect）| Stream | 可读性高，链式表达更清晰 |
| 需要 break/continue 提前退出 | for 循环或 findFirst/anyMatch | Stream 无直接 break |
| IO 操作（DB/HTTP）| Stream（顺序），自定义线程池（并行）| 避免占满 ForkJoinPool |
| 大数据量 CPU 计算 | parallel Stream + 自定义线程池 | 并发收益大于开销 |
| 需要 index（遍历带下标）| IntStream.range + for | Stream 不直接提供 index |

---

## 四、总结与延伸

**8 个核心坑速记**：
1. forEach 内不要修改外部状态，用 collect 收集
2. Stream 只能消费一次
3. parallel() 不是万能提速，IO 操作禁止用默认 ForkJoinPool
4. flatMap 返回值不能为 null，用 Stream.empty() 代替
5. orElse 总是求值，有开销时用 orElseGet
6. toMap 有重复 key 必须提供 merge function
7. peek 仅用于调试，勿做业务副作用
8. sorted/distinct 大数据量有内存压力，考虑提前处理或在 DB 层做

**延伸阅读方向**：
- Collectors 进阶：groupingBy、partitioningBy、teeing（JDK 12+）
- Spliterator：Stream 并行分片的底层机制
- Reactive Streams（Reactor/RxJava）：处理背压的流式编程
- Java 21 的 SequencedCollection：有序集合的新统一接口
