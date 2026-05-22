# MyBatis 缓存机制：一级缓存、二级缓存与坑

<div class="post-meta">📅 2025-05-20 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

同一个查询执行了两次，第二次没有打出 SQL 日志——是 MyBatis 一级缓存在工作。但数据明明改了，查出来却是旧数据——这也是 MyBatis 缓存的坑。理解 MyBatis 两级缓存的边界，才能在合适的场景开启，在危险的场景关闭。

---

## 一、背景：MyBatis 缓存的设计目标

MyBatis 缓存分两级：
- **一级缓存（本地缓存）**：SqlSession 级别，**默认开启且无法关闭**（只能降级为 STATEMENT 级别）
- **二级缓存（全局缓存）**：Mapper/namespace 级别，**默认关闭**，需显式开启

```
一级缓存（SqlSession 级）：
同一个 SqlSession → 同一条 SQL + 参数 → 命中缓存，不查 DB

二级缓存（Namespace 级）：
不同 SqlSession → 同一 Mapper → 命中跨 Session 的全局缓存
```
---

## 二、一级缓存：默认开启，同 Session 内生效

### 2.1 工作机制

```
SqlSession.selectOne("getById", 1L)
    → 生成 CacheKey（statementId + offset + limit + sql + params + env）
    → 查 PerpetualCache（HashMap）
    → 命中：直接返回
    → 未命中：查 DB → 写入缓存 → 返回

缓存失效时机：
- 执行了 INSERT/UPDATE/DELETE（同 Session 内）
- 调用了 SqlSession.clearCache()
- SqlSession 关闭
- 配置了 flushCache=true 的查询
```
### 2.2 Spring 集成后一级缓存的实际效果

```java
// 在 Spring 中，每次 @Autowired Mapper 调用，背后都是新的 SqlSession
// 因此一级缓存的作用范围很小，通常只在同一个事务内有效

@Service
public class UserService {
    @Autowired
    private UserMapper userMapper;

    @Transactional
    public void process(Long userId) {
        User u1 = userMapper.findById(userId);  // 查 DB，结果放入一级缓存
        User u2 = userMapper.findById(userId);  // 命中一级缓存，不查 DB
        // u1 == u2（同一个对象引用！）← 危险：修改 u1 会影响 u2
    }
}
```
**一级缓存的坑**：返回的是缓存中的**同一个对象引用**，修改会影响缓存数据。

---

## 三、二级缓存：显式开启，跨 Session 生效

### 3.1 开启方式

```xml
<!-- mybatis-config.xml 全局开关 -->
<settings>
    <setting name="cacheEnabled" value="true"/>  <!-- 默认已是 true -->
</settings>
```
```xml
<!-- UserMapper.xml：在需要缓存的 Mapper 中声明 -->
<cache
    eviction="LRU"           <!-- 淘汰策略：LRU/FIFO/SOFT/WEAK -->
    flushInterval="60000"   <!-- 刷新间隔（毫秒），不设置则不自动刷新 -->
    size="512"              <!-- 最多缓存 512 个引用 -->
    readOnly="true"/>       <!-- true=返回缓存对象本身（性能高），false=返回深拷贝（安全）-->
```
或使用注解：

```java
@CacheNamespace(eviction = LruCache.class, flushInterval = 60000, size = 512, readWrite = false)
public interface UserMapper { }
```
### 3.2 使用要求

二级缓存要求**实体类实现 Serializable**（缓存到磁盘或序列化时需要）：

```java
public class User implements Serializable {
    private static final long serialVersionUID = 1L;
    // ...
}
```
### 3.3 二级缓存的失效

```xml
<!-- 默认：所有查询语句都使用缓存，所有写操作都刷新缓存 -->
<select id="findById" resultType="User">
    SELECT * FROM user WHERE id = #{id}
</select>

<!-- flushCache=true：该语句执行后强制刷新缓存 -->
<select id="findSpecial" flushCache="true" resultType="User">
    SELECT * FROM user WHERE status = 'active'
</select>

<!-- useCache=false：该语句不使用二级缓存 -->
<select id="findRealtime" useCache="false" resultType="User">
    SELECT balance FROM account WHERE id = #{id}
</select>
```
---

