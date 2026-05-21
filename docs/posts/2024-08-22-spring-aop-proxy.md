# Spring AOP 代理机制：从 @Aspect 到字节码增强

<div class="post-meta">📅 2024-08-22 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

日志切面加了、方法执行时间打印了，但突然发现同类内方法调用时切面没生效。理解 Spring AOP 的代理实现原理，才能知道它能做什么，不能做什么，以及什么情况下该换用 AspectJ 编译时织入。

---

## 一、背景：AOP 解决什么问题

面向切面编程（AOP）将**横切关注点**（日志、事务、权限、监控）从业务代码中剥离，以声明式的方式统一处理：

`
没有 AOP：                     有 AOP：
┌──────────────┐              ┌──────────────┐
│ 业务代码      │              │ 业务代码      │ ← 只关注业务
│ + 日志代码   │              └──────────────┘
│ + 事务代码   │                      ↑
│ + 权限代码   │              ┌───────────────┐
└──────────────┘              │ 切面（横切）   │ 日志/事务/权限
                              └───────────────┘
`

Spring AOP 是**运行时代理**，不修改原始字节码，通过动态代理在方法调用前后插入逻辑。

---

## 二、两种代理模式：JDK vs CGLIB

### JDK 动态代理

要求目标类**实现接口**，代理对象是接口的实现类：

`
IUserService（接口）
    ↑                ← 代理对象实现相同接口
UserService（目标）  ← 被代理的真实对象
    ↑
UserServiceProxy（JDK代理）
`

`java
// JDK 动态代理原理简化版
IUserService proxy = (IUserService) Proxy.newProxyInstance(
    UserService.class.getClassLoader(),
    new Class[]{IUserService.class},   // 代理实现的接口
    (proxyObj, method, args) -> {
        System.out.println("Before: " + method.getName());
        Object result = method.invoke(target, args);  // 调用真实方法
        System.out.println("After: " + method.getName());
        return result;
    }
);
`

### CGLIB 代理

通过继承目标类生成子类，不需要接口：

`
UserService（目标类）
    ↑
UserServiceDone: spring-bean-lifecycle.mdEnhancerByCGLIB（CGLIB生成的子类）← 代理对象
`

`java
// CGLIB 通过字节码库（ASM）在运行时生成目标类的子类
// 子类重写所有方法，在方法调用前后插入拦截逻辑
Enhancer enhancer = new Enhancer();
enhancer.setSuperclass(UserService.class);
enhancer.setCallback((MethodInterceptor) (obj, method, args, proxy) -> {
    System.out.println("Before: " + method.getName());
    Object result = proxy.invokeSuper(obj, args);  // 调用父类方法
    System.out.println("After: " + method.getName());
    return result;
});
UserService proxy = (UserService) enhancer.create();
`

### Spring 选择策略

| 条件 | 代理方式 |
|------|---------|
| 目标类实现了接口（默认）| JDK 动态代理 |
| 目标类未实现接口 | CGLIB |
| @EnableAspectJAutoProxy(proxyTargetClass=true) | 强制 CGLIB |
| Spring Boot 2.x+（默认）| 强制 CGLIB（避免接口代理的类型转换问题）|

---

## 三、五种通知类型与完整切面示例

`java
@Aspect
@Component
public class ApiMonitorAspect {

    // 定义切入点：所有 Controller 层方法
    @Pointcut("execution(* com.example.controller..*.*(..))")
    public void controllerMethods() {}

    // 前置通知：方法执行前
    @Before("controllerMethods()")
    public void beforeAdvice(JoinPoint joinPoint) {
        log.info("[BEFORE] {}.{}",
            joinPoint.getTarget().getClass().getSimpleName(),
            joinPoint.getSignature().getName());
    }

    // 后置通知：方法正常返回后（不捕获异常）
    @AfterReturning(pointcut = "controllerMethods()", returning = "result")
    public void afterReturning(Object result) {
        log.info("[AFTER_RETURNING] result={}", result);
    }

    // 异常通知：方法抛出异常时
    @AfterThrowing(pointcut = "controllerMethods()", throwing = "ex")
    public void afterThrowing(Exception ex) {
        log.error("[AFTER_THROWING] exception={}", ex.getMessage());
    }

    // 最终通知：无论正常/异常都执行（类似 finally）
    @After("controllerMethods()")
    public void afterAdvice() {
        log.info("[AFTER] method completed");
    }

    // 环绕通知：最强大，可以控制方法是否执行
    @Around("controllerMethods()")
    public Object aroundAdvice(ProceedingJoinPoint pjp) throws Throwable {
        long start = System.currentTimeMillis();
        String methodName = pjp.getSignature().getName();

        try {
            Object result = pjp.proceed();  // 执行目标方法
            long cost = System.currentTimeMillis() - start;
            log.info("[AROUND] {} 耗时 {}ms", methodName, cost);
            return result;
        } catch (Throwable e) {
            log.error("[AROUND] {} 发生异常: {}", methodName, e.getMessage());
            throw e;
        }
    }
}
`

