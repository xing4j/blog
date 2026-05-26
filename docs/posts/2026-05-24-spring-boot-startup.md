# Spring Boot 启动流程：SpringApplication.run 全链路解析

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> - 👉 **SB-07 Spring Boot 启动流程：SpringApplication.run 全链路（本文）**
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

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 25 分钟｜**分类**：Spring 生态

---

## 导读

`SpringApplication.run(MyApp.class, args)` 一行代码背后，Spring Boot 启动了什么？本文从源码角度拆解启动流程：SpringApplication 初始化阶段做什么、`run()` 方法的 8 个阶段各司何职、`SpringApplicationRunListener` 在哪些时机触发、`ApplicationContext` 的 `refresh()` 与 Bean 初始化如何衔接。理解这条链路，是掌握自动装配、条件装配和 Starter 的前提。

---

## 一、整体流程概览

```
SpringApplication.run(MyApp.class, args)
    |
    |-- [阶段 1] new SpringApplication()      构造：推断应用类型、加载监听器
    |
    |-- [阶段 2] getRunListeners()            获取 SpringApplicationRunListener
    |-- [阶段 3] listeners.starting()         发布 ApplicationStartingEvent
    |
    |-- [阶段 4] prepareEnvironment()
    |              创建 Environment（StandardServletEnvironment）
    |              加载配置文件（application.yml / properties）
    |              发布 ApplicationEnvironmentPreparedEvent
    |
    |-- [阶段 5] createApplicationContext()
    |              根据应用类型创建 ApplicationContext
    |              Web 类型 -> AnnotationConfigServletWebServerApplicationContext
    |
    |-- [阶段 6] prepareContext()
    |              注册 primarySources（主启动类）
    |              应用 ApplicationContextInitializer
    |              发布 ApplicationContextInitializedEvent
    |              加载 BeanDefinition（主类 + 组件扫描）
    |              发布 ApplicationPreparedEvent
    |
    |-- [阶段 7] refreshContext()
    |              AbstractApplicationContext.refresh()    <- Spring 容器核心初始化
    |              启动内嵌 Tomcat（Web 应用）
    |              实例化所有 singleton Bean
    |              发布 ContextRefreshedEvent
    |
    |-- [阶段 8] afterRefresh()               ApplicationRunner / CommandLineRunner
    |              发布 ApplicationStartedEvent
    |              发布 ApplicationReadyEvent（服务就绪）
    |
    v
  应用启动完毕
```

---

## 二、阶段 1：SpringApplication 构造

```java
// Spring Boot 3.2 + JDK 17
public SpringApplication(ResourceLoader resourceLoader, Class<?>... primarySources) {
    this.resourceLoader = resourceLoader;
    this.primarySources = new LinkedHashSet<>(Arrays.asList(primarySources));

    // 1. 推断 Web 应用类型
    this.webApplicationType = WebApplicationType.deduceFromClasspath();
    // SERVLET: 存在 DispatcherServlet 类 -> Spring MVC
    // REACTIVE: 存在 DispatcherHandler 类 -> WebFlux
    // NONE: 普通非 Web 应用

    // 2. 从 META-INF/spring.factories 加载 BootstrapRegistryInitializer
    this.bootstrapRegistryInitializers = getBootstrapRegistryInitializersFromSpringFactories();

    // 3. 加载 ApplicationContextInitializer（7 个内置实现）
    setInitializers(getSpringFactoriesInstances(ApplicationContextInitializer.class));

    // 4. 加载 ApplicationListener（8 个内置实现）
    setListeners(getSpringFactoriesInstances(ApplicationListener.class));

    // 5. 推断主启动类（通过异常栈找到 main 方法所在类）
    this.mainApplicationClass = deduceMainApplicationClass();
}
```

**关键**：`ApplicationContextInitializer` 和 `ApplicationListener` 通过 `SpringFactoriesLoader` 从 `META-INF/spring.factories` 加载，这是 Spring SPI 机制，后续自动装配的基础。

