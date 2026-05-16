# Java 8 新特性全面实战指南

<div class="post-meta">📅 2026-05-16 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span></div>

Java 8 是 Java 发展史上最具里程碑意义的版本，引入了 Lambda 表达式、Stream API、全新时间 API 等重磅特性，彻底改变了 Java 的编程范式。本文结合实际业务场景，系统梳理 Java 8 核心特性的用法与原理。

---

## 一、Lambda 表达式

### 1.1 为什么需要 Lambda

Lambda 是一个**匿名函数**，可以把代码像数据一样传递，让代码更简洁、更灵活。

```java
// 传统匿名内部类：冗余代码多
Comparator<String> comp1 = new Comparator<String>() {
    @Override
    public int compare(String o1, String o2) {
        return o1.compareTo(o2);
    }
};

// Lambda 表达式：简洁直观
Comparator<String> comp2 = (o1, o2) -> o1.compareTo(o2);

// 更进一步，方法引用
Comparator<String> comp3 = String::compareTo;
```

### 1.2 Lambda 语法格式

Lambda 操作符 `->` 将表达式分为左侧（参数列表）和右侧（Lambda 体）。

```java
// 格式一：无参，无返回值
Runnable r = () -> System.out.println("Hello Lambda");

// 格式二：一个参数（参数括号可省略）
Consumer<String> c = name -> System.out.println(name);

// 格式三：两个参数，有返回值
BinaryOperator<Integer> add = (a, b) -> a + b;

// 格式四：多条语句，需要花括号和 return
BinaryOperator<Integer> max = (a, b) -> {
    System.out.println("比较中...");
    return a > b ? a : b;
};
```

### 1.3 类型推断

Lambda 表达式的参数类型由编译器根据上下文自动推断，无需显式声明：

```java
// 编译器可推断出 x 是 Integer
List<Integer> list = Arrays.asList(1, 3, 2, 5, 4);
list.sort((x, y) -> x - y);  // x, y 类型无需声明

// 等价的显式写法
list.sort((Integer x, Integer y) -> x - y);
```

---

## 二、函数式接口

### 2.1 什么是函数式接口

**只包含一个抽象方法**的接口称为函数式接口，可用 `@FunctionalInterface` 标注。Lambda 表达式的类型就是对应的函数式接口。

```java
@FunctionalInterface
public interface Converter<F, T> {
    T convert(F from);
}

// 使用 Lambda 创建实例
Converter<String, Integer> converter = Integer::valueOf;
Integer result = converter.convert("123"); // 123
```

### 2.2 四大核心函数式接口

| 接口 | 参数 | 返回值 | 用途 |
|------|------|--------|------|
| `Consumer<T>` | T | void | 消费数据 |
| `Supplier<T>` | 无 | T | 生产数据 |
| `Function<T, R>` | T | R | 数据转换 |
| `Predicate<T>` | T | boolean | 条件判断 |

```java
// Consumer：消费型，只入不出
Consumer<String> printer = System.out::println;
printer.accept("Hello");

// Supplier：供给型，只出不入
Supplier<List<String>> listFactory = ArrayList::new;
List<String> newList = listFactory.get();

// Function：函数型，输入转输出
Function<String, Integer> strToInt = Integer::parseInt;
int num = strToInt.apply("42"); // 42

// Function 链式调用
Function<String, String> trim = String::trim;
Function<String, String> upper = String::toUpperCase;
Function<String, String> process = trim.andThen(upper);
System.out.println(process.apply("  hello  ")); // "HELLO"

// Predicate：断言型，返回 boolean
Predicate<String> notEmpty = s -> !s.isEmpty();
Predicate<String> longEnough = s -> s.length() > 5;
Predicate<String> combined = notEmpty.and(longEnough);
System.out.println(combined.test("Hello World")); // true
```

### 2.3 实战：策略模式简化

```java
// 传统策略模式需要大量接口实现类
// 用函数式接口 + Lambda 一行搞定
Map<String, Function<Double, Double>> discountStrategies = new HashMap<>();
discountStrategies.put("VIP",    price -> price * 0.8);
discountStrategies.put("MEMBER", price -> price * 0.9);
discountStrategies.put("NORMAL", price -> price);

double finalPrice = discountStrategies
    .getOrDefault("VIP", p -> p)
    .apply(100.0); // 80.0
```

