# Spring Boot 自动装配：零配置背后的魔法

<div class="post-meta">📅 2024-10-27 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

加一个 spring-boot-starter-data-redis 依赖，不写任何配置类，Redis 连接池就自动初始化好了。Spring Boot 的自动装配让"约定大于配置"成为现实。理解这套机制，才能在出现问题时知道如何调试，以及如何编写自己的 Starter。

---

## 一、背景：Spring Boot 之前的痛点

Spring 时代（Spring 4.x 之前），整合 Redis 需要：
1. 在 XML 或 Java Config 中手动定义 JedisConnectionFactory
2. 手动定义 RedisTemplate 并配置序列化器
3. 手动定义连接池配置

Spring Boot 的目标：让 80% 的场景下，引入依赖即可用。

---

## 二、自动装配的核心流程

`
@SpringBootApplication
    ↓ 包含
@EnableAutoConfiguration
    ↓ 导入
AutoConfigurationImportSelector
    ↓ 读取
spring.factories / AutoConfiguration.imports（Spring Boot 3.x）
    ↓ 过滤（@Conditional）
符合条件的 AutoConfiguration 类
    ↓ 执行
注册所需的 Bean 到容器
`

### 2.1 入口：@EnableAutoConfiguration

`java
@SpringBootApplication
// 等价于：
@SpringBootConfiguration
@EnableAutoConfiguration   // ← 自动装配的开关
@ComponentScan
`

### 2.2 SPI 配置文件

Spring Boot 通过类 SPI 机制发现所有自动配置类：

`
Spring Boot 2.x：
META-INF/spring.factories 文件中：
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
  org.springframework.boot.autoconfigure.data.redis.RedisAutoConfiguration,\
  org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration,\
  ...（120+ 个自动配置类）

Spring Boot 3.x（新格式）：
META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
文件中每行一个自动配置类全限定名
`

### 2.3 @Conditional：按需生效

自动配置类不是全部生效，通过 @Conditional 系列注解控制：

`java
@Configuration
@ConditionalOnClass(RedisOperations.class)          // classpath 有 Redis 相关类时生效
@EnableConfigurationProperties(RedisProperties.class) // 读取 spring.redis.* 配置
@Import({ LettuceConnectionConfiguration.class, JedisConnectionConfiguration.class })
public class RedisAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean(name = "redisTemplate")  // 用户没有自定义 redisTemplate 时才创建
    @ConditionalOnSingleCandidate(RedisConnectionFactory.class)
    public RedisTemplate<Object, Object> redisTemplate(RedisConnectionFactory connectionFactory) {
        RedisTemplate<Object, Object> template = new RedisTemplate<>();
        template.setConnectionFactory(connectionFactory);
        return template;
    }

    @Bean
    @ConditionalOnMissingBean    // 用户没有自定义 StringRedisTemplate 时才创建
    @ConditionalOnSingleCandidate(RedisConnectionFactory.class)
    public StringRedisTemplate stringRedisTemplate(RedisConnectionFactory connectionFactory) {
        return new StringRedisTemplate(connectionFactory);
    }
}
`

**关键注解速查**：

| 注解 | 条件 |
|------|------|
| @ConditionalOnClass | classpath 存在指定类 |
| @ConditionalOnMissingClass | classpath 不存在指定类 |
| @ConditionalOnBean | 容器中存在指定 Bean |
| @ConditionalOnMissingBean | 容器中不存在指定 Bean |
| @ConditionalOnProperty | 配置属性满足条件 |
| @ConditionalOnWebApplication | 是 Web 应用 |
| @ConditionalOnExpression | SpEL 表达式为 true |

---

## 三、自定义 Starter：实现一个限流 Starter

### 3.1 项目结构

`
rate-limit-spring-boot-starter/
├── src/main/java/
│   └── com/example/ratelimit/
│       ├── RateLimitAutoConfiguration.java  ← 自动配置类
│       ├── RateLimitProperties.java          ← 配置属性类
│       └── RateLimitService.java             ← 核心服务
└── src/main/resources/
    └── META-INF/
        └── spring/
            └── org.springframework.boot.autoconfigure.AutoConfiguration.imports
`