---

## 三、阶段 4：Environment 准备

`Environment` 封装了所有配置来源（命令行参数、系统环境变量、application.yml 等），其创建和初始化是在 `prepareEnvironment()` 中完成的：

```java
private ConfigurableEnvironment prepareEnvironment(
        SpringApplicationRunListeners listeners,
        DefaultBootstrapContext bootstrapContext,
        ApplicationArguments applicationArguments) {

    // 1. 创建 Environment（Web 应用 -> StandardServletEnvironment）
    ConfigurableEnvironment environment = getOrCreateEnvironment();

    // 2. 配置 PropertySources（命令行参数）和 Profiles
    configureEnvironment(environment, applicationArguments.getSourceArgs());

    // 3. 发布事件：触发 ConfigFileApplicationListener 加载 application.yml
    listeners.environmentPrepared(bootstrapContext, environment);
    // -> ConfigDataEnvironmentPostProcessor 加载配置文件
    // -> 配置文件按优先级合并到 PropertySources

    // 4. 将 spring.main.* 属性绑定到 SpringApplication
    bindToSpringApplication(environment);

    return environment;
}
```

---

## 四、阶段 7：refresh() 是核心

`refreshContext()` 最终调用 `AbstractApplicationContext.refresh()`，这是 Spring 容器生命周期中最重要的方法，包含 13 个步骤：

```java
public void refresh() {
    // 1. prepareRefresh()         设置启动时间、active 标志、初始化早期事件
    // 2. obtainFreshBeanFactory()  获取（或创建）BeanFactory
    // 3. prepareBeanFactory()      配置 BeanFactory（ClassLoader、BPP、特殊 Bean 等）
    // 4. postProcessBeanFactory()  子类扩展点：允许修改 BeanFactory
    // 5. invokeBeanFactoryPostProcessors()  执行所有 BFPP
    //    -> ConfigurationClassPostProcessor 在此解析 @Configuration / @ComponentScan
    //    -> 自动装配的 AutoConfigurationImportSelector 在此执行
    // 6. registerBeanPostProcessors()  注册所有 BPP（不执行，只注册）
    // 7. initMessageSource()       国际化支持
    // 8. initApplicationEventMulticaster()  初始化事件广播器
    // 9. onRefresh()               子类扩展：Web 应用在此启动内嵌 Tomcat
    // 10. registerListeners()      注册 ApplicationListener
    // 11. finishBeanFactoryInitialization()  实例化所有 singleton Bean（最耗时）
    // 12. finishRefresh()          发布 ContextRefreshedEvent，启动 Lifecycle Bean
    // 13. resetCommonCaches()      清空反射缓存，减少内存占用
}
```

**最重要的步骤**：
- **步骤 5**：`invokeBeanFactoryPostProcessors()` 中，`ConfigurationClassPostProcessor` 解析 `@SpringBootApplication` 上的 `@ComponentScan` 和 `@EnableAutoConfiguration`，将所有 BeanDefinition 注册到容器。
- **步骤 9**：`onRefresh()` 在 `ServletWebServerApplicationContext` 中被重写，调用 `createWebServer()` 启动内嵌 Tomcat。
- **步骤 11**：`finishBeanFactoryInitialization()` 遍历所有非懒加载 singleton BeanDefinition，逐一调用 `getBean()` 完成实例化和初始化，这是启动耗时的主要来源。

---

## 五、内嵌 Tomcat 的启动时机

