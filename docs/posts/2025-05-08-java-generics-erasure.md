# Java 泛型擦除：你以为的类型安全，在运行时消失了

<div class="post-meta">📅 2025-05-08 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span></div>

List<String> 和 List<Integer> 在运行时居然是同一个类型？T t = new T() 为什么编译不过？泛型擦除是 Java 泛型实现的底层机制，也是无数奇怪编译错误和 ClassCastException 的根源。

---

## 一、背景：Java 泛型的历史包袱

Java 泛型诞生于 JDK 5（2004 年）。为了兼容大量已有的 JDK 1.4 字节码，Sun 选择了**类型擦除**方案：泛型信息只存在于编译期，编译后的字节码与 JDK 1.4 完全兼容，JVM 对泛型一无所知。

对比 C# 的"具体化泛型"（Reified Generics）：

| 特性 | Java 泛型（擦除式）| C# 泛型（具体化）|
|------|-----------------|----------------|
| 运行时类型信息 | ❌ 擦除，不存在 | ✅ 保留完整类型 |
| 
ew T() | ❌ 编译错误 | ✅ 合法 |
| T instanceof | ❌ 编译错误 | ✅ 合法 |
| 基本类型泛型 | ❌ 只能用包装类 | ✅ List<int> 合法 |
| 字节码兼容性 | ✅ 向后兼容 | ❌ 需要运行时支持 |

---

## 二、类型擦除的具体规则

编译器在生成字节码时，将泛型参数**替换为其上界**（无上界则替换为 Object）：

`java
// 编译前的源码
public class Box<T> {
    private T value;
    public T get() { return value; }
    public void set(T value) { this.value = value; }
}

// 编译后的字节码（等效 Java 代码）
public class Box {
    private Object value;         // T → Object
    public Object get() { return value; }
    public void set(Object value) { this.value = value; }
}
`

有上界时：

`java
// 源码
public class NumberBox<T extends Number> {
    public double doubleValue(T n) { return n.doubleValue(); }
}

// 擦除后
public class NumberBox {
    public double doubleValue(Number n) { return n.doubleValue(); }  // T → Number（上界）
}
`

**编译器自动插入强转**：

`java
Box<String> box = new Box<>();
box.set("hello");
String s = box.get();  // 编译器在 get() 调用处自动插入 checkcast java.lang.String
`

---

## 三、擦除引发的 5 类问题

### 3.1 无法在运行时获取泛型类型

`java
List<String> list = new ArrayList<>();
System.out.println(list.getClass());           // class java.util.ArrayList（无 String 信息）
System.out.println(list instanceof List<String>); // ❌ 编译错误
System.out.println(list instanceof List<?>);      // ✅ 只能用通配符
`

### 3.2 无法直接创建泛型类型实例

`java
public <T> T create() {
    return new T();  // ❌ 编译错误：Cannot instantiate type T
}

// ✅ 通过 Class<T> 反射创建
public <T> T create(Class<T> clazz) throws Exception {
    return clazz.getDeclaredConstructor().newInstance();
}
`

### 3.3 泛型数组不被允许

`java
List<String>[] arr = new List<String>[10];  // ❌ 编译错误：Generic array creation

// ✅ 用通配符
List<?>[] arr = new List<?>[10];

// ✅ 用 List<List<String>>
List<List<String>> lists = new ArrayList<>();
`

### 3.4 静态上下文中不能使用类型参数

`java
public class Singleton<T> {
    private static T instance;  // ❌ 静态字段不能用类型参数
    public static T getInstance() { return instance; }  // ❌
}
`

### 3.5 重载方法擦除后冲突

`java
public class Processor {
    public void process(List<String> list) {}  // ❌ 擦除后与下面方法签名相同
    public void process(List<Integer> list) {} // ❌ 编译错误：erasure of method... is the same
}
`

---

## 四、绕过擦除：保留运行时类型信息

### 4.1 TypeToken / ParameterizedTypeReference 模式

Jackson、Gson、Spring RestTemplate 都用这个模式解决泛型反序列化：

