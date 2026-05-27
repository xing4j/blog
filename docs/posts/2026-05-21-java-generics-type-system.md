# Java 泛型类型系统深度解析：Type 接口体系与反射获取

<div class="post-meta">📅 2026-05-21 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span></div>

在阅读 MyBatis、Spring、FastJSON 等框架源码时，你一定见过 `ParameterizedType`、`TypeVariable`、`WildcardType` 这些类型。它们是 Java 泛型类型系统的基石，理解它们，才能真正看懂框架如何在运行时"感知"泛型信息——明明类型擦除了，框架却还能知道 `Mapper<UserModel>` 里的 `UserModel` 是什么。

本文基于 `java.lang.reflect` 包，系统讲解 Java 泛型类型体系的五大接口，并通过一套完整的示例贯穿始终，最后以 FastJSON 的 `TypeReference` 为例，揭示这套机制在真实框架中的运用。

---

## 一、背景：类型擦除之后还剩什么

Java 泛型是 1.5 引入的编译期特性，为了保持与旧版字节码的兼容性，泛型信息在编译后会被**擦除**：`List<String>` 和 `List<Integer>` 在运行时都变成了 `List`。

但"擦除"并非"完全消失"。Java 在字节码的 `Signature` 属性中保留了泛型的**签名信息**，反射 API 可以读取到它。这正是 `java.lang.reflect.Type` 接口体系的价值所在——它让我们可以在运行时精确获取泛型的完整类型信息。

下面这张类图展示了整个体系的结构：

```
Type（顶层接口）
+-- Class<T>                  <- 普通类型，如 String、Integer
+-- ParameterizedType         <- 参数化类型，如 List<String>、Map<K,V>
+-- TypeVariable<D>           <- 泛型变量，如 T、K、V
+-- WildcardType              <- 通配符类型，如 ? extends Number
+-- GenericArrayType          <- 泛型数组，如 T[]、List<String>[]
```

`GenericDeclaration` 是一个额外的接口，被 `Class` 和 `Method` 实现，用于获取类或方法上**声明的**泛型变量列表。

---

## 二、Type 顶层接口

`Type` 是所有类型的公共超接口，源码极为简单：

```java
public interface Type {
    // 返回类型名称，默认调用 toString()
    default String getTypeName() {
        return toString();
    }
}
```

Java 中的所有类型，包括原始类型、数组、泛型类、通配符等，都可以用 `Type` 来统一表示。实际使用中，我们拿到一个 `Type` 后，通常通过 `instanceof` 判断其具体子类型，再进行强转。

---

## 三、五大子接口详解

### 3.1 ParameterizedType — 参数化类型

表示带有具体类型参数的泛型，如 `List<String>`、`Map<Integer, String>`、`UserMapper<UserModel>`。

```java
public interface ParameterizedType extends Type {
    // 获取 <> 中的类型参数列表，如 List<String> 返回 [String]
    Type[] getActualTypeArguments();
    // 获取 < 前的原始类型，如 List<String> 返回 List
    Type getRawType();
    // 获取所属类型，用于成员内部类，顶层类返回 null
    Type getOwnerType();
}
```

**常见场景**：方法参数/返回值为 `Map<String, List<User>>`，或继承 `BaseMapper<User>` 这类泛型父类。

---

### 3.2 TypeVariable — 泛型变量

表示在类或方法上**声明的**泛型占位符，如 `class Foo<T>` 中的 `T`，`<K extends Comparable<K>>` 中的 `K`。

```java
public interface TypeVariable<D extends GenericDeclaration> extends Type {
    // 获取上界列表，如 T extends Comparable & Serializable 返回两个上界
    // 若未声明上界，默认上界为 Object
    Type[] getBounds();
    // 获取声明此变量的类或方法（即 Class 或 Method 对象）
    D getGenericDeclaration();
    // 获取变量名称，如 T、K、V
    String getName();
}
```

---

### 3.3 WildcardType — 通配符类型

表示泛型通配符，如 `? extends Number`、`? super Integer`。注意：`?` 本身不是变量，不能在类定义中声明，只能出现在泛型参数位置。

