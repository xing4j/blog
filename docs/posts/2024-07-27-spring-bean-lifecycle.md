# Spring Bean 的完整生命周期：从出生到销毁的 14 步

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> - 👉 **SB-02 Spring Bean 生命周期深度解析（本文）**
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
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

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 15 分钟｜**分类**：Spring 生态

<div class="post-meta">📅 2024-07-27 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

## 导读

面试常问"Spring Bean 的生命周期"，很多人只能说出"实例化→依赖注入→初始化→销毁"四步。实际上完整流程有 14 个关键节点，这些扩展点是框架集成（MyBatis、Dubbo、Nacos）的基础，也是排查 Bean 初始化顺序问题的关键。

---

## 一、背景：为什么 Spring 需要如此精细的生命周期管理

Spring IoC 容器不仅负责创建 Bean，还要：
- 在合适的时机注入依赖
- 初始化之前/之后执行框架逻辑（如 AOP 代理生成）
- 允许用户在任意节点插入自定义逻辑

这套扩展点设计使得 Spring 成为可扩展的框架平台，而非封闭的 IoC 容器。

---

## 二、完整生命周期：14 个关键节点

```
Bean 定义加载（BeanDefinition 读取 XML / 注解）
    v
1.  BeanDefinitionRegistryPostProcessor.postProcessBeanDefinitionRegistry()
2.  BeanFactoryPostProcessor.postProcessBeanFactory()
    v
实例化（Constructor / 工厂方法）
    v
3.  InstantiationAwareBeanPostProcessor.postProcessBeforeInstantiation()
4.  [实例化]
5.  InstantiationAwareBeanPostProcessor.postProcessAfterInstantiation()
    v
属性填充（依赖注入）
    v
6.  BeanNameAware.setBeanName()
7.  BeanClassLoaderAware.setBeanClassLoader()
8.  BeanFactoryAware.setBeanFactory()
9.  ApplicationContextAware.setApplicationContext()
    v
10. BeanPostProcessor.postProcessBeforeInitialization()   <- @PostConstruct 在这之中
    v
11. InitializingBean.afterPropertiesSet()
12. @Bean(initMethod) 或 init-method
    v
13. BeanPostProcessor.postProcessAfterInitialization()   <- AOP 代理在此生成
    v
[Bean 就绪，放入容器]
    v
14. [容器关闭] DisposableBean.destroy() / @Bean(destroyMethod)
```
---

## 三、各扩展点使用场景

### 3.1 BeanFactoryPostProcessor：修改 Bean 定义

在所有 Bean 实例化前执行，可以修改 Bean 的元数据：

```java
@Component
public class MyBeanFactoryPostProcessor implements BeanFactoryPostProcessor {
    @Override
    public void postProcessBeanFactory(ConfigurableListableBeanFactory factory) {
        // 例：动态修改某个 Bean 的属性值
        BeanDefinition bd = factory.getBeanDefinition("dataSource");
        bd.getPropertyValues().add("url", "jdbc:mysql://prod-server/db");
    }
}
```
PropertyPlaceholderConfigurer（${...} 占位符替换）就是 BeanFactoryPostProcessor 的实现。

### 3.2 Aware 接口：让 Bean 感知容器

```java
@Component
public class SpringContextHolder implements ApplicationContextAware, DisposableBean {
    private static ApplicationContext context;

    @Override
    public void setApplicationContext(ApplicationContext ctx) {
        SpringContextHolder.context = ctx;
    }

    // 静态方法从容器获取 Bean（工具类场景使用）
    public static <T> T getBean(Class<T> clazz) {
        return context.getBean(clazz);
    }

    @Override
    public void destroy() {
        context = null;
    }
}
```
### 3.3 @PostConstruct / @PreDestroy（推荐的初始化方式）

```java
@Service
public class CacheService {
    private Map<String, Object> localCache;

    @PostConstruct
    public void init() {
        // Bean 实例化+注入完成后立即执行
        // 此时可以安全使用所有注入的依赖
        localCache = loadCacheFromRedis();
        log.info("本地缓存初始化完成，共 {} 条", localCache.size());
    }

    @PreDestroy
    public void cleanup() {
        // 容器关闭前执行
        localCache.clear();
        log.info("本地缓存已清理");
    }
}
```
### 3.4 BeanPostProcessor：最重要的扩展点

```java
@Component
public class LogBeanPostProcessor implements BeanPostProcessor {
    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) {
        // 在 @PostConstruct 之前执行
        return bean;
    }

    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) {
        // 在 @PostConstruct 之后执行
        // Spring AOP 就在这里用代理对象替换原始 bean
        if (bean instanceof UserService) {
            log.info("UserService Bean 初始化完成: {}", beanName);
        }
        return bean;  // 可以返回包装后的对象（AOP 代理）
    }
}
```
**重要**：postProcessAfterInitialization 返回的对象就是最终注入到其他 Bean 的对象，AOP 正是在此处用代理对象替换原始对象。

