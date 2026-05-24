# Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册原理

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - 👉 **SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册原理（本文）**
> - [SB-02 Spring Bean 生命周期深度解析](2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](2024-08-22-spring-aop-proxy.md)
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](2026-05-24-spring-boot-startup.md)
> - [SB-08 Spring Boot 自动装配原理深度解析](2024-10-27-spring-boot-autoconfigure.md)
> - [SB-09 Spring Boot 配置体系详解](2026-05-16-spring-boot-config-priority.md)
> - [SB-10 Spring Boot 条件装配：@Conditional 体系](2026-05-24-spring-boot-conditional.md)
> - [SB-11 Spring 循环依赖：三级缓存的设计原理](2026-05-24-spring-circular-dependency.md)
> - [SB-12 Filter、Interceptor、AOP 三者对比与选型](2026-05-24-spring-filter-interceptor-aop.md)
> - [SB-13 Spring 事件驱动：ApplicationEvent 与监听器](2026-05-24-spring-events.md)
> - [SB-14 Spring @Async 异步编程：原理与线程池配置](2026-05-24-spring-async.md)
> - [SB-15 Spring 扩展点：BPP、BFPP 与 ImportSelector](2026-05-24-spring-extension-points.md)
> - [SB-16 Spring Boot 全局异常处理与参数校验](2026-05-24-spring-exception-handler.md)
> - [SB-17 Spring Boot 多数据源：动态路由与跨库事务](2026-05-24-spring-boot-multi-datasource.md)
> - [SB-18 Spring Boot Actuator：健康检查与自定义端点](2026-05-24-spring-boot-actuator.md)
> - [SB-19 Spring Boot 自定义 Starter：从设计到发布](2026-05-24-spring-boot-custom-starter.md)
> - [SB-20 Spring Security 认证授权完整流程](2024-12-23-spring-security-auth.md)
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](2026-05-24-spring-boot-testing.md)

**深度等级**：⭐ 入门｜**阅读时长**：约 20 分钟｜**分类**：Spring 生态

---

## 导读

所有 Spring 面试的底层都绕不开 IoC 容器。本文从 "Spring 怎么管理 Bean" 出发，拆解 BeanFactory 体系、ApplicationContext 继承链、BeanDefinition 的结构与注册流程，帮你建立对 Spring 容器机制的完整认知，为后续 Bean 生命周期、AOP、自动装配打下基础。

---

## 一、IoC 解决了什么问题

传统对象创建方式下，A 依赖 B，A 就要 `new B()`——对象和依赖强耦合。一旦 B 的实现变化，所有创建 B 的地方都要改。

```java
// 传统方式：强耦合，硬编码依赖
public class OrderService {
    private UserService userService = new UserServiceImpl(); // A 直接 new B
    private OrderDao orderDao = new OrderDaoImpl("jdbc:mysql://...", ...); // 配置硬编码
}
```

**IoC（Inversion of Control，控制反转）**：把"谁负责创建对象、谁来组装依赖"的控制权，从业务代码转移给容器。

```java
// IoC 方式：依赖由容器注入，业务代码只声明需要什么
@Service
public class OrderService {
    @Autowired
    private UserService userService;  // 容器负责注入实现
    @Autowired
    private OrderDao orderDao;
}
```

**DI（Dependency Injection，依赖注入）**是 IoC 的具体实现方式——容器在创建对象时主动将依赖"注入"进去。

---

## 二、BeanFactory 体系：容器的骨架

### 2.1 核心接口层级

```
BeanFactory                          <- 最顶层接口，定义 getBean()
  |-- HierarchicalBeanFactory        <- 支持父子容器
  |-- ListableBeanFactory            <- 支持列举所有 BeanDefinition
  |     |-- ApplicationContext       <- 扩展接口（消息、事件、环境）
  |           |-- ConfigurableApplicationContext  <- 可配置（refresh/close）
  |                 |-- AbstractApplicationContext  <- 核心抽象实现
  |                       |-- AnnotationConfigApplicationContext   <- 注解配置
  |                       |-- ClassPathXmlApplicationContext       <- XML 配置
  |                       |-- AnnotationConfigServletWebServerApplicationContext  <- Spring Boot Web
  |-- ConfigurableBeanFactory        <- 可配置工厂（作用域、后置处理器注册）
        |-- AbstractBeanFactory      <- 核心实现（getBean 主逻辑）
              |-- DefaultListableBeanFactory  <- 最完整实现，Spring 默认容器
```