```java
public interface WildcardType extends Type {
    // 上界列表，如 ? extends Number 返回 [Number]；无上界时返回 [Object]
    Type[] getUpperBounds();
    // 下界列表，如 ? super Integer 返回 [Integer]；无下界时返回空数组
    Type[] getLowerBounds();
}
```

---

### 3.4 GenericArrayType — 泛型数组

表示数组元素为泛型的数组，如 `T[]`、`List<String>[]`。

```java
public interface GenericArrayType extends Type {
    // 返回数组元素的类型，如 List<String>[] 返回 List<String>（ParameterizedType）
    Type getGenericComponentType();
}
```

---

### 3.5 GenericDeclaration — 泛型声明接口

这是一个独立接口，被 `Class` 和 `Method` 实现，表示"可以声明泛型变量的地方"：

```java
public interface GenericDeclaration {
    // 返回此类/方法上声明的泛型变量列表
    TypeVariable<?>[] getTypeParameters();
}
```

---

## 四、Class 与 Method 的泛型相关 API

### Class 中的关键方法

| 方法 | 说明 |
|------|------|
| `TypeVariable<?>[] getTypeParameters()` | 获取类上声明的泛型变量（来自 `GenericDeclaration`） |
| `Type getGenericSuperclass()` | 获取父类的完整类型（含泛型参数） |
| `Type[] getGenericInterfaces()` | 获取实现接口的完整类型 |
| `Field[] getDeclaredFields()` | 获取本类所有字段（不含父类） |
| `Field[] getFields()` | 获取本类及父类的所有 `public` 字段 |

> 凡是方法名含有 **Generic** 的，都返回带泛型信息的类型。

### Method 中的关键方法

| 方法 | 说明 |
|------|------|
| `Type[] getGenericParameterTypes()` | 获取方法参数类型列表（含泛型信息） |
| `Type getGenericReturnType()` | 获取方法返回值类型（含泛型信息） |
| `TypeVariable<Method>[] getTypeParameters()` | 获取方法上声明的泛型变量 |

### Field 中的关键方法

| 方法 | 说明 |
|------|------|
| `Type getGenericType()` | 获取字段类型（含泛型信息）；非泛型字段与 `getType()` 等价 |
| `Class<?> getType()` | 获取字段的原始 Class 类型 |
| `Class<?> getDeclaringClass()` | 获取字段所在的类 |

---

## 五、实战示例

### 5.1 获取类上声明的泛型变量

```java
interface I1 {}
interface I2 {}

/**
 * 演示：读取类级别声明的泛型变量 T1、T2、T3
 * T1 无上界（默认 Object），T2 上界为 Integer，T3 有两个上界
 */
public class Demo1<T1, T2 extends Integer, T3 extends I1 & I2> {

    public static void main(String[] args) {
        // getTypeParameters() 返回类上声明的所有泛型变量
        TypeVariable<Class<Demo1>>[] typeParameters = Demo1.class.getTypeParameters();

        for (TypeVariable<Class<Demo1>> tv : typeParameters) {
            System.out.println("变量名: " + tv.getName());
            System.out.println("声明位置: " + tv.getGenericDeclaration());
            Type[] bounds = tv.getBounds();
            System.out.println("上界数量: " + bounds.length);
            for (Type bound : bounds) {
                System.out.println("  上界: " + bound.getTypeName());
            }
            System.out.println("----");
        }
    }
}
```

**输出**：
```
变量名: T1
声明位置: class Demo1
上界数量: 1
  上界: java.lang.Object
----
变量名: T2
声明位置: class Demo1
上界数量: 1
  上界: java.lang.Integer
----
变量名: T3
声明位置: class Demo1
上界数量: 2
  上界: I1
  上界: I2
----
```

---

### 5.2 获取方法上声明的泛型变量及参数/返回值类型

