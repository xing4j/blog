# Spring AOP 原理：JDK 动态代理 vs CGLIB

<div class="post-meta">📅 2024-08-22 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span> <span class="tag">AOP</span></div>

Spring AOP 底层使用两种代理技术：JDK 动态代理和 CGLIB。理解它们的原理有助于排查 AOP 失效、类型转换等问题。

---

## 一、JDK 动态代理

### 原理

基于**接口**实现，通过 `java.lang.reflect.Proxy` 在运行时生成实现了目标接口的代理类。

```
目标对象实现接口 → Proxy.newProxyInstance() → 生成 $Proxy0
   客户端调用代理 → invoke(InvocationHandler) → 前置增强
                                               → method.invoke(target)
                                               → 后置增强
```

### 核心实现

```java
// 1. 定义接口
public interface UserService {
    User findById(Long id);
}

// 2. 目标实现类
public class UserServiceImpl implements UserService {
    @Override
    public User findById(Long id) {
        return userMapper.selectById(id);
    }
}

// 3. InvocationHandler
public class LogInvocationHandler implements InvocationHandler {

    private final Object target;

    public LogInvocationHandler(Object target) {
        this.target = target;
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        System.out.println("[LOG] Before: " + method.getName());
        long start = System.currentTimeMillis();
        try {
            Object result = method.invoke(target, args);
            System.out.println("[LOG] After: " + (System.currentTimeMillis() - start) + "ms");
            return result;
        } catch (InvocationTargetException e) {
            throw e.getCause(); // 解包真实异常
        }
    }
}

// 4. 创建代理
UserService proxy = (UserService) Proxy.newProxyInstance(
    UserServiceImpl.class.getClassLoader(),
    new Class[]{UserService.class},
    new LogInvocationHandler(new UserServiceImpl())
);
proxy.findById(1L);
```

### 生成的代理类结构（伪代码）

```java
// JVM 动态生成，不可见
public final class $Proxy0 extends Proxy implements UserService {

    public User findById(Long id) {
        // 调用 InvocationHandler.invoke()
        return (User) h.invoke(this, findByIdMethod, new Object[]{id});
    }
}
```

---

## 二、CGLIB 代理

### 原理

基于**继承**实现，通过 ASM 字节码库在运行时生成目标类的子类，重写非 final 方法进行增强。

```
目标类（无需接口）→ Enhancer.create() → 生成 UserServiceImpl$$EnhancerByCGLIB$$xxx
   客户端调用代理 → MethodInterceptor.intercept() → 前置增强
                                                   → invokeSuper()  （调用父类原始方法）
                                                   → 后置增强
```

### 核心实现

```java
// 目标类（不需要接口）
public class OrderService {
    public Order create(OrderDTO dto) {
        return orderMapper.insert(dto);
    }
}

// MethodInterceptor
public class TimingInterceptor implements MethodInterceptor {

    @Override
    public Object intercept(Object obj, Method method,
                            Object[] args, MethodProxy proxy) throws Throwable {
        long start = System.currentTimeMillis();
        System.out.println("[TIMING] Start: " + method.getName());
        try {
            // invokeSuper 调用父类原始方法，不走代理，避免循环调用
            return proxy.invokeSuper(obj, args);
        } finally {
            System.out.println("[TIMING] Cost: " + (System.currentTimeMillis() - start) + "ms");
        }
    }
}

// 创建代理
Enhancer enhancer = new Enhancer();
enhancer.setSuperclass(OrderService.class);
enhancer.setCallback(new TimingInterceptor());
OrderService proxy = (OrderService) enhancer.create();
proxy.create(dto);
```

### 注意：final 方法无法被代理

```java
public class PayService {
    // ❌ final 方法不会被 CGLIB 重写，AOP 对此方法无效
    public final void pay(Order order) {
        // ...
    }
}
```

---

## 三、JDK 代理 vs CGLIB 对比