---

## 三、方法引用与构造器引用

### 3.1 方法引用的四种形式

当 Lambda 体已有现成方法实现时，可用 `::` 操作符直接引用，代码更简洁。

```java
// 1. 实例方法引用（对象::实例方法）
PrintStream ps = System.out;
Consumer<String> c1 = ps::println;
// 等价于：s -> ps.println(s)

// 2. 静态方法引用（类::静态方法）
Function<String, Integer> f1 = Integer::parseInt;
// 等价于：s -> Integer.parseInt(s)

// 3. 实例方法引用（类::实例方法）—— 第一个参数是调用对象
BiPredicate<String, String> bp = String::contains;
// 等价于：(s1, s2) -> s1.contains(s2)

Function<String, String> upper = String::toUpperCase;
// 等价于：s -> s.toUpperCase()
```

### 3.2 构造器引用

```java
// 无参构造器
Supplier<User> userFactory = User::new;
User user = userFactory.get();

// 有参构造器（自动匹配参数列表）
BiFunction<String, Integer, User> userBuilder = User::new;
User user2 = userBuilder.apply("张三", 25);
```

### 3.3 数组引用

```java
// 创建指定长度的数组
Function<Integer, String[]> arrayFactory = String[]::new;
String[] arr = arrayFactory.apply(5); // new String[5]
```

---

## 四、Stream API

Stream API 是 Java 8 最强大的特性之一，提供了流水线式的数据处理能力，类似 SQL 操作集合数据。

> **核心特点**：不存储数据、不修改源数据、操作延迟执行（惰性求值）

### 4.1 创建 Stream 的方式

```java
// 1. 集合创建
List<String> list = Arrays.asList("a", "b", "c");
Stream<String> stream1 = list.stream();          // 顺序流
Stream<String> stream2 = list.parallelStream();  // 并行流

// 2. 数组创建
int[] arr = {1, 2, 3, 4, 5};
IntStream intStream = Arrays.stream(arr);

// 3. Stream.of()
Stream<String> stream3 = Stream.of("x", "y", "z");

// 4. 无限流（迭代）
Stream<Integer> evenNumbers = Stream.iterate(0, n -> n + 2);
evenNumbers.limit(5).forEach(System.out::println); // 0 2 4 6 8

// 5. 无限流（生成）
Stream<Double> randoms = Stream.generate(Math::random);
randoms.limit(3).forEach(System.out::println);
```

### 4.2 中间操作：筛选、映射、排序

```java
List<Employee> employees = getEmployees();

// filter：过滤
List<Employee> highSalary = employees.stream()
    .filter(e -> e.getSalary() > 10000)
    .collect(Collectors.toList());

// map：转换
List<String> names = employees.stream()
    .map(Employee::getName)
    .collect(Collectors.toList());

// flatMap：扁平化（一对多展开）
List<String> words = Arrays.asList("Hello World", "Java 8");
List<String> letters = words.stream()
    .flatMap(s -> Arrays.stream(s.split(" ")))
    .collect(Collectors.toList()); // ["Hello", "World", "Java", "8"]

// distinct + sorted + limit + skip
List<Integer> result = Stream.of(3, 1, 4, 1, 5, 9, 2, 6, 5)
    .distinct()           // 去重：3,1,4,5,9,2,6
    .sorted()             // 排序：1,2,3,4,5,6,9
    .skip(2)              // 跳过前2个：3,4,5,6,9
    .limit(3)             // 取前3个：3,4,5
    .collect(Collectors.toList());
```

### 4.3 终止操作：查找、统计、归约