```java
// AnnotationConfigServletWebServerApplicationContext.onRefresh()
// Spring Boot 3.2

@Override
protected void onRefresh() {
    super.onRefresh();
    try {
        createWebServer(); // 启动内嵌 Tomcat
    } catch (Throwable ex) {
        throw new ApplicationContextException("Unable to start web server", ex);
    }
}

private void createWebServer() {
    WebServer webServer = this.webServer;
    ServletContext servletContext = getServletContext();
    if (webServer == null && servletContext == null) {
        // 从容器获取 ServletWebServerFactory（TomcatServletWebServerFactory）
        ServletWebServerFactory factory = getWebServerFactory();
        // 创建 Tomcat 实例（此时 Tomcat 已启动，但 Spring 容器还在继续初始化）
        this.webServer = factory.getWebServer(getSelfInitializer());
        // 注册 webServerStartStop Lifecycle Bean，用于 Spring 关闭时停止 Tomcat
        getBeanFactory().registerSingleton("webServerStartStop",
            new WebServerStartStopLifecycle(this, this.webServer));
    }
}
```

---

## 六、启动事件时序

```
ApplicationStartingEvent        SpringApplication.run() 最开始，Banner 打印前
ApplicationEnvironmentPreparedEvent  Environment 就绪，配置文件已加载
ApplicationContextInitializedEvent   ApplicationContext 已创建，Initializer 已调用
ApplicationPreparedEvent         BeanDefinition 已注册，refresh 尚未开始
ContextRefreshedEvent            refresh 完成，所有 Bean 已就绪
ApplicationStartedEvent          Runner 执行之前
ApplicationReadyEvent            Runner 执行完毕，服务就绪
ApplicationFailedEvent           启动过程任意阶段抛异常
```

---

## 七、踩坑总结

❌ **在 `ApplicationRunner` 中执行耗时初始化操作，导致服务就绪时间延长**

✅ `ApplicationRunner` 和 `CommandLineRunner` 在 `ApplicationReadyEvent` 之前执行——也就是说，它们跑完之前服务不算就绪。如果有耗时操作（如缓存预热），考虑改为监听 `ApplicationReadyEvent` 并用异步线程执行，或使用 `@Async` + `SmartLifecycle`。

❌ **自定义 `ApplicationContextInitializer` 注册到 `spring.factories`，但在 Spring Boot 3.x 中不生效**

✅ Spring Boot 3.x 默认使用 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` 格式（AOT 友好），`spring.factories` 中的部分 Key 已废弃。`ApplicationContextInitializer` 仍然从 `spring.factories` 加载，但需确认 key 为 `org.springframework.context.ApplicationContextInitializer`，且文件放置正确。

---

## 八、文章小结

- SpringApplication 构造阶段完成 Web 类型推断、SPI 加载 Initializer 和 Listener，为后续扩展提供钩子
- `prepareEnvironment()` 加载配置文件并发布事件，配置来源的优先级在此建立
- `refresh()` 的 13 个步骤是整个 Spring 容器生命周期的核心，步骤 5 触发自动装配，步骤 9 启动 Tomcat，步骤 11 实例化所有 Bean
- 内嵌 Tomcat 在 `refresh()` 的 `onRefresh()` 阶段启动，早于 Bean 全部就绪
- 启动事件按时序流转，可在不同阶段通过监听器扩展行为

---

## 九、思考题

1. `SpringApplication.run()` 的第 5 步 `invokeBeanFactoryPostProcessors()` 中，`ConfigurationClassPostProcessor` 是从哪里来的？它是什么时候被注册到容器的？

2. 为什么 Spring Boot 能"零配置"启动一个 Web 应用？Tomcat 是什么时候、被谁放到 Spring 容器中的？

---

## 参考资料

> 1. [Spring Boot 3.x 官方文档 - Application Startup](https://docs.spring.io/spring-boot/docs/current/reference/html/features.html#features.spring-application)
> 2. Spring Boot 源码：`SpringApplication`、`AbstractApplicationContext.refresh()`（版本：3.2）
> 3. [SB-08 Spring Boot 自动装配原理深度解析](posts/2024-10-27-spring-boot-autoconfigure.md)
> 4. [SB-10 Spring Boot 条件装配：@Conditional 体系](posts/2026-05-24-spring-boot-conditional.md)