| 维度 | JDK 动态代理 | CGLIB |
|------|------------|-------|
| 依赖条件 | 目标类必须实现接口 | 目标类不能是 final |
| 生成机制 | `java.lang.reflect.Proxy` | ASM 字节码生成子类 |
| 性能（创建） | 较快 | 较慢（ASM操作字节码） |
| 性能（调用） | 反射调用，稍慢 | 直接方法调用，更快 |
| final 方法 | 可代理（接口方法） | 不可代理 |
| Spring 默认 | 实现接口时使用 | 无接口/强制时使用 |
| 依赖 | JDK 内置 | 需要 cglib/spring-core 内置 |

---

## 四、Spring 何时选择哪种代理

```
Bean 创建完成（BeanPostProcessor.postProcessAfterInitialization）
         │
         ▼
是否有接口？
    ├─ 是 → 默认使用 JDK 动态代理
    │         但设置 proxyTargetClass=true → 强制 CGLIB
    └─ 否 → 使用 CGLIB
```

强制使用 CGLIB（推荐统一使用，避免类型转换问题）：

```java
// 方式1：全局配置
@EnableAspectJAutoProxy(proxyTargetClass = true)
@SpringBootApplication
public class Application {}

// 方式2：配置文件（Spring Boot 2.x 默认已设为 true）
spring.aop.proxy-target-class=true
```

---

## 五、自调用失效问题

### 问题描述

```java
@Service
public class ArticleService {

    // ❌ 直接调用 this.save()，绕过代理，@Transactional 失效
    public void publish(Article article) {
        this.save(article); // this 是原始对象，不是代理
        notifySubscribers(article);
    }

    @Transactional
    public void save(Article article) {
        articleMapper.insert(article);
    }
}
```

### 解决方案一：通过 AopContext 获取代理

```java
@Service
public class ArticleService {

    public void publish(Article article) {
        // 通过 AopContext 拿到当前代理对象
        ((ArticleService) AopContext.currentProxy()).save(article);
        notifySubscribers(article);
    }

    @Transactional
    public void save(Article article) {
        articleMapper.insert(article);
    }
}

// 需要开启 exposeProxy
@EnableAspectJAutoProxy(exposeProxy = true)
```

### 解决方案二：注入自身

```java
@Service
public class ArticleService {

    @Lazy
    @Autowired
    private ArticleService self; // @Lazy 避免循环依赖

    public void publish(Article article) {
        self.save(article); // 通过代理调用
    }

    @Transactional
    public void save(Article article) {
        articleMapper.insert(article);
    }
}
```

### 解决方案三：拆分 Service（最佳实践）

```java
@Service
public class ArticlePublishService {
    @Autowired
    private ArticlePersistService persistService;

    public void publish(Article article) {
        persistService.save(article); // 跨 Bean 调用，代理正常工作
        notifySubscribers(article);
    }
}

@Service
public class ArticlePersistService {
    @Transactional
    public void save(Article article) {
        articleMapper.insert(article);
    }
}
```

---

## 六、自定义切面示例

```java
@Aspect
@Component
public class PerformanceAspect {

    // 切点：service 包下所有 public 方法
    @Pointcut("execution(public * com.example.service..*(..))")
    public void serviceLayer() {}

    @Around("serviceLayer()")
    public Object timeAround(ProceedingJoinPoint pjp) throws Throwable {
        long start = System.currentTimeMillis();
        String method = pjp.getSignature().toShortString();
        try {
            return pjp.proceed();
        } finally {
            long cost = System.currentTimeMillis() - start;
            if (cost > 500) {
                log.warn("[SLOW] {} 耗时 {}ms", method, cost);
            }
        }
    }

    // 注解驱动切点
    @Before("@annotation(com.example.annotation.RequirePermission)")
    public void checkPermission(JoinPoint jp) {
        // 权限校验逻辑
    }
}
```

---

## 七、总结

- **JDK 代理**：轻量，基于接口，调用时有反射开销
- **CGLIB**：基于继承，无需接口，不能代理 `final` 方法/类
- Spring Boot 2.x 起默认使用 CGLIB（`proxyTargetClass=true`）
- 自调用问题是 AOP 最常见的坑，优先选择**拆分 Service** 的方式解决
- 理解代理原理，有助于排查 `ClassCastException` 和事务失效问题
