# MyBatis-Plus 多租户插件实现原理

<div class="post-meta">📅 2025-08-17 &nbsp;·&nbsp; 🏷️ <span class="tag">MyBatis-Plus</span></div>

多租户是 SaaS 系统的核心需求。MyBatis-Plus 的 `TenantLineInnerInterceptor` 通过 SQL 拦截，自动追加 `tenant_id` 条件，无需在每个 Mapper 中手动添加。

---

## 一、多租户核心流程

```
HTTP 请求（Header: X-Tenant-Id: tenant_001）
        │
        ▼
TenantContextHolder.set("tenant_001")  ← Filter 或 Interceptor 中设置
        │
        ▼
业务代码调用 Mapper
  userMapper.selectList(...)
        │
        ▼
MybatisPlusInterceptor
  └─ TenantLineInnerInterceptor
            │ 解析 SQL 语句（JSqlParser）
            │ 调用 TenantLineHandler.getTenantId()
            │ 自动追加 WHERE tenant_id = 'tenant_001'
            ▼
  最终 SQL: SELECT * FROM user WHERE ... AND tenant_id = 'tenant_001'
        │
        ▼
数据库执行
```

---

## 二、依赖与基础配置

```xml
<dependency>
    <groupId>com.baomidou</groupId>
    <artifactId>mybatis-plus-boot-starter</artifactId>
    <version>3.5.5</version>
</dependency>
<!-- SQL 解析依赖（自动传递，但版本需匹配）-->
<dependency>
    <groupId>com.github.jsqlparser</groupId>
    <artifactId>jsqlparser</artifactId>
    <version>4.6</version>
</dependency>
```

---

## 三、TenantContextHolder：线程安全存取租户 ID

```java
/**
 * 基于 ThreadLocal 的租户上下文，需在请求结束后清理防止内存泄漏
 */
public class TenantContextHolder {

    private static final ThreadLocal<String> TENANT_ID = new InheritableThreadLocal<>();

    public static void setTenantId(String tenantId) {
        TENANT_ID.set(tenantId);
    }

    public static String getTenantId() {
        return TENANT_ID.get();
    }

    public static void clear() {
        TENANT_ID.remove(); // 必须调用！防止线程池中的线程污染
    }
}
```

---

## 四、实现 TenantLineHandler

```java
@Component
public class MyTenantLineHandler implements TenantLineHandler {

    /**
     * 返回当前租户 ID（SQL 追加的值）
     * 框架会调用此方法获取 tenant_id 的值
     */
    @Override
    public Expression getTenantId() {
        String tenantId = TenantContextHolder.getTenantId();
        if (tenantId == null) {
            throw new RuntimeException("租户ID不能为空");
        }
        // 返回字符串类型的租户 ID
        return new StringValue(tenantId);
    }

    /**
     * 返回 tenant_id 字段名（表中的列名）
     */
    @Override
    public String getTenantIdColumn() {
        return "tenant_id";
    }

    /**
     * 是否忽略该表的多租户过滤
     * true = 忽略（不追加 tenant_id 条件）
     */
    @Override
    public boolean ignoreTable(String tableName) {
        // 公共表、字典表等不需要租户过滤
        return Arrays.asList(
            "sys_dict",
            "sys_config",
            "flyway_schema_history"
        ).contains(tableName.toLowerCase());
    }
}
```

---

## 五、注册拦截器（与分页插件共存）

```java
@Configuration
public class MybatisPlusConfig {

    @Autowired
    private MyTenantLineHandler tenantLineHandler;

    @Bean
    public MybatisPlusInterceptor mybatisPlusInterceptor() {
        MybatisPlusInterceptor interceptor = new MybatisPlusInterceptor();

        // 1. 先添加多租户拦截器（顺序很重要）
        interceptor.addInnerInterceptor(new TenantLineInnerInterceptor(tenantLineHandler));

        // 2. 再添加分页拦截器
        interceptor.addInnerInterceptor(new PaginationInnerInterceptor(DbType.MYSQL));

        // 3. 可选：乐观锁拦截器
        interceptor.addInnerInterceptor(new OptimisticLockerInnerInterceptor());

        return interceptor;
    }
}
```

> **顺序说明**：多租户拦截器应在分页拦截器之前，因为分页需要在已追加 tenant_id 条件的 SQL 基础上统计 count。

---

## 六、Web Filter 设置/清理租户上下文

