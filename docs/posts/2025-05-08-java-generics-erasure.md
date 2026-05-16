# Java 泛型擦除与类型推断那些坑

<div class="post-meta">📅 2025-05-08 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span></div>

Java 泛型是编译期的语法糖，运行时会被擦除。理解类型擦除机制，才能避免那些令人困惑的编译错误和运行时异常。

---

## 一、类型擦除是什么

Java 泛型在编译后，类型参数会被**擦除**为其上界（无上界则为 `Object`），字节码中不保留泛型信息。

```java
// 编译前
List<String> strList = new ArrayList<String>();
List<Integer> intList = new ArrayList<Integer>();

// 编译后（字节码等价）
List strList = new ArrayList();
List intList = new ArrayList();

// 运行时，两者类型相同！
System.out.println(strList.getClass() == intList.getClass()); // true
```

---

## 二、常见陷阱

### 陷阱一：不能用泛型类型创建对象或数组

```java
public class Box<T> {
    // ❌ 编译错误：类型擦除后不知道 T 是什么
    T item = new T();
    T[] items = new T[10];

    // ✅ 通过 Class 参数传入类型信息
    private final Class<T> type;
    public Box(Class<T> type) { this.type = type; }

    public T newInstance() throws Exception {
        return type.getDeclaredConstructor().newInstance();
    }
}
```

### 陷阱二：instanceof 不能用于泛型类型

```java
// ❌ 编译错误
if (obj instanceof List<String>) { }

// ✅ 只能检查原始类型
if (obj instanceof List<?>) {
    List<?> list = (List<?>) obj;
}
```

### 陷阱三：泛型类型不能用于重载区分

```java
// ❌ 编译错误：擦除后两个方法签名相同
public void process(List<String> list) { }
public void process(List<Integer> list) { }

// ✅ 改用不同方法名
public void processStrings(List<String> list) { }
public void processIntegers(List<Integer> list) { }
```

### 陷阱四：泛型静态字段共享

```java
// ❌ 误以为 Box<Integer> 和 Box<String> 有不同的 instance
public class Box<T> {
    private static T instance; // 编译错误！静态字段不能使用类型参数
}

// 泛型类的所有实例化共享同一份字节码
```

### 陷阱五：List<String> 不是 List<Object> 的子类

```java
// ❌ 编译错误：不能将 List<String> 赋给 List<Object>
List<String> strings = new ArrayList<>();
List<Object> objects = strings; // 编译错误！

// ✅ 使用通配符
List<? extends Object> wildcards = strings; // OK，但只读

// 理解：如果允许上述赋值，则可以往 objects 中加入 Integer，
// 而 strings 引用的实际是同一列表，会破坏类型安全
```

---

## 三、通配符 ? 的正确使用

### 上界通配符（? extends T）—— 生产者

```java
// 只读，适合作为数据来源
public double sum(List<? extends Number> list) {
    return list.stream().mapToDouble(Number::doubleValue).sum();
}

// 可以传入 List<Integer>、List<Double>、List<Long>
sum(Arrays.asList(1, 2, 3));       // List<Integer>
sum(Arrays.asList(1.0, 2.0));      // List<Double>
```

### 下界通配符（? super T）—— 消费者

```java
// 只写，适合作为数据接收者
public void addNumbers(List<? super Integer> list) {
    list.add(1);
    list.add(2);
}

// 可以传入 List<Integer>、List<Number>、List<Object>
```

### PECS 原则

> **Producer Extends, Consumer Super**（生产者用 extends，消费者用 super）

```java
// Collections.copy 的签名完美体现 PECS
public static <T> void copy(
    List<? super T> dest,    // 消费者，super
    List<? extends T> src    // 生产者，extends
) { ... }
```

---

## 四、运行时获取泛型信息

虽然运行时泛型被擦除，但通过**反射 + 类定义**可以获取部分信息：

```java
// 获取父类的泛型参数（必须是具体子类，不能是泛型类本身）
public class UserRepository extends BaseRepository<User> { }

Type superclass = UserRepository.class.getGenericSuperclass();
ParameterizedType pt = (ParameterizedType) superclass;
Type[] types = pt.getActualTypeArguments();
Class<?> entityClass = (Class<?>) types[0]; // User.class
```

Spring Data JPA、MyBatis-Plus 等框架正是用此技术自动推断实体类型。

---

## 五、类型推断（var 关键字，Java 10+）

```java
// var 让编译器推断类型，减少冗余
var list = new ArrayList<String>();   // 推断为 ArrayList<String>
var map = new HashMap<String, List<User>>(); // 推断复杂泛型类型

// 注意：var 是局部变量类型推断，不能用于：
// - 方法参数
// - 返回值类型
// - 类字段

// ❌
public var getUser() { return new User(); }

// 菱形操作符 <> 也是类型推断（Java 7+）
List<String> list = new ArrayList<>(); // 右侧 <> 自动推断
```

---

## 总结

| 概念 | 要点 |
|------|------|
| 类型擦除 | 编译后泛型参数消失，不能 instanceof、不能 new T() |
| 上界通配符 | `? extends T`，只读（生产者）|
| 下界通配符 | `? super T`，只写（消费者）|
| PECS 原则 | 生产者 extends，消费者 super |
| 运行时泛型 | 通过 `getGenericSuperclass()` 获取父类泛型参数 |
| 类型推断 | Java 7+ `<>`，Java 10+ `var` |