```java
interface MI1 {}
interface MI2 {}

/**
 * 演示：读取方法参数、返回值、以及方法自身声明的泛型变量
 */
public class Demo2 {

    /**
     * 方法声明了 T1、T2、T3 三个泛型变量；
     * 前三个参数是泛型变量类型，最后一个是普通 String；
     * 返回值也是泛型变量 T3。
     */
    public <T1, T2 extends Integer, T3 extends MI1 & MI2> T3 m1(T1 t1, T2 t2, T3 t3, String s) {
        return t3;
    }

    public static void main(String[] args) throws NoSuchMethodException {
        Method m1 = Demo2.class.getDeclaredMethod("m1",
                Object.class, Integer.class, MI1.class, String.class);

        // ① 方法参数类型列表
        System.out.println("=== 参数类型 ===");
        for (Type paramType : m1.getGenericParameterTypes()) {
            if (paramType instanceof TypeVariable) {
                TypeVariable<?> tv = (TypeVariable<?>) paramType;
                System.out.printf("泛型变量 %s，上界: %s，声明于: %s%n",
                        tv.getName(),
                        Arrays.toString(tv.getBounds()),
                        tv.getGenericDeclaration());
            } else if (paramType instanceof Class) {
                System.out.println("普通类型: " + ((Class<?>) paramType).getName());
            }
        }

        // ② 返回值类型
        System.out.println("\n=== 返回值类型 ===");
        Type returnType = m1.getGenericReturnType();
        if (returnType instanceof TypeVariable) {
            TypeVariable<?> tv = (TypeVariable<?>) returnType;
            System.out.printf("泛型变量 %s，上界: %s%n",
                    tv.getName(), Arrays.toString(tv.getBounds()));
        }

        // ③ 方法自身声明的泛型变量列表
        System.out.println("\n=== 方法声明的泛型变量 ===");
        for (TypeVariable<Method> tv : m1.getTypeParameters()) {
            System.out.printf("变量 %s，上界: %s%n",
                    tv.getName(), Arrays.toString(tv.getBounds()));
        }
    }
}
```

**输出**（关键部分）：
```
=== 参数类型 ===
泛型变量 T1，上界: [class java.lang.Object]，声明于: public MI1 Demo2.m1(...)
泛型变量 T2，上界: [class java.lang.Integer]，声明于: public MI1 Demo2.m1(...)
泛型变量 T3，上界: [interface MI1, interface MI2]，声明于: public MI1 Demo2.m1(...)
普通类型: java.lang.String

=== 返回值类型 ===
泛型变量 T3，上界: [interface MI1, interface MI2]

=== 方法声明的泛型变量 ===
变量 T1，上界: [class java.lang.Object]
变量 T2，上界: [class java.lang.Integer]
变量 T3，上界: [interface MI1, interface MI2]
```

---

### 5.3 获取方法参数/返回值的参数化类型（ParameterizedType）

当方法参数或返回值是 `List<T>`、`Map<String, Integer>` 这类泛型类型时，用 `ParameterizedType` 来解析。

```java
/**
 * Demo4 是一个泛型类，内部类 C1 的方法参数和返回值都是 List<T>
 */
public class Demo4<T> {

    public class C1 {
        /**
         * 参数和返回值都是 List<T>，T 是 Demo4 类上定义的泛型变量
         */
        public List<T> m1(List<T> list) {
            return list;
        }
    }

    public static void main(String[] args) throws NoSuchMethodException {
        Method m1 = Demo4.C1.class.getMethod("m1", List.class);

        // 解析参数类型
        System.out.println("=== 参数类型 ===");
        Type arg1Type = m1.getGenericParameterTypes()[0];
        printParameterizedType((ParameterizedType) arg1Type);

        // 解析返回值类型
        System.out.println("\n=== 返回值类型 ===");
        printParameterizedType((ParameterizedType) m1.getGenericReturnType());
    }

    private static void printParameterizedType(ParameterizedType pt) {
        System.out.println("原始类型: " + pt.getRawType());
        System.out.println("所属类型: " + pt.getOwnerType()); // 顶层类返回 null
        for (Type arg : pt.getActualTypeArguments()) {
            if (arg instanceof TypeVariable) {
                TypeVariable<?> tv = (TypeVariable<?>) arg;
                System.out.printf("泛型参数是变量: %s，声明于: %s%n",
                        tv.getName(), tv.getGenericDeclaration());
            }
        }
    }
}
```

