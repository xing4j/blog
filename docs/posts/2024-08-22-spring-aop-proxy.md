# Spring AOP 代理机制：从 @Aspect 到字节码增强

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> - 👉 **SB-06 Spring AOP 代理机制：JDK vs CGLIB（本文）**
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](posts/2026-05-24-spring-boot-startup.md)
> - [SB-08 Spring Boot 自动装配原理深度解析](posts/2024-10-27-spring-boot-autoconfigure.md)
> - [SB-09 Spring Boot 配置体系详解](posts/2026-05-16-spring-boot-config-priority.md)
> - [SB-10 Spring Boot 条件装配：@Conditional 体系](posts/2026-05-24-spring-boot-conditional.md)
> - [SB-11 Spring 循环依赖：三级缓存的设计原理](posts/2026-05-24-spring-circular-dependency.md)
> - [SB-12 Filter、Interceptor、AOP 三者对比与选型](posts/2026-05-24-spring-filter-interceptor-aop.md)
> - [SB-13 Spring 事件驱动：ApplicationEvent 与监听器](posts/2026-05-24-spring-events.md)
> - [SB-14 Spring @Async 异步编程：原理与线程池配置](posts/2026-05-24-spring-async.md)
> - [SB-15 Spring 扩展点：BPP、BFPP 与 ImportSelector](posts/2026-05-24-spring-extension-points.md)
> - [SB-16 Spring Boot 全局异常处理与参数校验](posts/2026-05-24-spring-exception-handler.md)
> - [SB-17 Spring Boot 多数据源：动态路由与跨库事务](posts/2026-05-24-spring-boot-multi-datasource.md)
> - [SB-18 Spring Boot Actuator：健康检查与自定义端点](posts/2026-05-24-spring-boot-actuator.md)
> - [SB-19 Spring Boot 自定义 Starter：从设计到发布](posts/2026-05-24-spring-boot-custom-starter.md)
> - [SB-20 Spring Security 认证授权完整流程](posts/2024-12-23-spring-security-auth.md)
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](posts/2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](posts/2026-05-24-spring-boot-testing.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 18 分钟｜**分类**：Spring 生态

<div class="post-meta">📅 2024-08-22 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

## 导读

日志切面加了、方法执行时间打印了，但突然发现同类内方法调用时切面没生效。理解 Spring AOP 的代理实现原理，才能知道它能做什么，不能做什么，以及什么情况下该换用 AspectJ 编译时织入。

---

## 一、背景：AOP 解决什么问题

面向切面编程（AOP）将**横切关注点**（日志、事务、权限、监控）从业务代码中剥离，以声明式的方式统一处理：

```
Without AOP:                   With AOP:
┌──────────────┐              ┌──────────────┐
│ Business Code│              │ Business Code│ <- focus on biz
│ + Logging    │              └──────────────┘
│ + Tx Code    │                      ↑
│ + Auth Code  │              ┌───────────────┐
└──────────────┘              │ Aspect (Cross)│ Log/Tx/Auth
                              └───────────────┘
```
Spring AOP 是**运行时代理**，不修改原始字节码，通过动态代理在方法调用前后插入逻辑。

---

## 二、两种代理模式：JDK vs CGLIB

### JDK 动态代理

要求目标类**实现接口**，代理对象是接口的实现类：

```
IUserService（接口）
    ↑                ← 代理对象实现相同接口
UserService（目标）  ← 被代理的真实对象
    ↑
UserServiceProxy（JDK代理）
```
```java
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
```
### CGLIB 代理

通过继承目标类生成子类，不需要接口：

```
UserService（目标类）
    ↑
UserServiceDone: spring-bean-lifecycle.mdEnhancerByCGLIB（CGLIB生成的子类）← 代理对象
```
```java
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
```
### Spring 选择策略

| 条件 | 代理方式 |
|------|---------|
| 目标类实现了接口（默认）| JDK 动态代理 |
| 目标类未实现接口 | CGLIB |
| @EnableAspectJAutoProxy(proxyTargetClass=true) | 强制 CGLIB |
| Spring Boot 2.x+（默认）| 强制 CGLIB（避免接口代理的类型转换问题）|

---

## 三、五种通知类型与完整切面示例

```java
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
```
**执行顺序（正常情况）**：@Around(前) → @Before → 目标方法 → @AfterReturning → @After → @Around(后)

**执行顺序（异常情况）**：@Around(前) → @Before → 目标方法抛异常 → @AfterThrowing → @After

---

## 四、切入点表达式速查

```java
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
```
---

## 五、常见坑点与最佳实践

### 坑 1：同类内部调用切面不生效

```java
@Service
public class OrderService {
    @Transactional  // 本质是 AOP 切面
    public void placeOrder(Order order) {
        saveOrder(order);
        this.updateStock();  // ❌ this 调用绕过代理，@Transactional 失效
    }

    public void updateStock() { ... }
}
```
### 坑 2：final 方法/类无法被 CGLIB 代理

```java
@Service
public final class PayService {  // ❌ final 类，CGLIB 无法继承生成子类
    public final void pay() { }  // ❌ final 方法，CGLIB 无法重写
}
```
### 坑 3：@Around 忘记调用 proceed()

```java
@Around("controllerMethods()")
public Object around(ProceedingJoinPoint pjp) throws Throwable {
    log.info("before");
    // ❌ 忘记 pjp.proceed()，目标方法永远不会执行！
    return null;

    // ✅
    // Object result = pjp.proceed();
    // return result;
}
```
### 坑 4：多切面执行顺序

同一个方法被多个切面拦截时，用 @Order 控制顺序（数字越小优先级越高）：

```java
@Aspect
@Component
@Order(1)  // 最外层，先进后出
public class LogAspect { ... }

@Aspect
@Component
@Order(2)  // 内层
public class TransactionAspect { ... }
```
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

## 七、踩坑总结

❌ **切面不生效：同类内部方法 A 调用方法 B，方法 B 的 `@Around` 切面没有执行**

✅ Spring AOP 基于动态代理，同类内部调用走的是 `this.method()`，绕过了代理对象，切面拦截器不会介入。解决方案：①将方法 B 抽取到单独的 Bean 中；②通过 `AopContext.currentProxy()` 获取代理对象调用（需配置 `exposeProxy = true`）；③真正需要内部调用拦截时，用 AspectJ 编译时织入。

❌ **`@Order` 设置了切面顺序，但多个切面在同一个方法上的执行顺序不符合预期**

✅ `@Order` 数字越小优先级越高，但只控制同一切入点多个切面间的**外层/内层**关系：外层切面先执行 Before，后执行 After。事务切面必须是最内层（离目标方法最近），日志/鉴权切面在外层——所以事务切面的 `@Order` 值应最大（或不设置，默认 `Integer.MAX_VALUE`）。

---

## 八、文章小结

- Spring AOP 基于运行时代理（JDK 接口代理 / CGLIB 子类代理），Spring Boot 2+ 默认使用 CGLIB
- JDK 代理要求实现接口，CGLIB 通过继承（`final` 类和方法无法被代理）
- 五种通知类型：`@Before` / `@After` / `@AfterReturning` / `@AfterThrowing` / `@Around`（最强大）
- 内部方法调用是切面不生效的首要原因，根本原因是调用路径绕过了代理对象
- `@Order` 控制切面优先级，值越小越靠外；事务切面应是最内层，避免事务在鉴权前开启

---

## 九、思考题

1. `@Around` 通知中调用了 `pjp.proceed()`，而 `@Before` 通知中抛出了异常，`@Around` 能捕获到这个异常吗？`@After` 通知会执行吗？

2. Spring Boot 默认使用 CGLIB 代理，但如果目标类是 `final` 的，会怎样？有什么解决方案？

---

## 参考资料

> 1. [Spring 官方文档 - Aspect Oriented Programming with Spring](https://docs.spring.io/spring-framework/reference/core/aop.html)
> 2. [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> 3. [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> 4. [SB-12 Filter、Interceptor、AOP 三者对比与选型](posts/2026-05-24-spring-filter-interceptor-aop.md)
