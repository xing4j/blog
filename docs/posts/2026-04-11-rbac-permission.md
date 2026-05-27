# RBAC 权限设计与 Spring Security 实现

<div class="post-meta">📅 2026-04-11 &nbsp;·&nbsp; 🏷️ <span class="tag">权限</span> <span class="tag">系统设计</span></div>

RBAC（Role-Based Access Control，基于角色的访问控制）是企业系统最常用的权限模型。

---

## 一、RBAC 模型

```
RBAC0（基础）：用户 -> 角色 -> 权限

用户（User）   多对多   角色（Role）   多对多   权限（Permission）
  admin         <-->     ADMIN         <-->      user:read
  alice         <-->     MANAGER       <-->      user:write
                <-->     VIEWER        <-->      order:read

RBAC1（角色继承）：
ADMIN 继承 MANAGER，MANAGER 继承 VIEWER

RBAC2（约束）：
互斥角色（出纳不能同时是审计员）
最大会话数限制
```

---

## 二、数据库设计

```sql
-- 5张核心表
CREATE TABLE sys_user (
    id      BIGINT PRIMARY KEY AUTO_INCREMENT,
    username VARCHAR(50) NOT NULL UNIQUE,
    password VARCHAR(100) NOT NULL,
    status  TINYINT DEFAULT 1  -- 1:启用 0:禁用
);

CREATE TABLE sys_role (
    id       BIGINT PRIMARY KEY AUTO_INCREMENT,
    code     VARCHAR(50) NOT NULL UNIQUE,  -- ROLE_ADMIN
    name     VARCHAR(50) NOT NULL
);

CREATE TABLE sys_permission (
    id       BIGINT PRIMARY KEY AUTO_INCREMENT,
    code     VARCHAR(100) NOT NULL UNIQUE, -- user:list, user:edit
    name     VARCHAR(50),
    type     TINYINT,  -- 1:菜单 2:按钮 3:接口
    parent_id BIGINT DEFAULT 0
);

-- 关联表
CREATE TABLE sys_user_role (
    user_id BIGINT,
    role_id BIGINT,
    PRIMARY KEY (user_id, role_id)
);

CREATE TABLE sys_role_permission (
    role_id       BIGINT,
    permission_id BIGINT,
    PRIMARY KEY (role_id, permission_id)
);
```

---

## 三、Spring Security + JWT 集成

```java
// 加载用户权限
@Service
public class UserDetailsServiceImpl implements UserDetailsService {
    @Autowired
    private UserMapper userMapper;
    @Autowired
    private PermissionMapper permissionMapper;

    @Override
    public UserDetails loadUserByUsername(String username) {
        User user = userMapper.findByUsername(username);
        if (user == null) throw new UsernameNotFoundException(username);

        // 查询用户的所有权限码
        List<String> perms = permissionMapper.findCodesByUserId(user.getId());
        
        List<GrantedAuthority> authorities = perms.stream()
            .map(SimpleGrantedAuthority::new)
            .collect(Collectors.toList());
        
        return new org.springframework.security.core.userdetails.User(
            username, user.getPassword(), authorities);
    }
}

// 接口权限控制
@RestController
@RequestMapping("/user")
public class UserController {
    
    @GetMapping("/list")
    @PreAuthorize("hasAuthority('user:list')")  // 检查权限码
    public List<User> list() { ... }

    @PostMapping
    @PreAuthorize("hasAuthority('user:add')")
    public User create(@RequestBody UserCreateReq req) { ... }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('user:delete')")
    public void delete(@PathVariable Long id) { ... }
    
    // 角色检查
    @GetMapping("/admin/stats")
    @PreAuthorize("hasRole('ADMIN')")
    public StatsVO getStats() { ... }
}
```

---

## 四、菜单权限过滤

```java
// 前端动态路由：根据用户权限返回可访问的菜单
@GetMapping("/menus")
public List<MenuVO> getUserMenus() {
    Long userId = SecurityUtils.getCurrentUserId();
    List<Permission> allMenus = permissionMapper.findMenusByUserId(userId);
    // 构建树形结构
    return buildMenuTree(allMenus, 0L);
}

private List<MenuVO> buildMenuTree(List<Permission> perms, Long parentId) {
    return perms.stream()
        .filter(p -> p.getParentId().equals(parentId))
        .map(p -> {
            MenuVO menu = new MenuVO(p);
            List<MenuVO> children = buildMenuTree(perms, p.getId());
            menu.setChildren(children);
            return menu;
        })
        .collect(Collectors.toList());
}
```

---

## 五、数据权限（行级权限）

```java
// 场景：销售员只能看自己的订单，经理能看部门订单

// 方案：MyBatis 拦截器动态添加 WHERE 条件
@Intercepts({@Signature(type = Executor.class, method = "query", args = {...})})
public class DataScopeInterceptor implements Interceptor {
    @Override
    public Object intercept(Invocation invocation) throws Throwable {
        // 获取当前用户角色
        UserContext user = SecurityUtils.getCurrentUser();
        
        // 根据角色追加 SQL 条件
        MappedStatement ms = (MappedStatement) invocation.getArgs()[0];
        BoundSql boundSql = ms.getBoundSql(invocation.getArgs()[1]);
        String sql = boundSql.getSql();
        
        String dataScopeSql = switch (user.getDataScope()) {
            case SELF     -> " AND creator_id = " + user.getId();
            case DEPT     -> " AND dept_id = " + user.getDeptId();
            case DEPT_AND_CHILD -> buildDeptSql(user.getDeptId());
            default       -> "";  // 全部数据
        };
        
        // 将条件拼入 SQL ...
        return invocation.proceed();
    }
}
```

---

## 六、权限缓存

```java
// Redis 缓存用户权限（避免每次查库）
@Service
public class PermissionCacheService {
    private static final String PERM_KEY = "user:perm:";
    
    public Set<String> getUserPermissions(Long userId) {
        String key = PERM_KEY + userId;
        Set<String> cached = redisTemplate.opsForSet().members(key);
        if (cached != null && !cached.isEmpty()) return cached;
        
        // 查库
        Set<String> perms = permissionMapper.findCodesByUserId(userId)
            .stream().collect(Collectors.toSet());
        
        redisTemplate.opsForSet().add(key, perms.toArray(new String[0]));
        redisTemplate.expire(key, Duration.ofHours(1));
        return perms;
    }
    
    // 修改权限后清除缓存
    public void clearUserPermCache(Long userId) {
        redisTemplate.delete(PERM_KEY + userId);
    }
}
```

---

## 总结

| 层次 | 实现方案 |
|------|---------|
| 菜单权限 | 根据用户角色动态返回菜单树 |
| 接口权限 | `@PreAuthorize` + Spring Security |
| 数据权限 | MyBatis 拦截器动态追加 SQL 条件 |
| 权限缓存 | Redis 缓存权限码，修改时清除 |
| 前端按钮 | `v-if="hasPermission('user:edit')"` |