**输出**：
```
=== 参数类型 ===
原始类型: interface java.util.List
所属类型: null
泛型参数是变量: T，声明于: class Demo4

=== 返回值类型 ===
原始类型: interface java.util.List
所属类型: null
泛型参数是变量: T，声明于: class Demo4
```

---

### 5.4 通过 getGenericSuperclass() 获取父类的泛型参数

这是框架中最常用的技巧——**子类在继承时固定了父类的泛型参数**，`getGenericSuperclass()` 就能拿到具体类型。

```java
class BaseResult<T1, T2> {}

/**
 * Demo6 继承 BaseResult 时明确指定了 T1=String、T2=Integer
 * 通过 getGenericSuperclass() 可以在运行时获取这两个具体类型
 */
public class Demo6 extends BaseResult<String, Integer> {

    public static void main(String[] args) {
        // getGenericSuperclass() 返回父类的带泛型完整类型
        Type superType = Demo6.class.getGenericSuperclass();
        System.out.println("父类类型实现: " + superType.getClass().getSimpleName());
        // 输出：ParameterizedTypeImpl

        if (superType instanceof ParameterizedType) {
            ParameterizedType pt = (ParameterizedType) superType;
            System.out.println("父类原始类型: " + pt.getRawType());
            for (Type arg : pt.getActualTypeArguments()) {
                System.out.println("泛型参数: " + arg.getTypeName());
            }
        }
    }
}
```

**输出**：
```
父类类型实现: ParameterizedTypeImpl
父类原始类型: class BaseResult
泛型参数: java.lang.String
泛型参数: java.lang.Integer
```

**匿名内部类的妙用**：如果不想写子类，可以用匿名内部类"临时固定"泛型参数：

```java
public class Demo5<T1, T2> {

    public void printGenericInfo(Demo5<T1, T2> demo) {
        // 通过父类信息拿到 T1、T2 的具体类型
        Type superType = demo.getClass().getGenericSuperclass();
        if (superType instanceof ParameterizedType) {
            ParameterizedType pt = (ParameterizedType) superType;
            for (Type arg : pt.getActualTypeArguments()) {
                System.out.println("具体类型: " + arg.getTypeName());
            }
        }
    }

    public static void main(String[] args) {
        // 创建匿名子类，固定泛型为 String 和 Integer
        Demo5<String, Integer> demo = new Demo5<String, Integer>() {};
        demo.printGenericInfo(demo);
        // 输出：具体类型: java.lang.String
        //       具体类型: java.lang.Integer
    }
}
```

> **关键点**：`new Demo5<String, Integer>() {}` 创建的是 Demo5 的匿名子类，而不是 Demo5 本身的实例，因此 `getGenericSuperclass()` 返回的是 `Demo5<String, Integer>` 而非 `Object`。

---

### 5.5 解析通配符类型（WildcardType）

```java
public class Demo8 {
    public static class C1 {}
    public static class C2 extends C1 {}

    /**
     * 参数 Map<? super C2, ? extends C1>：
     *   - 键的通配符有下界 C2
     *   - 值的通配符有上界 C1
     * 返回值 List<?>：无界通配符
     */
    public static List<?> m1(Map<? super C2, ? extends C1> map) {
        return null;
    }

    public static void main(String[] args) throws NoSuchMethodException {
        Method m1 = Demo8.class.getMethod("m1", Map.class);

        System.out.println("=== 参数通配符信息 ===");
        ParameterizedType paramType = (ParameterizedType) m1.getGenericParameterTypes()[0];
        for (Type arg : paramType.getActualTypeArguments()) {
            if (arg instanceof WildcardType) {
                printWildcard((WildcardType) arg);
            }
        }

        System.out.println("\n=== 返回值通配符信息 ===");
        ParameterizedType returnType = (ParameterizedType) m1.getGenericReturnType();
        for (Type arg : returnType.getActualTypeArguments()) {
            if (arg instanceof WildcardType) {
                printWildcard((WildcardType) arg);
            }
        }
    }

    private static void printWildcard(WildcardType wt) {
        System.out.println("通配符: " + wt.getTypeName());
        for (Type upper : wt.getUpperBounds()) {
            System.out.println("  上界: " + upper.getTypeName());
        }
        for (Type lower : wt.getLowerBounds()) {
            System.out.println("  下界: " + lower.getTypeName());
        }
        System.out.println("---");
    }
}
```

