# Spring Boot 自定义 Starter：从设计到发布

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](2026-05-24-spring-ioc-container.md)
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
> - 👉 **SB-19 Spring Boot 自定义 Starter：从设计到发布（本文）**
> - [SB-20 Spring Security 认证授权完整流程](2024-12-23-spring-security-auth.md)
> - [SB-21 Spring Cache 注解与 Redis 缓存集成](2025-04-04-spring-cache.md)
> - [SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc](2026-05-24-spring-boot-testing.md)

**深度等级**：⭐⭐⭐ 深度｜**阅读时长**：约 28 分钟｜**分类**：Spring 生态

---

## 导读

Starter 是 Spring Boot 生态的核心复用机制——引入一个依赖，相关 Bean 自动注册、配置属性自动绑定、缺失配置有合理默认值。本文从零构建一个完整的企业级 Starter（统一审计日志 Starter），涵盖模块拆分、AutoConfiguration 设计、条件装配、配置元数据、测试与发布全流程。

---

## 一、Starter 的结构设计

官方规范将 Starter 拆成两个 Maven 模块：

```
audit-log-spring-boot-starter       ← 纯 POM，仅声明依赖
audit-log-spring-boot-autoconfigure ← 实现：AutoConfiguration + 核心代码
```

**命名约定**：
- 官方：`spring-boot-starter-xxx`
- 第三方：`xxx-spring-boot-starter`（避免与官方命名冲突）

**为什么要拆分？** 让用户可以只引 `autoconfigure` 模块写集成测试，而不引入所有 starter 传递依赖；也让其他 starter 可以 `optional` 依赖 autoconfigure。

---

## 二、完整示例：审计日志 Starter

业务需求：自动记录所有标注了 `@AuditLog` 注解的方法的调用人、调用时间、入参、出参，写到数据库审计表中。

### 2.1 项目结构

```
audit-log-spring-boot-starter/
  pom.xml
audit-log-spring-boot-autoconfigure/
  pom.xml
  src/main/java/com/example/audit/
    annotation/AuditLog.java
    aspect/AuditLogAspect.java
    config/AuditLogAutoConfiguration.java
    config/AuditLogProperties.java
    service/AuditLogService.java
    service/impl/DefaultAuditLogService.java
  src/main/resources/META-INF/
    spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports  ← SB 3.x
    spring-configuration-metadata.json  ← IDE 提示
```

### 2.2 配置属性类

```java
// Spring Boot 3.2 + JDK 17
// audit-log-spring-boot-autoconfigure
@ConfigurationProperties(prefix = "audit.log")
@Data
public class AuditLogProperties {
    /** 是否启用审计日志 */
    private boolean enabled = true;

    /** 异步写入，默认开启 */
    private boolean async = true;

    /** 审计日志存储方式：db / kafka / console */
    private String storage = "db";

    /** 日志表名（storage=db 时生效）*/
    private String tableName = "audit_log";

    /** 最大记录的入参长度，超出截断 */
    private int maxParamLength = 2048;
}
```

### 2.3 注解定义

```java
// 业务方法标注此注解，触发审计日志记录
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface AuditLog {
    /** 操作描述，支持 SpEL 表达式，如 "#request.orderId" */
    String value() default "";

    /** 操作模块 */
    String module() default "";
}
```

### 2.4 AOP 切面

```java
@Aspect
@Slf4j
@RequiredArgsConstructor
public class AuditLogAspect {

    private final AuditLogService auditLogService;
    private final AuditLogProperties properties;

    @Around("@annotation(auditLog)")
    public Object around(ProceedingJoinPoint pjp, AuditLog auditLog) throws Throwable {
        long start = System.currentTimeMillis();
        AuditLogEntry entry = new AuditLogEntry();
        entry.setModule(auditLog.module());
        entry.setOperation(resolveSpEL(auditLog.value(), pjp));
        entry.setParams(truncate(toJson(pjp.getArgs()), properties.getMaxParamLength()));
        entry.setOperator(SecurityContextHolder.getContext().getAuthentication().getName());
        entry.setTimestamp(LocalDateTime.now());

        Object result = null;
        try {
            result = pjp.proceed();
            entry.setSuccess(true);
            return result;
        } catch (Exception e) {
            entry.setSuccess(false);
            entry.setErrorMsg(e.getMessage());
            throw e;
        } finally {
            entry.setDuration(System.currentTimeMillis() - start);
            auditLogService.save(entry); // 同步或异步由 service 内部决定
        }
    }

    // 省略 resolveSpEL / truncate / toJson 工具方法
}
```

### 2.5 AutoConfiguration 类

```java
// 核心：AutoConfiguration 类，所有条件装配逻辑在此
@AutoConfiguration
@ConditionalOnProperty(prefix = "audit.log", name = "enabled", havingValue = "true", matchIfMissing = true)
@EnableConfigurationProperties(AuditLogProperties.class)
@ConditionalOnClass(ProceedingJoinPoint.class) // 需要 spring-aop 在 classpath
@Import(AuditLogAspect.class)
public class AuditLogAutoConfiguration {

    // 只有用户没有自定义 AuditLogService 时，才注册默认实现
    @Bean
    @ConditionalOnMissingBean(AuditLogService.class)
    public AuditLogService auditLogService(AuditLogProperties properties) {
        return switch (properties.getStorage()) {
            case "kafka"   -> new KafkaAuditLogService();
            case "console" -> new ConsoleAuditLogService();
            default        -> new DbAuditLogService(properties); // "db"
        };
    }

    @Bean
    @ConditionalOnMissingBean
    public AuditLogAspect auditLogAspect(AuditLogService service, AuditLogProperties props) {
        return new AuditLogAspect(service, props);
    }
}
```

