# MyBatis 二级缓存的坑与最佳实践

<div class="post-meta">📅 2025-05-20 &nbsp;·&nbsp; 🏷️ <span class="tag">MyBatis</span></div>

MyBatis 二级缓存是开箱即用但暗藏陷阱的特性，不当使用会导致脏数据。本文系统梳理一/二级缓存机制、常见坑点与正确使用姿势。

---

## 一、一级缓存 vs 二级缓存

```
┌──────────────────────────────────────────────────────────────┐
│                      MyBatis 缓存架构                         │
│                                                              │
│  二级缓存（Mapper/Namespace 级别）                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  UserMapper 缓存空间    OrderMapper 缓存空间           │   │
│  │  key: namespace+sql+params → value: 查询结果          │   │
│  └──────────────────────────────────────────────────────┘   │
│           ↑ commit 后数据进入二级缓存                          │
│                                                              │
│  一级缓存（SqlSession 级别）                                   │
│  ┌─────────────────┐   ┌─────────────────┐                 │
│  │  SqlSession A   │   │  SqlSession B   │                 │
│  │  本地缓存 Map    │   │  本地缓存 Map    │                 │
│  └─────────────────┘   └─────────────────┘                 │
│           ↑ 同一 SqlSession 内有效，close 后清除               │
└──────────────────────────────────────────────────────────────┘
```

---

## 二、一级缓存详解

### 工作机制

一级缓存默认开启，**无需配置**，作用域是同一个 `SqlSession`。

```java
// 同一 SqlSession 两次相同查询，第二次走缓存
try (SqlSession session = sqlSessionFactory.openSession()) {
    User user1 = session.selectOne("findById", 1L); // 查数据库
    User user2 = session.selectOne("findById", 1L); // 走一级缓存
    System.out.println(user1 == user2); // true，同一对象！
}
```

### 一级缓存失效场景

```java
// 场景1：执行了 DML 操作（insert/update/delete）
session.selectOne("findById", 1L);
session.update("updateUser", user); // 清空当前 namespace 缓存
session.selectOne("findById", 1L); // 重新查数据库

// 场景2：手动清空
session.clearCache();

// 场景3：不同 SqlSession（Spring 中每次请求都是新的 SqlSession）
```

### 与 Spring 集成时的一级缓存

```
Spring 事务中：同一事务 = 同一 SqlSession → 一级缓存有效
非事务方法：每次调用 Mapper = 新 SqlSession → 一级缓存无效（用完即关）
```

```java
// ✅ 事务中一级缓存生效
@Transactional
public void example() {
    User u1 = userMapper.findById(1L); // 查 DB
    User u2 = userMapper.findById(1L); // 走一级缓存（同一 SqlSession）
}

// ❌ 非事务，一级缓存不生效
public void example() {
    User u1 = userMapper.findById(1L); // 查 DB（SqlSession1，用完关闭）
    User u2 = userMapper.findById(1L); // 再查 DB（SqlSession2）
}
```

---

## 三、二级缓存详解

### 开启方式

```xml
<!-- mybatis-config.xml 全局开启（默认 true）-->
<settings>
    <setting name="cacheEnabled" value="true"/>
</settings>
```

```xml
<!-- UserMapper.xml：在 Mapper 中声明使用缓存 -->
<mapper namespace="com.example.mapper.UserMapper">
    <cache
        eviction="LRU"
        flushInterval="60000"
        size="512"
        readOnly="true"/>
    <!-- ... -->
</mapper>
```

或注解方式：

```java
@CacheNamespace(
    eviction = LruCache.class,
    flushInterval = 60000,
    size = 512,
    readWrite = false
)
public interface UserMapper {
    // ...
}
```

### 二级缓存参数说明

| 参数 | 默认值 | 说明 |
|------|-------|------|
| `eviction` | LRU | 缓存淘汰策略：LRU/FIFO/SOFT/WEAK |
| `flushInterval` | 不刷新 | 自动刷新间隔（毫秒） |
| `size` | 1024 | 最多缓存多少个结果 |
| `readOnly` | false | true 返回缓存对象引用（快），false 返回深拷贝（安全） |

---

## 四、二级缓存的致命坑：脏数据

### 坑1：多表关联查询

这是二级缓存**最大的坑**。