**关键节点**：`DefaultListableBeanFactory` 是实际干活的核心类，同时实现了 `ListableBeanFactory`、`ConfigurableBeanFactory`、`BeanDefinitionRegistry` 等，是 Spring 容器的真正后端。

### 2.2 BeanFactory vs ApplicationContext

| 维度 | BeanFactory | ApplicationContext |
|------|------------|-------------------|
| 定位 | 低级容器，仅管理 Bean 创建 | 高级容器，BeanFactory 的超集 |
| 国际化 | ❌ | ✅ MessageSource |
| 事件发布 | ❌ | ✅ ApplicationEventPublisher |
| 环境抽象 | ❌ | ✅ Environment（profiles、properties）|
| Bean 初始化时机 | 懒加载（getBean 时才创建）| 默认预加载所有 singleton |
| 使用场景 | 框架内部底层使用 | 应用开发直接使用 |

> 日常开发中接触到的 Spring 容器均为 `ApplicationContext`，`BeanFactory` 主要在框架集成层出现。

---

## 三、BeanDefinition：Bean 的"配方"

### 3.1 BeanDefinition 是什么

Spring 在实际创建 Bean 对象之前，先将所有 Bean 的描述信息（类名、作用域、依赖、初始化方法等）存入 `BeanDefinition`。可以把它理解为 Bean 的**元数据模板**，容器根据这份模板来实例化和配置 Bean。

```java
// BeanDefinition 的核心属性（RootBeanDefinition 是常见实现）
public interface BeanDefinition {
    String getBeanClassName();          // Bean 的类名
    String getScope();                  // singleton / prototype
    boolean isLazyInit();               // 是否懒加载
    String[] getDependsOn();            // 依赖的 Bean 名称（depends-on）
    MutablePropertyValues getPropertyValues();  // 属性注入值
    ConstructorArgumentValues getConstructorArgumentValues(); // 构造器参数
    String getInitMethodName();         // init-method
    String getDestroyMethodName();      // destroy-method
    boolean isSingleton();
    boolean isPrototype();
    boolean isAbstract();
}
```

### 3.2 BeanDefinition 的类型体系

```
AbstractBeanDefinition
  |-- RootBeanDefinition       <- 最终合并后的 BD，容器内部实际使用
  |-- ChildBeanDefinition      <- 继承父 BD 的子定义（XML 时代遗留）
  |-- GenericBeanDefinition    <- 通用实现，注解扫描时的初始形态
  |-- ScannedGenericBeanDefinition   <- @Component 扫描生成
  |-- AnnotatedGenericBeanDefinition <- @Configuration 解析生成
  |-- ConfigurationClassBeanDefinition <- @Bean 方法生成
```

---

## 四、BeanDefinition 的注册流程

### 4.1 三种配置方式对应的解析路径

```
XML 配置文件
    XmlBeanDefinitionReader
        DefaultBeanDefinitionDocumentReader
            BeanDefinitionParserDelegate       -> BeanDefinition
                                                   |
注解类（@Configuration）                           v
    AnnotationConfigApplicationContext     BeanDefinitionRegistry
        ClassPathBeanDefinitionScanner    (.registerBeanDefinition())
            @Component / @Service 等           |
                                               v
@Bean 方法                             DefaultListableBeanFactory
    ConfigurationClassParser              (beanDefinitionMap)
        ConfigurationClassBeanDefinition
```

### 4.2 核心注册接口

```java
// BeanDefinitionRegistry：专门负责注册 BeanDefinition
public interface BeanDefinitionRegistry {
    void registerBeanDefinition(String beanName, BeanDefinition beanDefinition);
    void removeBeanDefinition(String beanName);
    BeanDefinition getBeanDefinition(String beanName);
    boolean containsBeanDefinition(String beanName);
    String[] getBeanDefinitionNames();
    int getBeanDefinitionCount();
}

// DefaultListableBeanFactory 的实现核心：一个 Map
// key = beanName, value = BeanDefinition
private final Map<String, BeanDefinition> beanDefinitionMap = new ConcurrentHashMap<>(256);
```

### 4.3 @ComponentScan 扫描过程