`java
// Gson TypeToken
Type type = new TypeToken<List<User>>() {}.getType();
List<User> users = gson.fromJson(json, type);

// Jackson TypeReference（原理相同）
List<User> users = mapper.readValue(json, new TypeReference<List<User>>() {});

// Spring RestTemplate
ResponseEntity<List<User>> response = restTemplate.exchange(
    url, HttpMethod.GET, null,
    new ParameterizedTypeReference<List<User>>() {}
);
`

**原理**：匿名子类的字节码中保留了泛型签名，通过 getClass().getGenericSuperclass() 可以在运行时获取。

### 4.2 Super Type Token 原理

`java
// 为什么匿名类能保留泛型信息？
abstract class TypeRef<T> {
    // 通过 getGenericSuperclass() 获取父类的泛型参数
    public Type getType() {
        ParameterizedType pt = (ParameterizedType) getClass().getGenericSuperclass();
        return pt.getActualTypeArguments()[0];
    }
}

TypeRef<List<String>> ref = new TypeRef<List<String>>() {};
System.out.println(ref.getType()); // java.util.List<java.lang.String>
`

匿名类的 class 文件中，Signature 属性保存了 TypeRef<List<String>> 的完整类型信息，不受擦除影响。

---

## 五、擦除与通配符的协同使用

`java
// ? extends T（协变，只读）
List<? extends Number> nums = new ArrayList<Integer>();
Number n = nums.get(0);  // ✅ 读取安全
nums.add(new Integer(1)); // ❌ 写入不安全（编译错误）

// ? super T（逆变，只写）
List<? super Integer> nums = new ArrayList<Number>();
nums.add(1);             // ✅ 写入安全
Integer i = nums.get(0); // ❌ 读取不安全（只能拿到 Object）

// PECS 原则：Producer Extends Consumer Super
// 作为生产者（读取数据）→ extends；作为消费者（写入数据）→ super
public static <T> void copy(List<? extends T> src, List<? super T> dst) {
    for (T item : src) dst.add(item);
}
`

---

## 六、常见坑点与最佳实践

### 坑 1：泛型方法返回类型依赖调用方推断

`java
public static <T> T firstOrNull(List<T> list) {
    return list.isEmpty() ? null : list.get(0);
}

// ❌ 错误理解：以为运行时能知道 T 是 String
Object o = firstOrNull(stringList);  // 编译器推断 T=Object

// ✅ 确保调用时有正确的上下文
String s = firstOrNull(stringList);  // 编译器推断 T=String，插入强转
`

### 坑 2：泛型类不能直接做 instanceof

`java
if (obj instanceof T) { }    // ❌ 编译错误
if (obj instanceof List) { } // ✅ 原始类型可以 instanceof

// ✅ 传入 Class 进行运行时类型检查
public <T> boolean isInstance(Object obj, Class<T> clazz) {
    return clazz.isInstance(obj);
}
`

### 坑 3：@SuppressWarnings("unchecked") 的合理使用

`java
// ❌ 不加注解让警告乱飞，降低代码可读性
List<String> list = (List<String>) getGenericList();

// ✅ 确认类型安全后，局部压制警告并加注释说明原因
@SuppressWarnings("unchecked")
List<String> list = (List<String>) getGenericList(); // 确保 getGenericList 只返回 String 元素
`

---

## 七、总结与延伸

**核心要点**：
- Java 泛型使用**类型擦除**实现，编译后泛型参数被替换为上界（默认 Object）
- 运行时无法通过 instanceof、
ew T()、泛型数组等操作使用类型参数
- 利用**匿名子类 + getGenericSuperclass()** 可以保留运行时泛型信息（TypeToken 模式）
- ? extends T（协变/只读）和 ? super T（逆变/只写）遵循 PECS 原则

**延伸阅读方向**：
- Java Reflection API：Type、ParameterizedType、TypeVariable、WildcardType 的完整类型系统
- Spring ResolvableType：对 Java 泛型反射 API 的封装，内部框架大量使用
- C# Reified Generics：对比了解具体化泛型的优缺点
- Valhalla 项目：Java 长期目标，引入 Value Types 和具体化泛型，彻底解决装箱性能问题