```xml
<!-- OrderMapper.xml 中的联表查询 -->
<select id="findWithUser" resultType="OrderVO">
    SELECT o.*, u.username
    FROM orders o
    JOIN users u ON o.user_id = u.id
    WHERE o.id = #{id}
</select>
```

```
问题：
1. 查询 order(id=1) → 结果缓存在 OrderMapper 的缓存空间
2. 更新 users 表（通过 UserMapper.update）→ 清空 UserMapper 缓存
3. 再查 order(id=1) → 从 OrderMapper 缓存返回旧数据！
   此时 username 已经过时，产生脏数据！
```

**解决方案**：关联查询不使用二级缓存，或使用 `@CacheNamespaceRef`

```java
// OrderMapper 引用 UserMapper 的缓存空间
// 这样 UserMapper 的写操作也会刷新 OrderMapper 的缓存
// 但这种做法耦合严重，不推荐
@CacheNamespaceRef(UserMapper.class)
public interface OrderMapper { }
```

### 坑2：readOnly=false 时 POJO 必须实现 Serializable

```java
// ❌ 未实现 Serializable，二级缓存序列化失败
public class User {
    private Long id;
    private String username;
}

// ✅ 实现 Serializable
public class User implements Serializable {
    private static final long serialVersionUID = 1L;
    private Long id;
    private String username;
}
```

### 坑3：事务未提交时二级缓存不可见

```
二级缓存数据在 SqlSession commit 后才写入
SqlSession 期间的查询结果存放在 TransactionalCacheManager 的暂存区
如果事务回滚，这部分数据直接丢弃，不写入二级缓存
```

---

## 五、什么时候该用/不该用

### 适合使用二级缓存

```
✅ 单表查询，写操作少（如字典表、配置表）
✅ 数据允许短暂不一致（日志统计、报表）
✅ 与 Redis 整合作为分布式二级缓存
```

### 不适合使用二级缓存

```
❌ 多表关联查询（脏数据风险高）
❌ 写多读少的表
❌ 对数据一致性要求高的业务（订单、金额）
❌ 集群部署（各节点缓存不同步，需集成分布式缓存）
```

---

## 六、与 Redis 集成的正确方案

使用 MyBatis-Redis 或 `mybatis-ehcache` 将二级缓存存到 Redis，解决集群节点缓存不一致问题。

```xml
<dependency>
    <groupId>org.mybatis.caches</groupId>
    <artifactId>mybatis-redis</artifactId>
    <version>1.0.0-beta2</version>
</dependency>
```

```xml
<!-- UserMapper.xml -->
<cache type="org.mybatis.caches.redis.RedisCache"/>
```

```properties
# redis.properties（mybatis-redis 配置）
redis.host=localhost
redis.port=6379
redis.connectionTimeout=5000
redis.password=
redis.database=0
```

但实际上，**生产中推荐直接用 Spring Cache + Redis**，绕开 MyBatis 二级缓存：

```java
@Service
public class UserService {

    @Autowired
    private UserMapper userMapper;

    // 用 Spring Cache 代替 MyBatis 二级缓存，粒度更细，控制更精确
    @Cacheable(cacheNames = "users", key = "#id", unless = "#result == null")
    public User findById(Long id) {
        return userMapper.selectById(id);
    }

    @CacheEvict(cacheNames = "users", key = "#user.id")
    public void update(User user) {
        userMapper.updateById(user);
    }
}
```

---

## 七、最佳实践总结

```
1. 一级缓存（默认开启，不需要管）
   ├─ Spring 事务内：有效，减少 DB 查询
   └─ 非事务方法：无效，每次新 SqlSession

2. 二级缓存
   ├─ 非联表查询的简单字典/配置数据：可以开
   ├─ 联表查询：强烈不建议开
   └─ 集群部署：必须配合 Redis 或直接用 Spring Cache

3. 推荐替代方案
   └─ Spring Cache + Redis：比 MyBatis 二级缓存更灵活、可控、易维护
```

| 场景 | 推荐方案 |
|------|---------|
| 单机、字典表 | MyBatis 二级缓存（简单） |
| 集群、业务缓存 | Spring Cache + Redis |
| 高一致性要求 | 不缓存，或先删缓存再查 |
| 多表联查 | 禁用二级缓存，用 Spring Cache 手动管理 |