```java
List<Integer> nums = Arrays.asList(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);

// 匹配
boolean allPositive  = nums.stream().allMatch(n -> n > 0);   // true
boolean hasEven      = nums.stream().anyMatch(n -> n % 2 == 0); // true
boolean noneNegative = nums.stream().noneMatch(n -> n < 0);  // true

// 查找
Optional<Integer> first = nums.stream().filter(n -> n > 5).findFirst(); // 6
Optional<Integer> any   = nums.stream().parallel().findAny();

// 统计
long count = nums.stream().filter(n -> n % 2 == 0).count(); // 5
Optional<Integer> max = nums.stream().max(Integer::compareTo); // 10
Optional<Integer> min = nums.stream().min(Integer::compareTo); // 1

// reduce：归约
int sum = nums.stream().reduce(0, Integer::sum);           // 55
Optional<Integer> product = nums.stream().reduce((a, b) -> a * b);
```

### 4.4 Collectors 收集器

```java
List<Employee> employees = getEmployees();

// 收集到各种容器
List<String>       nameList = employees.stream().map(Employee::getName).collect(Collectors.toList());
Set<String>        nameSet  = employees.stream().map(Employee::getName).collect(Collectors.toSet());
String             nameStr  = employees.stream().map(Employee::getName).collect(Collectors.joining(", "));

// 统计
Long   count   = employees.stream().collect(Collectors.counting());
Double avgSal  = employees.stream().collect(Collectors.averagingDouble(Employee::getSalary));
Double sumSal  = employees.stream().collect(Collectors.summingDouble(Employee::getSalary));
Optional<Employee> richest = employees.stream()
    .collect(Collectors.maxBy(Comparator.comparingDouble(Employee::getSalary)));

// 分组
Map<String, List<Employee>> byDept = employees.stream()
    .collect(Collectors.groupingBy(Employee::getDepartment));

// 多级分组
Map<String, Map<String, List<Employee>>> byDeptAndStatus = employees.stream()
    .collect(Collectors.groupingBy(Employee::getDepartment,
             Collectors.groupingBy(Employee::getStatus)));

// 分区（按 true/false 分组）
Map<Boolean, List<Employee>> partitioned = employees.stream()
    .collect(Collectors.partitioningBy(e -> e.getSalary() > 10000));

// 分组后统计数量
Map<String, Long> countByDept = employees.stream()
    .collect(Collectors.groupingBy(Employee::getDepartment, Collectors.counting()));
```

### 4.5 并行流与 Fork/Join

并行流将数据分块，用多线程分别处理后合并，底层依赖 **Fork/Join 框架**的工作窃取算法。

```java
// 顺序流
long seqResult = LongStream.rangeClosed(1, 100_000_000L)
    .reduce(0, Long::sum);

// 并行流（大数据量时更快）
long parResult = LongStream.rangeClosed(1, 100_000_000L)
    .parallel()
    .reduce(0, Long::sum);

// 在顺序流和并行流之间切换
Stream<Integer> stream = list.stream()
    .parallel()   // 切换为并行
    .filter(...)
    .sequential() // 切回顺序
    .map(...);
```

> **注意**：并行流不适合小数据量（线程开销大于收益）和涉及 IO 的操作（会阻塞 ForkJoinPool 公共线程池）。

---

## 五、新时间日期 API

Java 8 引入 `java.time` 包，彻底解决了 `Date`/`Calendar` 的线程不安全、API 设计混乱等问题。

### 5.1 LocalDate / LocalTime / LocalDateTime

不可变对象，不含时区信息，适合业务日期处理。

```java
// 创建
LocalDate date = LocalDate.now();                     // 2026-05-16
LocalDate birthday = LocalDate.of(1990, 8, 15);
LocalTime time = LocalTime.now();                     // 14:30:25.123
LocalDateTime dt = LocalDateTime.now();

// 日期加减
LocalDate nextWeek  = date.plusWeeks(1);
LocalDate lastMonth = date.minusMonths(1);
LocalDate nextYear  = date.plusYears(1);

// 修改特定字段
LocalDate firstDayOfMonth = date.withDayOfMonth(1);
LocalDate birthday2026 = birthday.withYear(2026);

// 获取字段
int year       = date.getYear();
int month      = date.getMonthValue(); // 1-12
int day        = date.getDayOfMonth();
DayOfWeek week = date.getDayOfWeek();  // SATURDAY

// 比较
boolean isBefore  = birthday.isBefore(date);
boolean isLeap    = date.isLeapYear();

// 格式化
DateTimeFormatter fmt = DateTimeFormatter.ofPattern("yyyy年MM月dd日");
String formatted = date.format(fmt);      // "2026年05月16日"
LocalDate parsed = LocalDate.parse("2026年05月16日", fmt);
```