```java
// 简化版：ClassPathBeanDefinitionScanner 的扫描逻辑
// Spring Boot 3.2 + JDK 17
public class ClassPathBeanDefinitionScanner {

    public int scan(String... basePackages) {
        int beanCountAtScanStart = registry.getBeanDefinitionCount();
        doScan(basePackages);
        // 注册内置后置处理器（如 @Autowired 解析器）
        registerAnnotationConfigProcessors(this.registry);
        return registry.getBeanDefinitionCount() - beanCountAtScanStart;
    }

    protected Set<BeanDefinitionHolder> doScan(String... basePackages) {
        for (String basePackage : basePackages) {
            // 1. 扫描 classpath，找到所有候选类（标注了 @Component 等）
            Set<BeanDefinition> candidates = findCandidateComponents(basePackage);
            for (BeanDefinition candidate : candidates) {
                // 2. 解析 @Scope 作用域
                ScopeMetadata scopeMetadata = scopeMetadataResolver.resolveScopeMetadata(candidate);
                candidate.setScope(scopeMetadata.getScopeName());
                // 3. 生成 beanName（默认类名首字母小写）
                String beanName = beanNameGenerator.generateBeanName(candidate, registry);
                // 4. 注册到容器
                registry.registerBeanDefinition(beanName, candidate);
            }
        }
    }
}
```

---

## 五、getBean 核心流程

理解了 BeanDefinition 注册，再看 `getBean` 就能把整个容器运转链路串起来：

```
getBean("orderService")
    |
    v
AbstractBeanFactory.doGetBean()
    |-- 1. 检查 singletonObjects 缓存（已创建则直接返回）
    |-- 2. 检查父容器（如有父子容器关系）
    |-- 3. 获取 BeanDefinition（含依赖信息）
    |-- 4. 处理 depends-on 依赖
    |-- 5. 根据 scope 走不同创建路径：
    |       Singleton -> getSingleton() + createBean()
    |       Prototype -> createBean() 每次新建
    |       其他 Scope -> 委托 Scope 实现
    |-- 6. createBean()
            |-- InstantiationAwareBeanPostProcessor.before  (可短路)
            |-- doCreateBean()
                    |-- 实例化（Constructor / 工厂方法）
                    |-- 属性填充（@Autowired 注入）
                    |-- 初始化（生命周期回调）
                    |-- BeanPostProcessor.after（AOP 代理在此生成）
```

---

## 六、踩坑总结

❌ **在 @Configuration 类中用 `new` 直接创建另一个 @Bean，导致依赖不走 Spring 代理**

```java
// 错误：直接 new，不经过容器，AOP/事务不生效
@Configuration
public class AppConfig {
    @Bean
    public UserService userService() {
        return new UserServiceImpl(new UserDao()); // new UserDao() 不是 Spring Bean
    }
}
```

```java
// 正确：方法调用经过 CGLIB 代理拦截，返回容器中已有的 Bean 实例
@Configuration
public class AppConfig {
    @Bean
    public UserDao userDao() {
        return new UserDao();
    }
    @Bean
    public UserService userService() {
        return new UserServiceImpl(userDao()); // 实际调用容器的 userDao，不 new
    }
}
```

❌ **`@Component` 和 `@Configuration` 对内部 `@Bean` 方法的行为理解错误**

✅ `@Configuration` 是 Full 模式（CGLIB 代理），`@Bean` 方法调用会被拦截返回单例。`@Component` 是 Lite 模式（无代理），`@Bean` 方法调用是普通 Java 方法调用，每次 `new` 出新对象。

---

## 七、文章小结

- IoC 将对象创建和依赖管理的控制权交给容器，解耦业务代码与具体实现
- `DefaultListableBeanFactory` 是 Spring 容器的核心实现，同时承担 BeanFactory 和 BeanDefinitionRegistry 职责
- `BeanDefinition` 是 Bean 的元数据模板，容器根据它创建和配置对象；注册到 `beanDefinitionMap` 后等待实例化
- XML、`@Component` 扫描、`@Bean` 方法三条路径最终汇聚到 `BeanDefinitionRegistry.registerBeanDefinition()`
- `getBean` 的核心路径：检查缓存 → 读取 BeanDefinition → 处理依赖 → createBean → BeanPostProcessor

---

## 八、思考题

1. 父子容器（如 Spring MVC 中 Root WebApplicationContext 和 Servlet WebApplicationContext）的关系是什么？子容器能访问父容器的 Bean，反过来呢？为什么这么设计？

2. 当你调用 `applicationContext.getBean("xxx")` 时，如果该 Bean 上有 `@Transactional`，返回的对象是原始对象还是代理对象？为什么？

---

## 参考资料

> 1. [Spring Framework 6.x 官方文档 - The IoC Container](https://docs.spring.io/spring-framework/reference/core/beans.html)
> 2. Spring Framework 源码：`DefaultListableBeanFactory`、`AbstractBeanFactory`（版本：6.1）
> 3. [SB-02 Spring Bean 生命周期深度解析](2024-07-27-spring-bean-lifecycle.md)
> 4. [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](2026-05-24-spring-boot-startup.md)