**输出**：
```
=== 参数通配符信息 ===
通配符: ? super Demo8$C2
  上界: java.lang.Object
  下界: Demo8$C2
---
通配符: ? extends Demo8$C1
  上界: Demo8$C1
---

=== 返回值通配符信息 ===
通配符: ?
  上界: java.lang.Object
---
```

---

### 5.6 解析泛型数组（GenericArrayType）

```java
public class Demo9 {

    /** 泛型数组字段：数组元素类型是 List<String> */
    List<String>[] listArray;

    public static void main(String[] args) throws NoSuchFieldException {
        Field field = Demo9.class.getDeclaredField("listArray");
        Type genericType = field.getGenericType();

        System.out.println("字段类型实现: " + genericType.getClass().getSimpleName());
        // 输出：GenericArrayTypeImpl

        if (genericType instanceof GenericArrayType) {
            GenericArrayType arrayType = (GenericArrayType) genericType;
            // 获取数组元素类型，即 List<String>（ParameterizedType）
            Type componentType = arrayType.getGenericComponentType();

            System.out.println("元素类型实现: " + componentType.getClass().getSimpleName());
            // 输出：ParameterizedTypeImpl

            if (componentType instanceof ParameterizedType) {
                ParameterizedType pt = (ParameterizedType) componentType;
                System.out.println("原始类型: " + pt.getRawType());
                for (Type arg : pt.getActualTypeArguments()) {
                    System.out.println("泛型参数: " + arg.getTypeName());
                }
            }
        }
    }
}
```

**输出**：
```
字段类型实现: GenericArrayTypeImpl
元素类型实现: ParameterizedTypeImpl
原始类型: interface java.util.List
泛型参数: java.lang.String
```

---

### 5.7 综合案例：递归解析任意复杂泛型

对于 `Map<String, ? extends List<? extends Map<K, V>>>[][]` 这种多层嵌套类型，可以写一个通用的递归解析器：

```java
public class Demo10<K, V> {

    // 二维泛型数组，元素是嵌套了通配符和泛型变量的 Map 类型
    Map<String, ? extends List<? extends Map<K, V>>>[][] map;

    /**
     * 递归解析任意 Type，打印其完整的类型层次结构
     *
     * @param type  当前要解析的类型
     * @param level 当前递归深度（用于缩进）
     */
    public static void parseType(Type type, int level) {
        String indent = "  ".repeat(level);

        if (type instanceof GenericArrayType) {
            System.out.println(indent + "[泛型数组] " + type.getTypeName());
            parseType(((GenericArrayType) type).getGenericComponentType(), level + 1);

        } else if (type instanceof ParameterizedType) {
            ParameterizedType pt = (ParameterizedType) type;
            System.out.println(indent + "[参数化类型] 原始类型=" + pt.getRawType().getTypeName());
            for (Type arg : pt.getActualTypeArguments()) {
                parseType(arg, level + 1);
            }

        } else if (type instanceof WildcardType) {
            WildcardType wt = (WildcardType) type;
            System.out.println(indent + "[通配符] " + wt.getTypeName());
            for (Type upper : wt.getUpperBounds()) {
                System.out.println(indent + "  上界:");
                parseType(upper, level + 2);
            }
            for (Type lower : wt.getLowerBounds()) {
                System.out.println(indent + "  下界:");
                parseType(lower, level + 2);
            }

        } else if (type instanceof TypeVariable) {
            TypeVariable<?> tv = (TypeVariable<?>) type;
            System.out.println(indent + "[泛型变量] " + tv.getName()
                    + "，声明于: " + tv.getGenericDeclaration());

        } else if (type instanceof Class) {
            System.out.println(indent + "[普通类型] " + ((Class<?>) type).getName());
        }
    }

    public static void main(String[] args) throws NoSuchFieldException {
        Field field = Demo10.class.getDeclaredField("map");
        parseType(field.getGenericType(), 0);
    }
}
```