### 5.2 Instant 时间戳

以 Unix 元年（1970-01-01 00:00:00 UTC）为基准，精度可达纳秒。

```java
Instant now = Instant.now();                   // 当前UTC时刻
Instant later = now.plusSeconds(3600);         // 1小时后
long epochMilli = now.toEpochMilli();          // 毫秒时间戳

// 与 Date 互转
Date legacyDate = Date.from(now);
Instant fromDate = legacyDate.toInstant();
```

### 5.3 Duration 和 Period

```java
// Duration：计算时间间隔（时、分、秒、纳秒）
LocalTime start = LocalTime.of(9, 0);
LocalTime end   = LocalTime.of(18, 30);
Duration workTime = Duration.between(start, end);
System.out.println(workTime.toHours());   // 9
System.out.println(workTime.toMinutes()); // 570

// Period：计算日期间隔（年、月、日）
LocalDate birth = LocalDate.of(1990, 8, 15);
LocalDate today = LocalDate.now();
Period age = Period.between(birth, today);
System.out.printf("年龄：%d 岁 %d 月 %d 天%n",
    age.getYears(), age.getMonths(), age.getDays());
```

### 5.4 TemporalAdjuster 时间校正器

```java
LocalDate today = LocalDate.now();

// 内置调整器
LocalDate nextSunday   = today.with(TemporalAdjusters.next(DayOfWeek.SUNDAY));
LocalDate firstOfMonth = today.with(TemporalAdjusters.firstDayOfMonth());
LocalDate lastOfYear   = today.with(TemporalAdjusters.lastDayOfYear());
LocalDate firstOfNext  = today.with(TemporalAdjusters.firstDayOfNextMonth());

// 自定义调整器：下一个工作日
TemporalAdjuster nextWorkday = temporal -> {
    LocalDate d = LocalDate.from(temporal);
    do {
        d = d.plusDays(1);
    } while (d.getDayOfWeek() == DayOfWeek.SATURDAY
          || d.getDayOfWeek() == DayOfWeek.SUNDAY);
    return d;
};
LocalDate nextBizDay = today.with(nextWorkday);
```

### 5.5 时区处理

```java
// 查看所有时区
Set<String> allZones = ZoneId.getAvailableZoneIds();

ZoneId shanghaiZone = ZoneId.of("Asia/Shanghai");
ZoneId newYorkZone  = ZoneId.of("America/New_York");

// 带时区的日期时间
ZonedDateTime shanghaiTime = ZonedDateTime.now(shanghaiZone);
ZonedDateTime newYorkTime  = ZonedDateTime.now(newYorkZone);

// 时区转换
ZonedDateTime converted = shanghaiTime.withZoneSameInstant(newYorkZone);
```

### 5.6 与传统 API 互转

```java
// Instant <-> Date
Date date = Date.from(Instant.now());
Instant inst = date.toInstant();

// LocalDateTime <-> Timestamp
Timestamp ts = Timestamp.valueOf(LocalDateTime.now());
LocalDateTime ldt = ts.toLocalDateTime();

// LocalDate <-> java.sql.Date
java.sql.Date sqlDate = java.sql.Date.valueOf(LocalDate.now());
LocalDate ld = sqlDate.toLocalDate();

// TimeZone <-> ZoneId
ZoneId zoneId = TimeZone.getDefault().toZoneId();
```

---

## 六、接口默认方法与静态方法

### 6.1 默认方法

Java 8 允许接口包含带具体实现的 `default` 方法，解决接口演进难题（无需修改所有实现类）。

```java
public interface Vehicle {
    // 抽象方法
    String getBrand();

    // 默认方法
    default String describe() {
        return "品牌：" + getBrand();
    }

    // 另一个默认方法，可复用其他默认方法
    default void printInfo() {
        System.out.println(describe());
    }
}

// 实现类可以直接使用默认方法，无需重写
public class Car implements Vehicle {
    @Override
    public String getBrand() { return "Toyota"; }
    // describe() 和 printInfo() 继承自接口
}
```