---

## 四、初始化方式优先级对比

同一个 Bean 中，三种初始化方式的执行顺序：

```
@PostConstruct -> afterPropertiesSet() -> initMethod
```
```java
@Component
public class OrderService implements InitializingBean {

    @PostConstruct
    public void postConstruct() {
        System.out.println("1. @PostConstruct");  // 最先执行
    }

    @Override
    public void afterPropertiesSet() {
        System.out.println("2. afterPropertiesSet");  // 第二
    }

    public void initMethod() {
        System.out.println("3. initMethod");  // 最后执行
    }
}
// @Bean(initMethod = "initMethod") 时触发 initMethod
```
**推荐**：优先使用 @PostConstruct，语义清晰，无需实现 Spring 接口（低侵入性）。

---

## 五、常见坑点与最佳实践

### 坑 1：在构造函数中使用尚未注入的依赖

```java
@Service
public class OrderService {
    @Autowired
    private UserService userService;

    // ❌ 构造函数执行时，@Autowired 还未注入，userService 为 null
    public OrderService() {
        userService.doSomething();  // NullPointerException!
    }

    // ✅ 使用 @PostConstruct，此时所有依赖已注入
    @PostConstruct
    public void init() {
        userService.doSomething();
    }
}
```
### 坑 2：BeanPostProcessor 依赖了普通 Bean，导致后者无法被 AOP 代理

```java
// ❌ BeanPostProcessor 初始化时会触发其依赖的 Bean 提前实例化
// 如果 DataService 被依赖，它会在 AOP BeanPostProcessor 之前就实例化，
// 导致 DataService 的 AOP 代理失效
@Component
public class MyPostProcessor implements BeanPostProcessor {
    @Autowired
    private DataService dataService;  // ❌ 导致 DataService 过早实例化
}
```
解决：通过 ApplicationContext.getBean() 懒获取，避免构造时注入。

### 坑 3：@PostConstruct 中开启异步任务，但 @Async 代理尚未生成

```java
@Service
public class TaskService {
    @PostConstruct
    public void startTask() {
        // ❌ @PostConstruct 在 BeanPostProcessor.after 之前执行
        // 此时 @Async 代理可能尚未生成，asyncMethod() 会在当前线程同步执行
        asyncMethod();
    }

    @Async
    public void asyncMethod() { ... }
}
```
---

## 六、踩坑总结

❌ **在构造函数中调用 `@Autowired` 注入的依赖，触发 NullPointerException**

✅ 字段注入（`@Autowired`）在构造函数之后、`@PostConstruct` 之前执行。构造函数执行时依赖尚未注入。解决方案：将初始化逻辑移到 `@PostConstruct` 方法中，或改为构造器注入（推荐，依赖在构造时传入）。

❌ **`BeanPostProcessor` 实现类中 `@Autowired` 了普通 Service，导致该 Service 无法生成 AOP 代理**

✅ `BeanPostProcessor` 在容器启动早期初始化，其依赖的 Bean 会被提前实例化，可能跳过后续注册的 AOP `BeanPostProcessor`。解决方案：在 `BeanPostProcessor` 中使用 `@Lazy` 延迟注入，或在方法内通过 `ApplicationContext.getBean()` 懒获取依赖。

---

## 七、文章小结

- Bean 完整生命周期有 14 个关键节点，分为容器初始化期、Bean 创建期（实例化→属性注入→Aware 回调→初始化）、销毁期
- 三种初始化方式执行顺序：`@PostConstruct` → `afterPropertiesSet()` → `initMethod`，推荐 `@PostConstruct`（低侵入）
- `BeanPostProcessor.postProcessAfterInitialization()` 是 AOP 代理生成时机，返回值就是最终注入到其他 Bean 的对象
- `BeanFactoryPostProcessor` 在所有 Bean 实例化之前执行，可修改 `BeanDefinition` 元数据（如 PropertyPlaceholderConfigurer）
- `BeanPostProcessor` 的 `@Autowired` 依赖会导致被依赖的 Bean 提前实例化，可能绕过 AOP 代理，需用 `@Lazy` 避免

---

## 八、思考题

1. Bean A 和 Bean B 互相依赖（字段注入），Spring 的三级缓存是如何解决这个问题的？`BeanPostProcessor` 在哪一步生成 AOP 代理？

2. `@PostConstruct` 方法中调用了一个标注了 `@Async` 的方法，结果发现异步没有生效，为什么？如何修复？

---

## 参考资料

> 1. Spring Framework 源码：`AbstractAutowireCapableBeanFactory.doCreateBean()`（版本：6.1）
> 2. [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> 3. [SB-11 Spring 循环依赖：三级缓存的设计原理](posts/2026-05-24-spring-circular-dependency.md)
> 4. [SB-14 Spring @Async 异步编程：原理与线程池配置](posts/2026-05-24-spring-async.md)