**输出**（结构清晰地展示了整个嵌套层次）：
```
[泛型数组] Map<String, ? extends List<? extends Map<K, V>>>[][]
  [泛型数组] Map<String, ? extends List<? extends Map<K, V>>>[]
    [参数化类型] 原始类型=java.util.Map
      [普通类型] java.lang.String
      [通配符] ? extends List<? extends Map<K, V>>
        上界:
          [参数化类型] 原始类型=java.util.List
            [通配符] ? extends Map<K, V>
              上界:
                [参数化类型] 原始类型=java.util.Map
                  [泛型变量] K，声明于: class Demo10
                  [泛型变量] V，声明于: class Demo10
```

这个递归解析器是通用的，可以处理任意深度的嵌套泛型。

---

## 六、框架中的真实应用

### 6.1 FastJSON 的 TypeReference

FastJSON 中，将 JSON 反序列化为泛型对象时，需要告诉它具体的类型：

```java
// ❌ 错误：T 被擦除，FastJSON 无法知道 data 字段的具体类型
Result<UserModel> result = JSON.parseObject(json, Result.class);

// ✅ 正确：通过匿名内部类固定泛型参数
Result<UserModel> result = JSON.parseObject(json, new TypeReference<Result<UserModel>>() {});
```

`TypeReference` 的核心实现正是利用了 `getGenericSuperclass()`：

```java
public abstract class TypeReference<T> {
    protected final Type type;

    protected TypeReference() {
        // getClass() 返回的是匿名子类的 Class，而非 TypeReference 本身
        // getGenericSuperclass() 因此能拿到 TypeReference<Result<UserModel>> 这个参数化类型
        Type superClass = getClass().getGenericSuperclass();
        // 取出 <> 中的第一个参数，即 Result<UserModel>
        this.type = ((ParameterizedType) superClass).getActualTypeArguments()[0];
    }
}
```

**关键理解**：`new TypeReference<Result<UserModel>>() {}` 创建了 `TypeReference` 的一个匿名子类，泛型参数固定为 `Result<UserModel>`。在匿名子类的构造器中调用 `getGenericSuperclass()`，父类就是 `TypeReference<Result<UserModel>>`，从而取出 `Result<UserModel>` 这个完整类型。

---

### 6.2 Spring 的 ResolvableType

Spring 提供了更高层的封装 `ResolvableType`，在框架内部大量用于解析泛型：

```java
// 解析 List<String> 的泛型参数
ResolvableType type = ResolvableType.forField(getClass().getDeclaredField("myList"));
// String
Class<?> generic = type.getGeneric(0).resolve();

// 解析父类的泛型参数（如 DAO 继承 BaseDAO<User>）
ResolvableType superType = ResolvableType.forClass(UserDAO.class).getSuperType();
// User
Class<?> entityClass = superType.getGeneric(0).resolve();
```

Spring 中的 `@Autowired` 注入 `List<UserService>` 时，也是通过 `ResolvableType` 来匹配具体的 Bean 类型的。

---

### 6.3 MyBatis 获取 Mapper 的泛型实体类型

MyBatis 中的 `BaseMapper<T>` 设计：

```java
// 框架层代码（简化版）
public class MapperRegistry {

    public <T> Class<?> getEntityClass(Class<T> mapperClass) {
        // 获取 Mapper 接口实现的 BaseMapper 接口的泛型参数
        for (Type iface : mapperClass.getGenericInterfaces()) {
            if (iface instanceof ParameterizedType) {
                ParameterizedType pt = (ParameterizedType) iface;
                if (pt.getRawType() == BaseMapper.class) {
                    // 取出 T 的具体类型
                    return (Class<?>) pt.getActualTypeArguments()[0];
                }
            }
        }
        throw new IllegalArgumentException("Not a BaseMapper implementation");
    }
}

// 用户代码
public interface UserMapper extends BaseMapper<User> {}
// mapperRegistry.getEntityClass(UserMapper.class) -> User.class
```