### 6.2 默认方法冲突解决

**类优先原则**：父类的具体实现优先于接口默认方法；若多个接口有同名默认方法，必须手动覆盖。

```java
interface A {
    default void hello() { System.out.println("A"); }
}
interface B {
    default void hello() { System.out.println("B"); }
}

// ❌ 编译报错：接口冲突，必须覆盖
class C implements A, B {
    @Override
    public void hello() {
        A.super.hello(); // 显式选择调用 A 的默认方法
    }
}

// 父类优先于接口默认方法
class Parent {
    public void hello() { System.out.println("Parent"); }
}
class Child extends Parent implements A {
    // 自动使用 Parent.hello()，接口 A 的默认方法被忽略
}
```

### 6.3 静态方法

Java 8 接口中可定义静态工具方法，不再需要单独的工具类（如 `Collections`）。

```java
public interface StringUtils {
    static boolean isNullOrEmpty(String s) {
        return s == null || s.isEmpty();
    }

    static String requireNonEmpty(String s, String message) {
        if (isNullOrEmpty(s)) throw new IllegalArgumentException(message);
        return s;
    }
}

// 直接通过接口名调用
boolean empty = StringUtils.isNullOrEmpty("");  // true
```

---

## 七、Optional 类

`Optional<T>` 是一个容器类，显式表达"值可能不存在"，从根源上减少 `NullPointerException`。

### 7.1 创建 Optional

```java
// 确定有值
Optional<String> opt1 = Optional.of("hello");

// 可能为 null（推荐用法）
Optional<String> opt2 = Optional.ofNullable(null);
Optional<String> opt3 = Optional.ofNullable("world");

// 空 Optional
Optional<String> empty = Optional.empty();
```

### 7.2 获取值

```java
Optional<String> opt = Optional.ofNullable(getValue());

// 直接获取（不存在时抛 NoSuchElementException，不推荐）
String s1 = opt.get();

// 提供默认值（推荐）
String s2 = opt.orElse("默认值");
String s3 = opt.orElseGet(() -> computeDefault());  // 惰性求值

// 不存在时抛自定义异常
String s4 = opt.orElseThrow(() -> new BusinessException("数据不存在"));
```

### 7.3 链式操作

```java
// isPresent() + get() 仍是反模式，应用 map/flatMap
// ❌ 不推荐
if (opt.isPresent()) {
    String val = opt.get().toUpperCase();
}

// ✅ 推荐：map 转换
Optional<String> upper = opt.map(String::toUpperCase);

// flatMap：当映射结果本身是 Optional
Optional<User> userOpt = findUser(userId);
Optional<String> email = userOpt.flatMap(User::getEmail); // getEmail() 返回 Optional<String>

// filter：满足条件才保留
Optional<String> longStr = opt.filter(s -> s.length() > 5);

// ifPresent：存在时消费
opt.ifPresent(System.out::println);
```

### 7.4 实战：消除多层判空

```java
// 传统写法：嵌套判空，代码丑陋
public String getCityName(User user) {
    if (user != null) {
        Address address = user.getAddress();
        if (address != null) {
            City city = address.getCity();
            if (city != null) {
                return city.getName();
            }
        }
    }
    return "未知";
}

// Optional 写法：链式优雅
public String getCityName(User user) {
    return Optional.ofNullable(user)
        .map(User::getAddress)
        .map(Address::getCity)
        .map(City::getName)
        .orElse("未知");
}
```

---

## 八、其他新特性

### 8.1 重复注解

Java 8 之前，同一注解不能在同一位置重复使用；Java 8 通过 `@Repeatable` 解决了这个问题。

```java
@Repeatable(Schedules.class)
@interface Schedule {
    String cron();
}

@Retention(RetentionPolicy.RUNTIME)
@interface Schedules {
    Schedule[] value();
}

// 同一方法上重复使用同一注解
@Schedule(cron = "0 0 8 * * ?")
@Schedule(cron = "0 0 20 * * ?")
public void dailyTask() { ... }
```

### 8.2 类型注解