## 四、自定义二级缓存：集成 Redis

MyBatis 二级缓存是进程内缓存，不适合分布式系统。可以实现 Cache 接口集成 Redis：

```java
public class RedisMybatisCache implements Cache {
    private final String id;  // namespace id
    private static RedisTemplate<Object, Object> redisTemplate;
    private static final long TTL_SECONDS = 3600;

    public RedisMybatisCache(String id) {
        this.id = id;
    }

    @Override
    public String getId() { return id; }

    @Override
    public void putObject(Object key, Object value) {
        redisTemplate.opsForHash().put(id, key.toString(), value);
        redisTemplate.expire(id, TTL_SECONDS, TimeUnit.SECONDS);
    }

    @Override
    public Object getObject(Object key) {
        return redisTemplate.opsForHash().get(id, key.toString());
    }

    @Override
    public Object removeObject(Object key) {
        return redisTemplate.opsForHash().delete(id, key.toString());
    }

    @Override
    public void clear() {
        redisTemplate.delete(id);
    }

    @Override
    public int getSize() {
        return redisTemplate.opsForHash().size(id).intValue();
    }

    // Spring 注入 RedisTemplate（需要静态注入）
    public static void setRedisTemplate(RedisTemplate<Object, Object> template) {
        RedisMybatisCache.redisTemplate = template;
    }
}
```
```xml
<!-- 使用自定义 Redis 缓存 -->
<cache type="com.example.cache.RedisMybatisCache"/>
```
---

## 五、对比：一级缓存 vs 二级缓存

| 特性 | 一级缓存 | 二级缓存 |
|------|---------|---------|
| 作用范围 | SqlSession 内 | Mapper namespace 内（跨 Session）|
| 默认状态 | 开启（不可关闭）| 关闭 |
| 分布式支持 | ❌ | ❌（默认）/ ✅（自定义 Redis Cache）|
| 缓存粒度 | SQL + 参数 + 环境 | SQL + 参数 |
| 失效触发 | 同 Session 的 DML，Session 关闭 | 任意 Session 的 DML（Namespace 内）|
| 适用场景 | 同事务内重复查询 | 读多写少的静态数据 |

---

## 六、常见坑点与最佳实践

### 坑 1：一级缓存在脏读场景

```java
// 线程 A 读取 user，缓存在一级缓存
User u = mapper.findById(1L);  // 一级缓存：{id:1, name:"Alice"}

// 线程 B（另一个 SqlSession）更新了数据库
// UPDATE user SET name='Bob' WHERE id=1

// 线程 A 再次读取，命中一级缓存，得到旧数据
User u2 = mapper.findById(1L);  // ← 得到 "Alice"，但 DB 已是 "Bob"
```
### 坑 2：二级缓存跨 namespace 的脏读

```xml
<!-- ❌ OrderMapper 和 UserMapper 都能查 user 表，但缓存不互通 -->
<!-- UserMapper 缓存了 user，OrderMapper 更新了 user，UserMapper 缓存变脏 -->
```
**建议**：涉及多表关联查询的 Mapper 不要开启二级缓存。

### 坑 3：实体类不实现 Serializable 导致异常

**最佳实践**：写多读少的 OLTP 业务，不要开启 MyBatis 二级缓存；读多写少的字典/配置数据，可以开启配合 Redis。

---

## 七、总结与延伸

**核心要点**：
- 一级缓存：SqlSession 级别，Spring 集成后作用范围 = 一个事务；返回同一对象引用
- 二级缓存：Namespace 级别，默认关闭，适合读多写少场景；实体类需要 Serializable
- 生产环境分布式系统中，MyBatis 原生缓存不够用，结合 Spring Cache + Redis 更可控

**延伸阅读方向**：
- MyBatis Plus 扩展：@TableLogic 逻辑删除、@Version 乐观锁的缓存失效影响
- L2 Cache 与分布式一致性：使用 Canal 监听 binlog 主动淘汰缓存
- MyBatis 插件机制：Interceptor 实现数据权限、SQL 审计、分页等功能
- MyBatis 与 Spring 事务整合：SqlSessionTemplate 如何保证事务边界内的 Session 一致性
