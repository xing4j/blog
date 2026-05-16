# 深拷贝与浅拷贝的 N 种实现方式对比

<div class="post-meta">📅 2025-03-22 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span></div>

对象拷贝是日常开发中的高频操作，选错方式轻则数据污染，重则引发难以排查的 Bug。本文梳理各种拷贝实现方式的原理与适用场景。

---

## 一、浅拷贝 vs 深拷贝

```
原对象                    浅拷贝结果              深拷贝结果
┌──────────┐             ┌──────────┐           ┌──────────┐
│ name="A" │             │ name="A" │           │ name="A" │
│ address──┼──┐          │ address──┼──┐        │ address──┼──→ 新对象
└──────────┘  │          └──────────┘  │        └──────────┘
              ↓                        ↓（同一引用！）
          ┌──────────┐             ┌──────────┐
          │ city="北京"│             │ city="北京"│
          └──────────┘             └──────────┘
```

- **浅拷贝**：复制基本类型字段值，引用类型只复制引用地址（两个对象共享同一引用对象）
- **深拷贝**：递归复制所有引用对象，两个对象完全独立

---

## 二、各种实现方式

### 方式一：Object.clone()（浅拷贝）

```java
public class User implements Cloneable {
    private String name;
    private Address address; // 引用类型

    @Override
    public User clone() {
        try {
            return (User) super.clone(); // 浅拷贝！address 仍是同一引用
        } catch (CloneNotSupportedException e) {
            throw new RuntimeException(e);
        }
    }
}

User original = new User("Alice", new Address("北京"));
User copy = original.clone();
copy.getAddress().setCity("上海");
// original.getAddress().getCity() == "上海"  ← 被修改了！
```

### 方式二：clone() 实现深拷贝（手动递归）

```java
@Override
public User clone() {
    try {
        User copy = (User) super.clone();
        copy.address = this.address.clone(); // 手动深拷贝引用字段
        return copy;
    } catch (CloneNotSupportedException e) {
        throw new RuntimeException(e);
    }
}
```

**缺点**：嵌套层次深时代码繁琐，新增字段需同步修改 clone 方法。

### 方式三：构造器拷贝

```java
public class User {
    public User(User other) {
        this.name = other.name;
        this.address = new Address(other.address); // 手动深拷贝
    }
}
```

清晰明确，适合字段较少且层次简单的类。

### 方式四：序列化深拷贝

```java
// 方式 4a：Java 原生序列化（需实现 Serializable）
public static <T extends Serializable> T deepCopy(T obj) {
    try {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        new ObjectOutputStream(bos).writeObject(obj);
        ByteArrayInputStream bis = new ByteArrayInputStream(bos.toByteArray());
        return (T) new ObjectInputStream(bis).readObject();
    } catch (Exception e) {
        throw new RuntimeException("深拷贝失败", e);
    }
}

// 方式 4b：JSON 序列化（Jackson）—— 最常用
public static <T> T deepCopy(T obj, Class<T> clazz) {
    ObjectMapper mapper = new ObjectMapper();
    try {
        return mapper.readValue(mapper.writeValueAsString(obj), clazz);
    } catch (Exception e) {
        throw new RuntimeException(e);
    }
}
```

### 方式五：Apache Commons / Spring BeanUtils（浅拷贝）

```java
// Apache BeanUtils（浅拷贝，有类型转换，较慢）
BeanUtils.copyProperties(source, target);

// Spring BeanUtils（浅拷贝，性能较好）
org.springframework.beans.BeanUtils.copyProperties(source, target);

// MapStruct（编译期生成，性能最佳，推荐）
@Mapper
public interface UserMapper {
    UserMapper INSTANCE = Mappers.getMapper(UserMapper.class);
    UserDTO toDTO(User user);
}
```

### 方式六：Kryo 序列化深拷贝（高性能）

```java
// Kryo 比 Java 原生序列化快 10x，比 JSON 快 3-5x
Kryo kryo = new Kryo();
kryo.setRegistrationRequired(false);
Output output = new Output(new ByteArrayOutputStream());
kryo.writeObject(output, original);
Input input = new Input(output.toBytes());
User copy = kryo.readObject(input, User.class);
```

---

## 三、各方式性能与适用场景对比

| 方式 | 拷贝深度 | 性能 | 需要实现接口/注解 | 适用场景 |
|------|---------|------|-----------------|---------|
| `Object.clone()` | 浅 | ⭐⭐⭐⭐⭐ | `Cloneable` | 性能极敏感的浅拷贝 |
| 手动 clone 深拷贝 | 深 | ⭐⭐⭐⭐ | `Cloneable` | 层次简单的深拷贝 |
| 构造器拷贝 | 深 | ⭐⭐⭐⭐⭐ | 无 | 字段少、层次浅 |
| Java 序列化 | 深 | ⭐⭐ | `Serializable` | 通用但性能差 |
| JSON 序列化 | 深 | ⭐⭐⭐ | 无（推荐 Jackson）| 业务层深拷贝首选 |
| Kryo 序列化 | 深 | ⭐⭐⭐⭐ | 无 | 高性能深拷贝 |
| Spring BeanUtils | 浅 | ⭐⭐⭐⭐ | 无 | DTO 属性复制 |
| MapStruct | 浅/深可配 | ⭐⭐⭐⭐⭐ | `@Mapper` | 编译期生成，生产推荐 |

---

## 四、生产建议

```java
// 1. 简单 VO/DTO 转换 → MapStruct（性能最佳，类型安全）
UserDTO dto = UserMapper.INSTANCE.toDTO(user);

// 2. 业务层需要深拷贝对象 → JSON 序列化（简单够用）
User copy = JsonUtils.deepCopy(user, User.class);

// 3. 高性能场景 → Kryo
// 4. 避免用 Apache BeanUtils，性能差且有类型转换风险
```

---

## 总结

- 浅拷贝：引用对象共享，修改会互相影响，适合不可变对象或只读场景
- 深拷贝：完全独立，推荐 JSON 序列化（简单）或 MapStruct（性能）
- **生产首选 MapStruct**，编译期生成代码，无反射，性能最优
