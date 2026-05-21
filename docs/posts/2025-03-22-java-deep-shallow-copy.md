# Java 对象拷贝全解：浅拷贝、深拷贝与生产选型

<div class="post-meta">📅 2025-03-22 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span></div>

BeanUtils 拷贝完对象，修改了"副本"里的 List，原对象的 List 也跟着变了——这是浅拷贝的经典坑。理解拷贝的本质，选对拷贝方式，是写出健壮业务代码的基础。

---

## 一、背景：为什么要区分浅拷贝和深拷贝

Java 中所有对象赋值默认是**引用传递**：User b = a 只是让 b 指向同一个对象，并没有创建新对象。当我们需要一份独立的"副本"时，就需要显式拷贝。

拷贝的核心问题在于**引用类型字段**：

`
原对象 original                     浅拷贝 copy
┌────────────┐                    ┌────────────┐
│ name="Alice"│                   │ name="Alice"│
│ address ─────────────────────────→ address   │
└────────────┘         ↓          └────────────┘
                 ┌──────────┐
                 │ city="北京"│  ← 两个对象共享同一个 Address 实例
                 └──────────┘
                                      ↓ 深拷贝 deepCopy
                 ┌──────────┐    ┌────────────┐
                 │ city="北京"│   │ name="Alice"│
                 └──────────┘   │ address ──→ 新 Address 实例
                                └────────────┘
`

- **浅拷贝**：复制基本类型字段，引用类型字段只复制引用指针（共享底层对象）
- **深拷贝**：递归复制所有引用类型对象，两个对象完全独立

---

## 二、各种拷贝方式详解

### 2.1 Object.clone()（浅拷贝）

`java
public class User implements Cloneable {
    private String name;
    private Address address;  // 引用类型

    @Override
    public User clone() {
        try {
            return (User) super.clone();  // 浅拷贝：address 仍指向同一对象
        } catch (CloneNotSupportedException e) {
            throw new AssertionError();
        }
    }
}

User original = new User("Alice", new Address("北京"));
User copy = original.clone();
copy.getAddress().setCity("上海");
System.out.println(original.getAddress().getCity()); // 输出：上海 ← 原对象被污染！
`

### 2.2 手动深拷贝（覆写 clone）

`java
@Override
public User clone() {
    try {
        User copy = (User) super.clone();
        copy.address = this.address.clone();  // 手动深拷贝引用字段
        copy.tags = new ArrayList<>(this.tags); // List 也要新建
        return copy;
    } catch (CloneNotSupportedException e) {
        throw new AssertionError();
    }
}
`

**缺点**：嵌套层次深时极易遗漏，新增字段必须同步修改 clone 方法，维护成本高。

### 2.3 拷贝构造函数（推荐简单对象）

`java
public class User {
    public User(User other) {
        this.name = other.name;               // String 不可变，引用可以复用
        this.age = other.age;                 // 基本类型，直接复制值
        this.address = new Address(other.address);  // 引用类型，递归拷贝
        this.tags = new ArrayList<>(other.tags);    // List 新建
    }
}

User copy = new User(original);
`

**优点**：明确可读，不依赖接口；**缺点**：每个类都要写，字段多时冗长。

### 2.4 序列化深拷贝（通用方案）

`java
// 方式 A：Jackson JSON 序列化（最常用，无需实现 Serializable）
public static <T> T deepCopy(T obj, Class<T> clazz) {
    try {
        ObjectMapper mapper = new ObjectMapper();
        return mapper.readValue(mapper.writeValueAsBytes(obj), clazz);
    } catch (Exception e) {
        throw new RuntimeException("Deep copy failed", e);
    }
}

User copy = deepCopy(original, User.class);

// 方式 B：Java 原生序列化（需实现 Serializable，性能较差）
@SuppressWarnings("unchecked")
public static <T extends Serializable> T deepCopy(T obj) {
    try (ByteArrayOutputStream bos = new ByteArrayOutputStream();
         ObjectOutputStream oos = new ObjectOutputStream(bos)) {
        oos.writeObject(obj);
        try (ObjectInputStream ois = new ObjectInputStream(
                new ByteArrayInputStream(bos.toByteArray()))) {
            return (T) ois.readObject();
        }
    } catch (Exception e) {
        throw new RuntimeException("Deep copy failed", e);
    }
}
`

