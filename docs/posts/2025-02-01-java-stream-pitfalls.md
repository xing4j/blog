# Java 8 Stream 流式操作性能陷阱

<div class="post-meta">📅 2025-02-01 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">性能</span></div>

Stream API 使代码简洁优雅，但不当使用会带来严重的性能问题。本文总结 Stream 的常见陷阱与优化技巧。

---

## 一、陷阱一：在循环中创建 Stream

```java
// ❌ 每次循环都创建 Stream 对象，GC 压力大
for (int i = 0; i < 1000000; i++) {
    boolean exists = list.stream()
        .anyMatch(item -> item.getId() == targetId);
}

// ✅ 将集合转换为 Set，O(1) 查找
Set<Long> idSet = new HashSet<>(idList);
for (int i = 0; i < 1000000; i++) {
    boolean exists = idSet.contains(targetId);
}
```

---

## 二、陷阱二：collect 后再 stream

```java
// ❌ 中间 collect 破坏了流水线，产生中间集合
List<User> result = users.stream()
    .filter(u -> u.getAge() > 18)
    .collect(Collectors.toList())   // 多余的中间 collect
    .stream()
    .map(User::getName)
    .collect(Collectors.toList());

// ✅ 一次流水线完成
List<String> result = users.stream()
    .filter(u -> u.getAge() > 18)
    .map(User::getName)
    .collect(Collectors.toList());
```

---

## 三、陷阱三：parallelStream 滥用

```java
// ❌ 数据量小时 parallelStream 反而更慢（线程创建和合并开销）
List<String> names = list.stream()
    .parallel()
    .map(String::toUpperCase)
    .collect(Collectors.toList());

// ❌ parallelStream 中执行 IO 操作（阻塞 ForkJoinPool 公共线程）
list.parallelStream().forEach(item -> {
    dbService.save(item); // IO 阻塞！
});

// ✅ parallelStream 适合：数据量大（> 10000）且 CPU 密集型的纯计算
// ✅ IO 密集型改用自定义线程池
List<CompletableFuture<Void>> futures = list.stream()
    .map(item -> CompletableFuture.runAsync(() -> dbService.save(item), ioExecutor))
    .collect(Collectors.toList());
CompletableFuture.allOf(futures.toArray(new CompletableFuture[0])).join();
```

parallelStream 性能测试参考（列表大小 vs 耗时）：

| 数据量 | sequential | parallel | 结论 |
|--------|-----------|----------|------|
| 1,000 | 0.5ms | 2ms | sequential 更快 |
| 100,000 | 30ms | 12ms | parallel 开始有优势 |
| 1,000,000 | 280ms | 90ms | parallel 明显更快 |

---

## 四、陷阱四：distinct / sorted 操作代价高

```java
// distinct() 需要维护 HashSet 记录已见元素
// sorted() 需要全部收集后排序，破坏惰性求值

// ❌ distinct + sorted 双重代价
list.stream()
    .map(this::heavyTransform)   // 重计算
    .distinct()                   // 中间状态
    .sorted()                     // 全量排序
    .limit(10)
    .collect(Collectors.toList());

// ✅ 先 limit 再 distinct（减少需要去重的元素数量）
// 或提前在数据库层排序/去重（让数据库来做）
```

---

## 五、陷阱五：装箱/拆箱开销

```java
// ❌ Stream<Integer> 会自动装箱，大量数据时性能差
List<Integer> numbers = ...;
int sum = numbers.stream()
    .mapToInt(Integer::intValue)  // 这里还是会装箱后拆箱
    .sum();

// ✅ 对于 int/long/double，使用专用原始类型流
IntStream.range(0, 1000000).sum();   // 无装箱

int[] arr = {1, 2, 3, 4, 5};
IntStream.of(arr).sum();

// ✅ 从 List<Integer> 转为 IntStream
int sum = numbers.stream().mapToInt(Integer::intValue).sum();
```

| Stream 类型 | 装箱 | 适用场景 |
|------------|------|---------|
| `Stream<Integer>` | 有 | 对象流，有 null 需求 |
| `IntStream` | 无 | int 类型计算，性能优先 |
| `LongStream` | 无 | long 类型计算 |
| `DoubleStream` | 无 | double 类型计算 |

---

## 六、陷阱六：Collectors.groupingBy 结果未排序

```java
// groupingBy 返回的 Map 不保证顺序（默认 HashMap）
Map<String, List<User>> grouped = users.stream()
    .collect(Collectors.groupingBy(User::getDept));

// ✅ 需要有序时使用 TreeMap 或 LinkedHashMap
Map<String, List<User>> sorted = users.stream()
    .collect(Collectors.groupingBy(
        User::getDept,
        TreeMap::new,   // 指定 Map 工厂
        Collectors.toList()
    ));
```

---

## 七、Stream vs for 循环性能选择

| 场景 | 推荐 |
|------|------|
| 简单迭代（小数据量）| for 循环（更快，无对象创建）|
| 复杂变换链（可读性优先）| Stream |
| CPU 密集 + 大数据量 | parallelStream |
| IO 操作 | CompletableFuture + 自定义线程池 |
| 基本类型大量计算 | IntStream / LongStream |

---

## 总结

1. **避免在热点循环中创建 Stream**，频繁查找改用 Set/Map
2. **一次流水线**，不要中间 collect 再 stream
3. **parallelStream 慎用**：数据量小时反而慢，IO 操作时阻塞公共池
4. **大量数值计算**使用 IntStream/LongStream 避免装箱开销
5. **distinct/sorted** 是有状态操作，尽早过滤减少操作数量