**执行顺序（正常情况）**：@Around(前) → @Before → 目标方法 → @AfterReturning → @After → @Around(后)

**执行顺序（异常情况）**：@Around(前) → @Before → 目标方法抛异常 → @AfterThrowing → @After

---

## 四、切入点表达式速查

`java
// execution 语法：execution(修饰符 返回类型 包名.类名.方法名(参数))
execution(* com.example.service.*.*(..))          // service 下所有类的所有方法
execution(public * *(..))                          // 所有 public 方法
execution(* get*(..))                              // 所有 get 开头的方法
execution(* com.example..*.*(..))                  // example 包及子包的所有方法
execution(* *(String, ..))                         // 第一个参数是 String 的方法

// @annotation：匹配带特定注解的方法
@annotation(com.example.annotation.RequireLogin)

// @within：匹配带特定注解的类的所有方法
@within(org.springframework.stereotype.Service)

// args：匹配特定参数类型的方法
args(java.lang.String, ..)
`

---

## 五、常见坑点与最佳实践

### 坑 1：同类内部调用切面不生效

`java
@Service
public class OrderService {
    @Transactional  // 本质是 AOP 切面
    public void placeOrder(Order order) {
        saveOrder(order);
        this.updateStock();  // ❌ this 调用绕过代理，@Transactional 失效
    }

    public void updateStock() { ... }
}
`

### 坑 2：final 方法/类无法被 CGLIB 代理

`java
@Service
public final class PayService {  // ❌ final 类，CGLIB 无法继承生成子类
    public final void pay() { }  // ❌ final 方法，CGLIB 无法重写
}
`

### 坑 3：@Around 忘记调用 proceed()

`java
@Around("controllerMethods()")
public Object around(ProceedingJoinPoint pjp) throws Throwable {
    log.info("before");
    // ❌ 忘记 pjp.proceed()，目标方法永远不会执行！
    return null;

    // ✅
    // Object result = pjp.proceed();
    // return result;
}
`

### 坑 4：多切面执行顺序

同一个方法被多个切面拦截时，用 @Order 控制顺序（数字越小优先级越高）：

`java
@Aspect
@Component
@Order(1)  // 最外层，先进后出
public class LogAspect { ... }

@Aspect
@Component
@Order(2)  // 内层
public class TransactionAspect { ... }
`

---

## 六、Spring AOP vs AspectJ

| 特性 | Spring AOP | AspectJ |
|------|-----------|---------|
| 织入时机 | 运行时（代理） | 编译时/加载时/运行时 |
| 适用范围 | 仅 Spring 管理的 Bean | 任何 Java 类 |
| 是否能拦截 static/final | ❌ | ✅ |
| 性能 | 略有代理开销 | 接近原生（编译时织入）|
| 复杂性 | 低，开箱即用 | 高，需要配置编译器/Agent |
| 适用场景 | 企业应用日志/事务/权限 | SDK 级别、性能敏感场景 |

---

## 七、总结与延伸

**核心要点**：
- Spring AOP 基于动态代理（JDK/CGLIB），运行时生成代理对象
- JDK 代理需要接口，CGLIB 通过继承（Spring Boot 2+ 默认 CGLIB）
- **内部方法调用不经过代理**，是切面不生效的首要原因
- 五种通知类型：@Before/@After/@AfterReturning/@AfterThrowing/@Around

**延伸阅读方向**：
- AspectJ 编译时织入：彻底解决内部调用问题，适合 SDK 级别切面
- Spring 事务实现：TransactionInterceptor 是最复杂的 AOP 应用
- ProxyFactory API：编程式创建 AOP 代理，理解代理工厂的工作原理
- Arthas 	race 命令：生产环境动态追踪方法调用链，AOP 的终极调试工具