### 2.6 注册 AutoConfiguration（Spring Boot 3.x）

```
# src/main/resources/META-INF/spring/
# org.springframework.boot.autoconfigure.AutoConfiguration.imports

com.example.audit.config.AuditLogAutoConfiguration
```

> **注意**：Spring Boot 2.x 用 `META-INF/spring.factories`，3.x 改用此文件，两者可共存以兼容。

### 2.7 starter 模块的 POM

```xml
<!-- audit-log-spring-boot-starter/pom.xml -->
<dependencies>
    <!-- 业务代码在 autoconfigure 里 -->
    <dependency>
        <groupId>com.example</groupId>
        <artifactId>audit-log-spring-boot-autoconfigure</artifactId>
        <version>${project.version}</version>
    </dependency>
    <!-- starter 只引必要的传递依赖 -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-aop</artifactId>
    </dependency>
</dependencies>
```

---

## 三、配置属性元数据（IDE 提示）

在 autoconfigure 模块中加入 `spring-boot-configuration-processor`，编译时自动生成 `spring-configuration-metadata.json`，让 IDE 在 `application.yml` 中提供自动补全和 Javadoc 提示：

```xml
<!-- autoconfigure/pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-configuration-processor</artifactId>
    <optional>true</optional> <!-- 不传递给用户 -->
</dependency>
```

---

## 四、允许用户覆盖（@ConditionalOnMissingBean 设计原则）

Starter 的所有 Bean 注册都应加 `@ConditionalOnMissingBean`，让用户可以用自己的实现替换默认行为：

```java
// 用户在自己的项目中：
@Bean
public AuditLogService myAuditLogService() {
    return new ElasticSearchAuditLogService(); // 覆盖 starter 的默认实现
}
```

**原则**：Starter 提供默认，不强制；`@ConditionalOnMissingBean` 保证用户的 Bean 优先。

---

## 五、自动装配测试

```java
// autoconfigure 模块的集成测试
@SpringBootTest
@TestPropertySource(properties = "audit.log.storage=console")
class AuditLogAutoConfigurationTest {

    @Autowired
    private ApplicationContext context;

    @Test
    void shouldRegisterDefaultBeans() {
        assertThat(context.containsBean("auditLogAspect")).isTrue();
        assertThat(context.getBean(AuditLogService.class))
            .isInstanceOf(ConsoleAuditLogService.class);
    }

    @Test
    void shouldAllowCustomService() {
        // 用 @Import 覆盖 Bean
        // 详见 SB-22 测试体系
    }
}
```

---

## 六、踩坑总结

❌ **AutoConfiguration 类上写了 `@Configuration`，引入 Starter 后出现 Bean 重复注册或循环依赖**

✅ Spring Boot 3.x 的 AutoConfiguration 类应使用 `@AutoConfiguration`（而不是 `@Configuration`），它内部已包含 `@Configuration`，且标记了 `proxyBeanMethods = false`（节省代理性能），同时有延迟加载的语义。避免将 AutoConfiguration 类手动添加到应用的 `@ComponentScan` 路径下（应只通过 `AutoConfiguration.imports` 文件注册）。

❌ **`@ConditionalOnMissingBean` 不生效：用户定义了自定义 Bean，但 Starter 的默认 Bean 仍然被注册，导致冲突**

✅ `@ConditionalOnMissingBean` 的判断时机是在该 AutoConfiguration 类的 `@Bean` 方法执行时。如果用户的 Bean 定义在普通 `@Configuration` 类中，但 AutoConfiguration 先执行（ordering 问题），就会误以为没有用户 Bean。解决方案：在 AutoConfiguration 上使用 `@AutoConfigureAfter(UserConfig.class)` 确保在用户配置之后执行，或改用 `@ConditionalOnMissingBean(type = "xxx.AuditLogService")` 按类型字符串判断（避免直接引用用户类导致的类加载问题）。

---

## 七、文章小结

- Starter 分两个模块：`xxx-autoconfigure`（实现）+ `xxx-starter`（纯 POM 依赖集合）
- AutoConfiguration 通过 `META-INF/spring/AutoConfiguration.imports` 注册（Spring Boot 3.x），不依赖组件扫描
- 所有 Bean 注册加 `@ConditionalOnMissingBean`，保证用户可覆盖，这是 Starter 的核心设计原则
- `@ConfigurationProperties` + `spring-boot-configuration-processor` 提供类型安全配置和 IDE 自动补全
- AutoConfiguration 类使用 `@AutoConfiguration`（非 `@Configuration`），并用 `@AutoConfigureAfter/@AutoConfigureBefore` 控制顺序

---

## 八、思考题

1. 同一个 AutoConfiguration 类中有多个 `@Bean` 方法，它们之间有依赖关系时，调用顺序如何保证？`proxyBeanMethods = false` 时直接调用 `@Bean` 方法会怎样？

2. 如果 Starter 需要根据用户引入了哪些第三方库（如 Jedis vs Lettuce）来决定使用不同的实现，应该用哪个条件注解？有什么注意事项？

---

## 参考资料

> 1. [Spring Boot 官方文档 - Creating Your Own Starter](https://docs.spring.io/spring-boot/docs/current/reference/html/features.html#features.developing-auto-configuration)
> 2. [SB-08 Spring Boot 自动装配原理深度解析](2024-10-27-spring-boot-autoconfigure.md)
> 3. [SB-10 Spring Boot 条件装配：@Conditional 体系](2026-05-24-spring-boot-conditional.md)
> 4. [SB-15 Spring 扩展点：BPP、BFPP 与 ImportSelector](2026-05-24-spring-extension-points.md)