### 2.5 各工具类的浅拷贝

`java
// Spring BeanUtils（浅拷贝，字段名相同即复制）
org.springframework.beans.BeanUtils.copyProperties(source, target);

// Apache Commons BeanUtils（浅拷贝，有类型转换，性能较差）
org.apache.commons.beanutils.BeanUtils.copyProperties(target, source);  // 注意参数顺序反了！

// MapStruct（编译期生成代码，可配置深浅，性能最佳）
@Mapper
public interface UserMapper {
    @Mapping(target = "address", expression = "java(new Address(user.getAddress()))")
    UserDTO toDTO(User user);
}
`

---

## 三、各方式性能与适用场景对比

| 方式 | 拷贝深度 | 性能 | 适用场景 | 注意事项 |
|------|---------|------|---------|---------|
| Object.clone() | 浅 | ⭐⭐⭐⭐⭐ | 性能极敏感的浅拷贝 | 需实现 Cloneable |
| 手动覆写 clone | 深 | ⭐⭐⭐⭐ | 简单类的深拷贝 | 新增字段要同步修改 |
| 拷贝构造函数 | 深 | ⭐⭐⭐⭐⭐ | 字段少、层次浅 | 每个类都要写 |
| Jackson 序列化 | 深 | ⭐⭐⭐ | 通用业务层深拷贝 | 有 getter/setter 要求 |
| Java 序列化 | 深 | ⭐⭐ | 遗留代码兼容 | 需实现 Serializable，性能差 |
| Kryo 序列化 | 深 | ⭐⭐⭐⭐ | 高性能深拷贝 | 线程不安全，需池化 |
| Spring BeanUtils | 浅 | ⭐⭐⭐⭐ | DTO 属性复制 | **注意是浅拷贝！** |
| **MapStruct** | 可配置 | ⭐⭐⭐⭐⭐ | **生产首选** | 需编译期配置 |

---

## 四、常见坑点与最佳实践

### 坑 1：Spring BeanUtils 是浅拷贝，List 字段共享

`java
User original = new User();
original.setTags(new ArrayList<>(Arrays.asList("tag1", "tag2")));

User copy = new User();
BeanUtils.copyProperties(original, copy);

copy.getTags().add("tag3");
// original.getTags() == ["tag1", "tag2", "tag3"] ← 原对象被污染！
`

### 坑 2：Apache BeanUtils 参数顺序与 Spring 相反

`java
// Spring：copyProperties(source, target)
org.springframework.beans.BeanUtils.copyProperties(source, target);

// Apache：copyProperties(target, source) ← 顺序相反！
org.apache.commons.beanutils.BeanUtils.copyProperties(target, source);
`

### 坑 3：Jackson 深拷贝对 LocalDate 等类型需要配置

`java
ObjectMapper mapper = new ObjectMapper()
    .registerModule(new JavaTimeModule())     // 支持 Java 8 时间类型
    .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);

User copy = mapper.readValue(mapper.writeValueAsBytes(original), User.class);
`

---

## 五、生产选型建议

`
DTO/VO 属性复制（字段映射）      → MapStruct（编译期生成，类型安全，性能最佳）
业务对象深拷贝（简单场景）        → Jackson deepCopy
业务对象深拷贝（高性能场景）      → Kryo（注意线程安全，使用池化）
字段少的简单对象                 → 拷贝构造函数（最直观）
避免使用                        → Apache BeanUtils（性能差且参数顺序容易混淆）
`

---

## 六、总结与延伸

**核心要点**：
- 浅拷贝复制引用，修改副本会影响原对象；深拷贝创建独立副本
- BeanUtils.copyProperties 是浅拷贝，含引用类型字段时必须注意
- 生产首选 **MapStruct**（DTO 转换）或 **Jackson**（通用深拷贝）
- 避免手动维护 clone 方法，新增字段遗漏是常见 Bug 来源

**延伸阅读方向**：
- Kryo 序列化：高性能序列化库，支持深拷贝，常用于分布式缓存
- MapStruct 高级用法：多源映射、自定义转换、继承映射
- Protobuf / FlatBuffers：零拷贝序列化，高性能 RPC 传输
- Java 14+ Records：不可变数据对象，天然线程安全，无需考虑深浅拷贝
