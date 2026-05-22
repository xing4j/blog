# Spring Bean 的完整生命周期：从出生到销毁的 14 步

<div class="post-meta">📅 2024-07-27 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

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
    ↓
1.  BeanDefinitionRegistryPostProcessor.postProcessBeanDefinitionRegistry()
2.  BeanFactoryPostProcessor.postProcessBeanFactory()
    ↓
实例化（Constructor / 工厂方法）
    ↓
3.  InstantiationAwareBeanPostProcessor.postProcessBeforeInstantiation()
4.  [实例化]
5.  InstantiationAwareBeanPostProcessor.postProcessAfterInstantiation()
    ↓
属性填充（依赖注入）
    ↓
6.  BeanNameAware.setBeanName()
7.  BeanClassLoaderAware.setBeanClassLoader()
8.  BeanFactoryAware.setBeanFactory()
9.  ApplicationContextAware.setApplicationContext()
    ↓
10. BeanPostProcessor.postProcessBeforeInitialization()   ← @PostConstruct 在这之中
    ↓
11. InitializingBean.afterPropertiesSet()
12. @Bean(initMethod) 或 init-method
    ↓
13. BeanPostProcessor.postProcessAfterInitialization()   ← AOP 代理在此生成
    ↓
[Bean 就绪，放入容器]
    ↓
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
@PostConstruct → afterPropertiesSet() → initMethod
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

## 六、总结与延伸

**完整生命周期 14 步速记**：
- **容器初始化期**：BeanDefinitionRegistryPostProcessor → BeanFactoryPostProcessor
- **Bean 创建期**：实例化 → 属性注入 → Aware 回调 → BeanPostProcessor.before → 初始化（@PostConstruct/afterPropertiesSet/initMethod）→ BeanPostProcessor.after（AOP代理）
- **销毁期**：@PreDestroy / DisposableBean.destroy()

**延伸阅读方向**：
- Spring AOP 原理：AbstractAutoProxyCreator 作为 BeanPostProcessor 生成代理的完整流程
- Spring 循环依赖：三级缓存如何解决 A→B→A 的构造循环引用
- @Lazy 注解：延迟 Bean 初始化，打破循环依赖的另一种方式
- Spring 事件机制：ApplicationEvent + @EventListener 实现 Bean 间的解耦通信
