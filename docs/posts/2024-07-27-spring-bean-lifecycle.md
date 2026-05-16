# Spring Bean 生命周期完整流程图解

<div class="post-meta">📅 2024-07-27 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

Spring Bean 的生命周期是面试高频题，也是深入理解 IoC 容器的核心。本文以流程图 + 代码示例的方式完整呈现每个阶段。

---

## 一、完整生命周期 ASCII 流程图

```
┌─────────────────────────────────────────────────────────────┐
│                     Spring IoC 容器                          │
│                                                             │
│  1. 实例化 (Instantiation)                                   │
│     └─ Constructor / 反射 newInstance()                     │
│            │                                                │
│  2. 属性填充 (Populate Properties)                           │
│     └─ @Autowired / @Value / setter 注入                    │
│            │                                                │
│  3. Aware 接口回调                                           │
│     ├─ BeanNameAware.setBeanName()                          │
│     ├─ BeanFactoryAware.setBeanFactory()                    │
│     └─ ApplicationContextAware.setApplicationContext()      │
│            │                                                │
│  4. BeanPostProcessor 前置处理                               │
│     └─ postProcessBeforeInitialization()                    │
│            │                                                │
│  5. 初始化 (Initialization)                                  │
│     ├─ @PostConstruct 方法                                  │
│     ├─ InitializingBean.afterPropertiesSet()                │
│     └─ init-method (XML) / @Bean(initMethod)               │
│            │                                                │
│  6. BeanPostProcessor 后置处理                               │
│     └─ postProcessAfterInitialization()  ← AOP代理在此生成  │
│            │                                                │
│  7. Bean 投入使用                                            │
│            │                                                │
│  8. 销毁 (Destroy)                                          │
│     ├─ @PreDestroy 方法                                     │
│     ├─ DisposableBean.destroy()                             │
│     └─ destroy-method (XML) / @Bean(destroyMethod)         │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、各阶段代码示例

### 阶段1：实例化

Spring 默认通过无参构造函数反射创建 Bean 实例，也支持工厂方法。

```java
@Component
public class UserService {
    public UserService() {
        System.out.println("1. 实例化：UserService 构造方法执行");
    }
}
```

### 阶段2：属性填充

```java
@Component
public class UserService {
    @Autowired
    private UserRepository userRepository; // 属性填充阶段注入

    @Value("${app.name}")
    private String appName;
}
```

### 阶段3：Aware 接口回调

```java
@Component
public class UserService implements BeanNameAware,
        BeanFactoryAware, ApplicationContextAware {

    @Override
    public void setBeanName(String name) {
        System.out.println("3. BeanNameAware: beanName=" + name);
    }

    @Override
    public void setBeanFactory(BeanFactory beanFactory) {
        System.out.println("3. BeanFactoryAware: 获得BeanFactory引用");
    }

    @Override
    public void setApplicationContext(ApplicationContext ctx) {
        System.out.println("3. ApplicationContextAware: 获得ApplicationContext引用");
    }
}
```

### 阶段4 & 6：BeanPostProcessor

```java
@Component
public class MyBeanPostProcessor implements BeanPostProcessor {

    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) {
        System.out.println("4. Before Init: " + beanName);
        return bean; // 可替换为代理对象
    }

    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) {
        System.out.println("6. After Init: " + beanName);
        return bean; // AOP 代理对象在这里返回
    }
}
```

> **重要**：Spring AOP 就是通过 `postProcessAfterInitialization` 返回代理对象实现的。

---

## 三、初始化方式详解与对比

| 方式 | 执行顺序 | 适用场景 |
|------|---------|---------|
| `@PostConstruct` | 最先 | 推荐，代码内聚，JSR-250标准 |
| `InitializingBean.afterPropertiesSet()` | 第二 | 框架内部使用较多，侵入性强 |
| `@Bean(initMethod="xxx")` | 最后 | 第三方类无法改源码时 |

```java
@Component
public class DataSourceConfig implements InitializingBean {

