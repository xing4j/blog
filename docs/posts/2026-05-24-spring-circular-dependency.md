# Spring 循环依赖：三级缓存的设计原理与边界

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](posts/2026-05-24-spring-boot-startup.md)
> - [SB-08 Spring Boot 自动装配原理深度解析](posts/2024-10-27-spring-boot-autoconfigure.md)
> - [SB-09 Spring Boot 配置体系详解](posts/2026-05-16-spring-boot-config-priority.md)
> - [SB-10 Spring Boot 条件装配：@Conditional 体系](posts/2026-05-24-spring-boot-conditional.md)
> - 👉 **SB-11 Spring 循环依赖：三级缓存的设计原理与边界（本文）**
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

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 20 分钟｜**分类**：Spring 生态

---

## 导读

A 依赖 B，B 依赖 A，Spring 却能正常启动——这是怎么做到的？三级缓存是高频面试题，但很多人只能背出"三个 Map 的名字"，说不清为什么需要三级而不是两级，也不知道构造器注入为什么无法解决。本文从问题出发，逐步推导三级缓存的设计必要性，并梳理循环依赖的所有边界情况。

---

## 一、什么是循环依赖

```java
@Service
public class ServiceA {
    @Autowired
    private ServiceB serviceB; // A 依赖 B
}

@Service
public class ServiceB {
    @Autowired
    private ServiceA serviceA; // B 依赖 A
}
```

如果 Spring 按照"先完整创建 A，再完整创建 B"的顺序处理，会陷入死循环：
- 创建 A → 发现需要 B → 创建 B → 发现需要 A → 创建 A → ...

Spring 通过**三级缓存 + 提前暴露（Early Reference）**打破这个死循环。

---

## 二、三级缓存的数据结构

`DefaultSingletonBeanRegistry` 中定义了三个 Map：

```java
// 一级缓存：完整的 singleton Bean（实例化 + 属性填充 + 初始化全部完成）
private final Map<String, Object> singletonObjects = new ConcurrentHashMap<>(256);

// 二级缓存：提前暴露的半成品 Bean（已实例化，但未完成属性填充和初始化）
// 存放的是已经被"早期引用"访问过的对象
private final Map<String, Object> earlySingletonObjects = new ConcurrentHashMap<>(16);

// 三级缓存：Bean 的 ObjectFactory（工厂函数，调用时才生成早期引用）
// 存放的是 "能生产早期引用" 的工厂，可在生产时执行 AOP 代理逻辑
private final Map<String, ObjectFactory<?>> singletonFactories = new HashMap<>(16);
```

---

## 三、循环依赖解决过程（逐步推导）

### 3.1 A、B 属性注入循环依赖的完整流程

```
Step 1：getBean("serviceA")
    -> 三级缓存均无 -> doCreateBean("serviceA")
    -> 实例化 ServiceA（new ServiceA()，只分配内存，属性为 null）
    -> 将 ServiceA 的 ObjectFactory 放入三级缓存（singletonFactories）

Step 2：填充 ServiceA 的属性，发现需要 @Autowired ServiceB
    -> getBean("serviceB")
    -> 三级缓存均无 -> doCreateBean("serviceB")
    -> 实例化 ServiceB
    -> 将 ServiceB 的 ObjectFactory 放入三级缓存

Step 3：填充 ServiceB 的属性，发现需要 @Autowired ServiceA
    -> getBean("serviceA")
    -> 一级缓存无，二级缓存无，三级缓存有 ServiceA 的 ObjectFactory!
    -> 调用 ObjectFactory.getObject()，获得 ServiceA 的早期引用（可能是 AOP 代理）
    -> 将早期引用放入二级缓存（earlySingletonObjects），移除三级缓存
    -> 返回 ServiceA 的早期引用

Step 4：ServiceB 完成属性填充 + 初始化 -> 放入一级缓存，移除二三级缓存

Step 5：回到 ServiceA 的属性填充，ServiceB 已就绪，ServiceA 完成初始化
    -> ServiceA 放入一级缓存，移除二三级缓存
```

---

## 四、为什么必须是三级缓存？

### 4.1 如果只有一级缓存

只用 `singletonObjects` 存放已完成的 Bean。创建 A 时 A 还没完成，无法放入，B 获取不到 A，死循环。

### 4.2 如果只有两级缓存（一级 + 二级）

把半成品的 A 直接放入二级缓存，B 获取到 A，问题解决了——如果 A 不需要 AOP 代理的话。

**关键问题**：如果 A 上有 `@Transactional` 或 `@Aspect`，Spring 会在初始化完成后生成 A 的代理对象。但 B 拿到的是 A 的原始对象。如果此时把原始对象放入二级缓存，B 持有的是原始 A，最终 A 的代理也无法正确注入到 B 中。

### 4.3 三级缓存的作用

**三级缓存存放的是 `ObjectFactory`（工厂函数），调用时才生成 A 的早期引用**。这个工厂函数包含了 AOP 代理逻辑：