Java 8 扩展了注解使用范围，可标注在类型使用处（泛型、强转、instanceof 等）。

```java
// 泛型类型参数
List<@NonNull String> list = new ArrayList<>();

// 强制类型转换
String s = (@NonNull String) obj;

// 实现接口
class MyList<E> implements @Readonly List<@Readonly E> { ... }
```

---

## 九、综合实战：员工数据分析

用 Java 8 特性完成一个完整的数据分析场景：

```java
@Data
@AllArgsConstructor
public class Employee {
    private String name;
    private String department;
    private double salary;
    private int age;
    private LocalDate joinDate;
}

public class EmployeeAnalysis {
    private List<Employee> employees = Arrays.asList(
        new Employee("张三", "研发", 15000, 28, LocalDate.of(2020, 3, 1)),
        new Employee("李四", "研发", 18000, 32, LocalDate.of(2019, 6, 15)),
        new Employee("王五", "市场", 12000, 25, LocalDate.of(2022, 1, 10)),
        new Employee("赵六", "市场", 13500, 30, LocalDate.of(2021, 9, 5)),
        new Employee("钱七", "运营", 11000, 27, LocalDate.of(2023, 3, 20)),
        new Employee("孙八", "研发", 22000, 35, LocalDate.of(2018, 11, 1))
    );

    public void analyze() {
        // 1. 各部门平均薪资
        Map<String, Double> avgSalaryByDept = employees.stream()
            .collect(Collectors.groupingBy(
                Employee::getDepartment,
                Collectors.averagingDouble(Employee::getSalary)));
        avgSalaryByDept.forEach((dept, avg) ->
            System.out.printf("%s 部门平均薪资：%.0f%n", dept, avg));

        // 2. 薪资最高的员工
        employees.stream()
            .max(Comparator.comparingDouble(Employee::getSalary))
            .map(e -> e.getName() + "：" + e.getSalary())
            .ifPresent(s -> System.out.println("薪资最高：" + s));

        // 3. 研发部门 30 岁以下员工姓名（按薪资降序）
        List<String> youngDevs = employees.stream()
            .filter(e -> "研发".equals(e.getDepartment()))
            .filter(e -> e.getAge() < 30)
            .sorted(Comparator.comparingDouble(Employee::getSalary).reversed())
            .map(Employee::getName)
            .collect(Collectors.toList());
        System.out.println("研发部30岁以下员工：" + youngDevs);

        // 4. 入职满 3 年的员工数
        LocalDate threshold = LocalDate.now().minusYears(3);
        long seniorCount = employees.stream()
            .filter(e -> e.getJoinDate().isBefore(threshold))
            .count();
        System.out.println("入职满3年：" + seniorCount + " 人");

        // 5. 统计每个部门的薪资汇总信息
        Map<String, DoubleSummaryStatistics> statsMap = employees.stream()
            .collect(Collectors.groupingBy(
                Employee::getDepartment,
                Collectors.summarizingDouble(Employee::getSalary)));
        statsMap.forEach((dept, stats) ->
            System.out.printf("%s - 总计:%.0f 最高:%.0f 最低:%.0f%n",
                dept, stats.getSum(), stats.getMax(), stats.getMin()));

        // 6. 所有员工姓名拼接
        String allNames = employees.stream()
            .map(Employee::getName)
            .collect(Collectors.joining("、", "员工名单：[", "]"));
        System.out.println(allNames);
    }
}
```

---

## 十、总结

| 特性 | 核心价值 |
|------|---------|
| Lambda 表达式 | 函数式编程，代码简洁，可传递行为 |
| 函数式接口 | 为 Lambda 提供类型，内置 Consumer/Supplier/Function/Predicate |
| 方法引用 | Lambda 的极简写法，直接复用已有方法 |
| Stream API | 声明式数据处理，支持链式操作和并行计算 |
| 新时间 API | 不可变、线程安全，API 设计清晰 |
| 接口默认/静态方法 | 接口演进友好，替代工具类 |
| Optional | 显式处理 null，减少 NPE 风险 |

Java 8 的这些特性共同推动了 Java 向函数式编程的迈进，熟练掌握后能显著提升代码质量和开发效率。
