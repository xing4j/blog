# MyBatis Plus 多租户：一个注解实现数据隔离

<div class="post-meta">📅 2025-08-17 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

SaaS 系统要求每个租户只能访问自己的数据，最直接的做法是每条 SQL 手动加 WHERE tenant_id = ?——这既容易遗漏，又让代码充满噪音。MyBatis Plus 的多租户插件通过拦截器自动注入租户条件，让数据隔离变成"零侵入"的事。

---

## 一、背景：多租户的三种数据隔离方案

| 方案 | 实现 | 隔离强度 | 成本 |
|------|------|---------|------|
| 独立数据库 | 每租户独立 DB | ⭐⭐⭐⭐⭐ | 运维成本极高 |
| 独立 Schema | 同一 DB，不同 Schema | ⭐⭐⭐⭐ | 表结构变更麻烦 |
| 共享表（行隔离）| 同一张表，tenant_id 列区分 | ⭐⭐⭐ | 开发最简单 |

**行隔离方案**是中小型 SaaS 的常见选择，MyBatis Plus 的多租户插件正是针对这种方案设计。

---

## 二、MyBatis Plus 多租户插件原理

```
SQL 执行流程：
Mapper.selectList()
    ↓
MybatisPlusInterceptor（拦截器链）
    ↓
TenantLineInnerInterceptor（多租户内部拦截器）
    ↓
JSQLParser 解析 SQL → 注入 WHERE tenant_id = #{currentTenantId}
    ↓
执行最终 SQL
```
MyBatis Plus 使用 **JSQLParser** 解析 SQL 语法树，将租户条件注入到 WHERE、JOIN ON、INSERT 等子句中，无需修改任何业务代码。

---

## 三、完整集成步骤

### 3.1 添加依赖

```xml
<dependency>
    <groupId>com.baomidou</groupId>
    <artifactId>mybatis-plus-boot-starter</artifactId>
    <version>3.5.5</version>
</dependency>
```
### 3.2 实现 TenantLineHandler

```java
@Component
public class TenantContext {
    // 使用 ThreadLocal 存储当前请求的租户 ID
    private static final ThreadLocal<Long> CURRENT_TENANT = new ThreadLocal<>();

    public static void setTenantId(Long tenantId) {
        CURRENT_TENANT.set(tenantId);
    }

    public static Long getTenantId() {
        return CURRENT_TENANT.get();
    }

    public static void clear() {
        CURRENT_TENANT.remove();  // 防止内存泄漏
    }
}

@Component
public class CustomTenantHandler implements TenantLineHandler {

    @Override
    public Expression getTenantId() {
        // 从 ThreadLocal 获取当前租户 ID
        Long tenantId = TenantContext.getTenantId();
        if (tenantId == null) {
            throw new IllegalStateException("未设置租户 ID，请检查请求上下文");
        }
        return new LongValue(tenantId);
    }

    @Override
    public String getTenantIdColumn() {
        return "tenant_id";  // 租户字段名
    }

    @Override
    public boolean ignoreTable(String tableName) {
        // 不需要租户隔离的表（如系统配置表、租户信息表本身）
        return Set.of("sys_config", "tenant_info", "sys_dict").contains(tableName.toLowerCase());
    }
}
```
### 3.3 注册插件

```java
@Configuration
public class MybatisPlusConfig {

    @Bean
    public MybatisPlusInterceptor mybatisPlusInterceptor(CustomTenantHandler tenantHandler) {
        MybatisPlusInterceptor interceptor = new MybatisPlusInterceptor();

        // 多租户插件（必须放在分页插件之前）
        interceptor.addInnerInterceptor(new TenantLineInnerInterceptor(tenantHandler));

        // 分页插件
        interceptor.addInnerInterceptor(new PaginationInnerInterceptor(DbType.MYSQL));

        return interceptor;
    }
}
```
### 3.4 Web 拦截器：从请求中提取租户 ID