---

## 七、常见坑点与最佳实践

### 坑 1：对非子类直接调用 getGenericSuperclass() 得不到泛型信息

```java
// ❌ 直接实例化，T 被擦除，getGenericSuperclass() 只能得到 Object
Demo5<String, Integer> demo = new Demo5<>();
Type superType = demo.getClass().getGenericSuperclass(); // class java.lang.Object

// ✅ 必须通过匿名子类，让编译器将泛型参数写入字节码 Signature 属性
Demo5<String, Integer> demo = new Demo5<String, Integer>() {};
```

### 坑 2：getTypeParameters() 和 getActualTypeArguments() 混淆

```java
class Foo<T extends Number> {
    List<T> data;
}

// getTypeParameters() 返回声明的变量（T extends Number），不是具体类型
TypeVariable<?>[] vars = Foo.class.getTypeParameters();
// vars[0].getName() == "T"，vars[0].getBounds() == [Number]

// getActualTypeArguments() 是对 ParameterizedType 调用的，返回实际类型参数
// 例如对 Foo<Integer>（子类化）调用父类的 getGenericSuperclass()
```

### 坑 3：getGenericInterfaces() 与 getInterfaces() 的区别

```java
interface Repo<T> {}
class UserRepo implements Repo<User> {}

// getInterfaces() 返回原始类型，丢失泛型
Class<?>[] raw = UserRepo.class.getInterfaces(); // [Repo]

// getGenericInterfaces() 保留泛型参数
Type[] generic = UserRepo.class.getGenericInterfaces(); // [Repo<User>]
// 通过 ParameterizedType 可拿到 User
```

### 坑 4：多层嵌套泛型需要逐层解包

```java
// Map<String, List<User>>
// 不能直接拿到 User，必须先拿 List<User>，再拿 User
ParameterizedType mapType = ...; // Map<String, List<User>>
ParameterizedType listType = (ParameterizedType) mapType.getActualTypeArguments()[1]; // List<User>
Class<?> userClass = (Class<?>) listType.getActualTypeArguments()[0]; // User
```

### 最佳实践

| 场景 | 推荐做法 |
|------|---------|
| 框架中获取实体类型 | `getGenericSuperclass()` + `ParameterizedType` |
| 反序列化泛型对象 | 参考 FastJSON 的 `TypeReference` 匿名子类模式 |
| 通用泛型解析 | 优先用 Spring 的 `ResolvableType`（更健壮，处理了继承链） |
| 判断类型种类 | 先 `instanceof` 判断，再强转，处理所有 5 种情况 |
| 递归解析复杂嵌套类型 | 用 5.7 节的递归模式，覆盖全部 5 种接口 |

---

## 八、总结与延伸

**核心要点回顾**：

1. Java 泛型虽然运行时被擦除，但 `Signature` 属性保留了签名信息，反射 API 可以读取
2. `java.lang.reflect.Type` 体系包含 5 种类型：`Class`（普通）、`ParameterizedType`（参数化）、`TypeVariable`（变量）、`WildcardType`（通配符）、`GenericArrayType`（泛型数组）
3. 获取父类泛型参数的关键方法是 `getGenericSuperclass()`；匿名内部类技巧可以在不定义子类的情况下"固定"泛型参数
4. FastJSON 的 `TypeReference`、Spring 的 `ResolvableType`、MyBatis 的泛型实体解析，底层都依赖这套机制

**延伸阅读**：

- [Java 泛型擦除与类型推断那些坑](posts/2025-05-08-java-generics-erasure.md) — 本博客对类型擦除陷阱的专项分析
- Spring 源码中的 `ResolvableType`（`spring-core` 模块）—— 工业级泛型解析的最佳参考实现
- JSR 14（Java 泛型规范）及 Gilad Bracha 的《Generics in the Java Programming Language》— 泛型设计的一手文献
- Kotlin 的 `reified` 类型参数 — 对比了解 Kotlin 如何在语言层面解决类型擦除问题