```java
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class TenantFilter implements Filter {

    private static final String TENANT_HEADER = "X-Tenant-Id";

    @Override
    public void doFilter(ServletRequest req, ServletResponse resp, FilterChain chain)
            throws IOException, ServletException {
        HttpServletRequest request = (HttpServletRequest) req;
        String tenantId = request.getHeader(TENANT_HEADER);

        if (StringUtils.hasText(tenantId)) {
            TenantContextHolder.setTenantId(tenantId);
        }
        try {
            chain.doFilter(req, resp);
        } finally {
            TenantContextHolder.clear(); // 必须清理，防止线程复用时污染
        }
    }
}
```

---

## 七、SQL 自动改写效果

```java
// 原始代码
userMapper.selectList(
    new LambdaQueryWrapper<User>().eq(User::getStatus, 1)
);

// 实际执行的 SQL（自动追加 tenant_id）
// SELECT * FROM user WHERE status = 1 AND tenant_id = 'tenant_001'

// INSERT 也会自动追加
userMapper.insert(new User().setName("张三"));
// INSERT INTO user (name, tenant_id) VALUES ('张三', 'tenant_001')

// UPDATE
userMapper.update(user, wrapper);
// UPDATE user SET ... WHERE ... AND tenant_id = 'tenant_001'

// DELETE
userMapper.delete(wrapper);
// DELETE FROM user WHERE ... AND tenant_id = 'tenant_001'
```

---

## 八、忽略租户过滤的几种方式

### 方式1：ignoreTable 中配置特定表

```java
@Override
public boolean ignoreTable(String tableName) {
    return "sys_dict".equals(tableName);
}
```

### 方式2：@InterceptorIgnore 注解忽略某个 Mapper 方法

```java
public interface UserMapper extends BaseMapper<User> {

    // 全局统计（忽略租户过滤）
    @InterceptorIgnore(tenantLine = "true")
    @Select("SELECT COUNT(*) FROM user")
    Long countAll();

    // 超级管理员查所有租户数据
    @InterceptorIgnore(tenantLine = "true")
    List<User> selectAllTenants();
}
```

### 方式3：编程式忽略（适合动态场景）

```java
// 在某段代码中临时忽略租户
InterceptorIgnoreHelper.handle(IgnoreStrategy.builder().tenantLine(true).build());
try {
    // 此处执行的 SQL 不追加 tenant_id
    userMapper.selectList(null);
} finally {
    InterceptorIgnoreHelper.clearIgnoreStrategy();
}
```

---

## 九、多租户与分页插件共存验证

```java
@Test
void testTenantWithPage() {
    // 模拟租户请求
    TenantContextHolder.setTenantId("tenant_001");
    try {
        Page<User> page = new Page<>(1, 10);
        // 实际 SQL：
        // SELECT COUNT(*) FROM user WHERE status = 1 AND tenant_id = 'tenant_001'
        // SELECT * FROM user WHERE status = 1 AND tenant_id = 'tenant_001' LIMIT 0, 10
        IPage<User> result = userMapper.selectPage(page,
            new LambdaQueryWrapper<User>().eq(User::getStatus, 1));

        Assertions.assertNotNull(result);
    } finally {
        TenantContextHolder.clear();
    }
}
```

---

## 十、完整配置总览

```yaml
# application.yml
mybatis-plus:
  configuration:
    log-impl: org.apache.ibatis.logging.stdout.StdOutImpl  # 开发时打印 SQL
  global-config:
    db-config:
      logic-delete-field: deleted    # 逻辑删除字段
      logic-delete-value: 1
      logic-not-delete-value: 0
```

---

## 十一、常见问题与解决

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| tenant_id 为 null 报错 | ThreadLocal 未设置 | Filter 中设置，finally 清理 |
| 跨线程 tenant_id 丢失 | ThreadLocal 不跨线程 | 使用 `InheritableThreadLocal` 或手动传递 |
| 公共表数据被过滤 | 未配置 ignoreTable | 在 ignoreTable 中加入该表 |
| 分页 count 不准 | 拦截器顺序错误 | 多租户拦截器放在分页之前 |
| INSERT 未写入 tenant_id | 表没有 tenant_id 列 | 检查表结构，确保有该字段 |
| 子查询未追加 tenant_id | JSqlParser 版本问题 | 升级 jsqlparser 版本 |

---

## 十二、总结

- `TenantLineInnerInterceptor` 基于 JSqlParser 解析 SQL AST，自动在 WHERE 子句注入 `tenant_id = ?`
- `TenantLineHandler` 是唯一需要实现的接口，提供租户 ID 和忽略规则
- **ThreadLocal** 是传递租户上下文的标准方式，必须在 finally 中清理
- 多租户与分页插件共存时，多租户拦截器需排在前面
- `@InterceptorIgnore(tenantLine = "true")` 可对特定方法跳过租户过滤