    private DataSource dataSource;

    // 执行顺序第一：JSR-250 标准，推荐
    @PostConstruct
    public void init1() {
        System.out.println("5-1. @PostConstruct 初始化连接池");
    }

    // 执行顺序第二：Spring 框架接口
    @Override
    public void afterPropertiesSet() {
        System.out.println("5-2. InitializingBean.afterPropertiesSet()");
    }
}

// 如果是第三方类，使用 initMethod
@Bean(initMethod = "start", destroyMethod = "stop")
public DruidDataSource druidDataSource() {
    return new DruidDataSource();
}
```

---

## 四、销毁方式详解与对比

| 方式 | 执行顺序 | 说明 |
|------|---------|------|
| `@PreDestroy` | 最先 | 推荐，与 @PostConstruct 对称 |
| `DisposableBean.destroy()` | 第二 | Spring 接口，侵入性强 |
| `@Bean(destroyMethod="xxx")` | 最后 | 适合第三方 Bean |

```java
@Component
public class CacheManager implements DisposableBean {

    // 执行顺序第一
    @PreDestroy
    public void cleanup1() {
        System.out.println("8-1. @PreDestroy 清理缓存");
    }

    // 执行顺序第二
    @Override
    public void destroy() {
        System.out.println("8-2. DisposableBean.destroy()");
    }
}
```

> **注意**：只有单例（Singleton）Bean 才会触发销毁回调；原型（Prototype）Bean 不会。

---

## 五、循环依赖与三级缓存

Bean 生命周期中最复杂的问题是循环依赖，Spring 使用三级缓存解决：

```
singletonObjects（一级缓存）：完全初始化好的 Bean
earlySingletonObjects（二级缓存）：提前暴露的半成品 Bean
singletonFactories（三级缓存）：ObjectFactory，用于生成早期引用
```

```
A 依赖 B，B 依赖 A：
1. 创建 A → 实例化后放入三级缓存
2. 填充 A 的属性时发现需要 B
3. 创建 B → 实例化后放入三级缓存
4. 填充 B 的属性时发现需要 A
5. 从三级缓存拿到 A 的 ObjectFactory，获得 A 的早期引用（可能是代理）
6. B 完成初始化 → 放入一级缓存
7. A 拿到 B 的引用 → 完成初始化 → 放入一级缓存
```

---

## 六、完整执行顺序验证

运行以下代码可观察完整顺序：

```java
@Component
public class LifecycleBean implements BeanNameAware, InitializingBean, DisposableBean {

    public LifecycleBean()          { System.out.println("1. 构造方法"); }

    @Autowired
    public void setXxx(Xxx xxx)     { System.out.println("2. 属性填充"); }

    @Override
    public void setBeanName(String n){ System.out.println("3. BeanNameAware"); }

    @PostConstruct
    public void postConstruct()      { System.out.println("5-1. @PostConstruct"); }

    @Override
    public void afterPropertiesSet() { System.out.println("5-2. afterPropertiesSet"); }

    @PreDestroy
    public void preDestroy()         { System.out.println("8-1. @PreDestroy"); }

    @Override
    public void destroy()            { System.out.println("8-2. destroy"); }
}
```

输出顺序：
```
1. 构造方法
2. 属性填充
3. BeanNameAware
(BeanPostProcessor Before)
5-1. @PostConstruct
5-2. afterPropertiesSet
(BeanPostProcessor After)
--- 应用运行中 ---
8-1. @PreDestroy
8-2. destroy
```

---

## 七、总结

- **推荐**使用 `@PostConstruct` / `@PreDestroy`，语义清晰，无侵入性
- **BeanPostProcessor** 是扩展点核心，AOP、事务、自动注入都依赖它
- **Aware 接口**用于获取 Spring 容器相关资源，避免过度使用
- 理解生命周期有助于排查 Bean 初始化顺序问题和循环依赖问题