### 3.2 配置属性类

`java
@ConfigurationProperties(prefix = "ratelimit")
public class RateLimitProperties {
    private int maxRequests = 100;   // 默认每秒最大请求数
    private int windowSeconds = 1;   // 时间窗口（秒）
    private boolean enabled = true;

    // getters/setters
}
`

### 3.3 自动配置类

`java
@AutoConfiguration
@ConditionalOnClass(RateLimitService.class)              // 依赖存在时生效
@ConditionalOnProperty(prefix = "ratelimit", name = "enabled", havingValue = "true", matchIfMissing = true)
@EnableConfigurationProperties(RateLimitProperties.class)
public class RateLimitAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean   // 用户可以覆盖
    public RateLimitService rateLimitService(RateLimitProperties props) {
        return new RateLimitService(props.getMaxRequests(), props.getWindowSeconds());
    }
}
`

### 3.4 注册自动配置

`
文件：META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
内容：
com.example.ratelimit.RateLimitAutoConfiguration
`

### 3.5 使用方只需引入依赖

`yaml
# application.yml（可选，有默认值）
ratelimit:
  max-requests: 200
  window-seconds: 1
  enabled: true
`

`java
@Service
public class ApiService {
    @Autowired
    private RateLimitService rateLimitService;  // 自动注入，无需任何额外配置
}
`

---

## 四、调试自动装配

当自动配置不生效时：

`ash
# 启动时加参数，查看所有自动配置的生效/未生效原因
java -jar app.jar --debug

# 或在 application.yml 中开启
logging:
  level:
    org.springframework.boot.autoconfigure: DEBUG
`

输出示例：

`
============================
CONDITIONS EVALUATION REPORT
============================
Positive matches:
-----------------
   RedisAutoConfiguration matched:
      - @ConditionalOnClass found required class 'RedisOperations' (OnClassCondition)

Negative matches:
-----------------
   MongoAutoConfiguration:
      Did not match:
         - @ConditionalOnClass did not find required class 'com.mongodb.client.MongoClient'
`

---

## 五、常见坑点

### 坑 1：自定义 Bean 没有覆盖自动配置

`java
// ❌ 没加 @Primary 或 @ConditionalOnMissingBean，与自动配置的 Bean 产生冲突
@Bean
public RedisTemplate<String, Object> redisTemplate() { ... }

// ✅ 加 @Primary 优先使用，或者自动配置类用了 @ConditionalOnMissingBean（大多数情况可以直接定义）
@Bean
@Primary
public RedisTemplate<String, Object> redisTemplate() { ... }
`

### 坑 2：@ConfigurationProperties 未绑定

`java
// ❌ 忘记加 @EnableConfigurationProperties 或 @Component
@ConfigurationProperties(prefix = "myapp")
public class MyProperties {
    private String name;  // 值为 null，未从配置文件读取
}

// ✅ 方式一：在 @SpringBootApplication 类上加 @EnableConfigurationProperties
// ✅ 方式二：在 Properties 类上加 @Component
// ✅ 方式三：在 AutoConfiguration 类上加 @EnableConfigurationProperties(MyProperties.class)
`

---

## 六、总结与延伸

**核心要点**：
- 自动装配 = @EnableAutoConfiguration + SPI（spring.factories/AutoConfiguration.imports）+ @Conditional 过滤
- @ConditionalOnMissingBean 保证用户自定义 Bean 优先级高于自动配置
- 自定义 Starter 三要素：AutoConfiguration 类 + Properties 类 + SPI 注册文件

**延伸阅读方向**：
- Spring Boot Actuator：通过 /actuator/conditions 端点在线查看条件评估报告
- Spring Boot 3.x 变化：spring.factories 被 AutoConfiguration.imports 替代，更高效
- ImportSelector vs ImportBeanDefinitionRegistrar：两种动态注册 Bean 的方式
- GraalVM Native Image：自动装配在 AOT 编译期的静态分析与优化