```java
@Component
public class TenantInterceptor implements HandlerInterceptor {

    @Override
    public boolean preHandle(HttpServletRequest request,
                             HttpServletResponse response, Object handler) {
        // 方式 A：从 JWT Token 中获取租户 ID
        String token = request.getHeader("Authorization");
        if (token != null && token.startsWith("Bearer ")) {
            Long tenantId = JwtUtils.extractTenantId(token.substring(7));
            TenantContext.setTenantId(tenantId);
        }
        return true;
    }

    @Override
    public void afterCompletion(HttpServletRequest request,
                                HttpServletResponse response, Object handler, Exception ex) {
        TenantContext.clear();  // 请求结束后清理 ThreadLocal
    }
}

@Configuration
public class WebConfig implements WebMvcConfigurer {
    @Autowired
    private TenantInterceptor tenantInterceptor;

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(tenantInterceptor)
                .addPathPatterns("/api/**")
                .excludePathPatterns("/api/auth/**");  // 登录接口不需要租户上下文
    }
}
```
### 3.5 效果验证

```java
// 业务代码无需任何改动
@Service
public class OrderService {
    @Autowired
    private OrderMapper orderMapper;

    public List<Order> listOrders() {
        // 实际执行：SELECT * FROM orders WHERE tenant_id = 123
        // ← 自动注入，业务层完全无感
        return orderMapper.selectList(null);
    }
}
```
---

## 四、特殊场景处理

### 4.1 临时忽略租户过滤（超管查所有租户数据）

```java
// 方式 A：使用 @InterceptorIgnore 注解（Mapper 方法级别）
@Mapper
public interface OrderMapper extends BaseMapper<Order> {
    @InterceptorIgnore(tenantLine = "true")
    List<Order> selectAllTenants();  // 忽略租户过滤
}

// 方式 B：编程式临时关闭（线程级别）
TenantContext.setTenantId(null);  // 设置 null 时需要在 getTenantId() 中处理
// 或者通过标志位跳过过滤
```
### 4.2 Insert 时自动填充租户 ID

MyBatis Plus 的多租户插件会在 INSERT 语句中自动加入 eenant_id 字段，也可以结合 MetaObjectHandler 填充：

```java
@Component
public class TenantMetaObjectHandler implements MetaObjectHandler {
    @Override
    public void insertFill(MetaObject metaObject) {
        this.strictInsertFill(metaObject, "tenantId", Long.class, TenantContext.getTenantId());
        this.strictInsertFill(metaObject, "createTime", LocalDateTime.class, LocalDateTime.now());
    }

    @Override
    public void updateFill(MetaObject metaObject) {
        this.strictUpdateFill(metaObject, "updateTime", LocalDateTime.class, LocalDateTime.now());
    }
}
```
---

## 五、常见坑点与最佳实践

### 坑 1：ThreadLocal 未清理导致租户 ID 污染

```java
// ❌ 线程池复用线程，上个请求的 tenantId 污染下个请求
// 必须在 HandlerInterceptor.afterCompletion 或 Filter.finally 中清理
TenantContext.clear();  // 这行必须在 finally 块中执行
```
### 坑 2：ignoreTable 大小写问题

```java
// ❌ 不同数据库表名大小写处理不同
@Override
public boolean ignoreTable(String tableName) {
    return tableName.equals("SYS_CONFIG");  // MySQL 不区分大小写，但传入可能是小写
}

// ✅ 统一转小写比较
@Override
public boolean ignoreTable(String tableName) {
    return Set.of("sys_config", "tenant_info").contains(tableName.toLowerCase());
}
```
### 坑 3：复杂 SQL（子查询/Union）可能注入不完整

JSQLParser 对复杂 SQL 的解析可能不完整，建议对关键复杂查询进行手动验证打印实际 SQL。

---

## 六、总结与延伸

**核心要点**：
- MyBatis Plus 多租户插件通过 JSQLParser 自动注入 eenant_id 条件，零业务侵入
- TenantLineHandler 实现三个方法：当前租户 ID、租户字段名、忽略表列表
- 租户 ID 通过 ThreadLocal 传递，**必须**在请求结束后清理，防止线程池污染
- 超管场景用 @InterceptorIgnore 临时跳过租户过滤

**延伸阅读方向**：
- MyBatis Plus 逻辑删除：@TableLogic + 软删除与多租户的协同处理
- 数据权限插件：DataPermissionInterceptor，按部门/角色过滤数据，类似多租户原理
- Schema 级别多租户：动态切换数据源，Sharding-JDBC 的 Schema 路由策略
- MyBatis Plus 乐观锁：@Version 注解防并发更新，与多租户场景的配合