```java
// doCreateBean 中，将 ObjectFactory 放入三级缓存
// Spring Boot 3.2 + Spring Framework 6.1

addSingletonFactory(beanName, () -> getEarlyBeanReference(beanName, mbd, bean));

// getEarlyBeanReference 会调用 SmartInstantiationAwareBeanPostProcessor
// AbstractAutoProxyCreator 实现了该接口，能在此处提前生成 AOP 代理
protected Object getEarlyBeanReference(String beanName, RootBeanDefinition mbd, Object bean) {
    Object exposedObject = bean;
    if (!mbd.isSynthetic() && hasInstantiationAwareBeanPostProcessors()) {
        for (SmartInstantiationAwareBeanPostProcessor bp : getBeanPostProcessorCache().smartInstantiationAware) {
            exposedObject = bp.getEarlyBeanReference(exposedObject, beanName);
        }
    }
    return exposedObject;
}
```

**结论**：
- 两级缓存可以解决无 AOP 的循环依赖
- 三级缓存通过 `ObjectFactory` 延迟决策"给 B 提供 A 的原始对象还是代理对象"，保证 B 始终拿到与最终放入一级缓存一致的 A 的引用

---

## 五、循环依赖的边界：哪些情况不能解决

| 场景 | 能否解决 | 原因 |
|------|---------|------|
| Singleton + 属性注入（@Autowired / @Resource）| ✅ 能解决 | 三级缓存机制 |
| Singleton + setter 注入 | ✅ 能解决 | 同上 |
| Singleton + 构造器注入 | ❌ 不能解决 | 实例化时就需要依赖，三级缓存尚未加入 |
| Prototype + 属性注入 | ❌ 不能解决 | Prototype 不使用单例缓存机制 |
| Singleton + Prototype 混合 | ⚠️ 部分可解决 | Singleton 依赖 Prototype 可以；反向不行 |
| `@Async` + 循环依赖 | ⚠️ 可能报错 | `@Async` 代理在后期生成，可能导致二级缓存中的对象与最终代理不一致 |

**构造器注入无法解决的原因**：

```java
// 构造器注入：实例化时就要求依赖已存在
@Service
public class ServiceA {
    private final ServiceB serviceB;
    public ServiceA(ServiceB serviceB) { // 构造时就需要 B
        this.serviceB = serviceB;
    }
}
// 实例化 A 需要 B -> 实例化 B 需要 A -> A 还没放入任何缓存 -> 死锁
```

---

## 六、Spring Boot 3.x 的变化：默认禁止循环依赖

Spring Boot 2.6+ 默认**禁止循环依赖**（`spring.main.allow-circular-references=false`），启动时检测到循环依赖直接报错：

```
The dependencies of some of the beans in the application context form a cycle:
serviceA -> serviceB -> serviceA
```

**官方建议**：循环依赖通常是设计问题（高耦合），应通过重构消除，而非开启 `allow-circular-references=true`。

常见的重构方式：
- 提取共同依赖的部分到第三个 Bean
- 使用事件机制解耦（见 [SB-13](posts/2026-05-24-spring-events.md)）
- 使用 `@Lazy` 延迟注入打破强依赖链

---

## 七、踩坑总结

❌ **项目升级 Spring Boot 2.5 → 2.6 后，启动报"Circular dependency"错误，急忙加了 `allow-circular-references=true` 了事**

✅ 这是强行掩盖问题。正确做法：用日志中的 Bean 依赖链图分析循环原因，拆分职责或用事件解耦。只有确实因框架原因（如 Spring Security 的某些内部依赖）无法避免时，才考虑配置允许。

❌ **给有 `@Async` 的 Bean 使用属性注入导致循环依赖，启动时报 `BeanCurrentlyInCreationException`**

✅ `@Async` 在所有 BPP 处理完毕后才生成代理，此时二级缓存中的早期引用是原始对象，而最终放入一级缓存的是代理对象，Spring 检测到不一致会抛异常。解决方案：对该 Bean 使用 `@Lazy` 注入，或将 `@Async` 方法抽取到独立的 Bean 中。

---

## 八、文章小结

- 循环依赖本质是对象创建时的相互等待；Spring 通过"提前暴露未完成的对象引用"打破等待
- 三级缓存中：一级存完整 Bean，二级存已被访问的早期引用，三级存 `ObjectFactory`（延迟生成早期引用，支持 AOP）
- **为什么三级而不是两级**：三级缓存的 `ObjectFactory` 能在生成早期引用时执行 AOP 代理逻辑，保证 Bean 引用的一致性
- 构造器注入、Prototype 作用域、`@Async` 与循环依赖的组合均无法被三级缓存解决
- Spring Boot 2.6+ 默认禁止循环依赖，应通过重构消除而非配置绕过

---

## 九、思考题

1. 如果 A 和 B 都通过 `@Async` 标注方法，且互相依赖，Spring 会怎么处理？为什么？

2. 三级缓存的 `ObjectFactory` 只在第一次被访问时调用一次并将结果存入二级缓存。如果 C 也依赖 A，C 获取 A 的早期引用时，是调用 `ObjectFactory` 还是直接从二级缓存取？

---

## 参考资料

> 1. Spring Framework 源码：`DefaultSingletonBeanRegistry`、`AbstractAutowireCapableBeanFactory.doCreateBean()`（版本：6.1）
> 2. [Spring Boot 2.6 Release Notes - Circular References](https://github.com/spring-projects/spring-boot/wiki/Spring-Boot-2.6-Release-Notes#circular-references-between-beans-prohibited-by-default)
> 3. [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> 4. [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
