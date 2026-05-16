# SpringBoot 自动装配原理（@EnableAutoConfiguration 源码解析）

<div class="post-meta">📅 2024-10-27 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring Boot</span></div>

SpringBoot 最核心的特性就是自动装配——通过约定优于配置，让开发者无需手动注册大量 Bean。本文从源码层面拆解整个流程，并手写一个自定义 Starter。

---

## 一、整体流程图

```
@SpringBootApplication
        │
        ├─ @ComponentScan          → 扫描当前包及子包
        ├─ @SpringBootConfiguration → 等同 @Configuration
        └─ @EnableAutoConfiguration
                │
                └─ @Import(AutoConfigurationImportSelector.class)
                            │
                            ▼
              selectImports() 方法执行
                            │
                ┌───────────┴────────────┐
                │                        │
        Spring Boot 2.7-            Spring Boot 3.x+
   META-INF/spring.factories    META-INF/spring/
   EnableAutoConfiguration=...  AutoConfiguration.imports
                │                        │
                └───────────┬────────────┘
                            ▼
                  加载候选自动配置类列表
                            │
                            ▼
                  @Conditional 条件过滤
                  ├─ @ConditionalOnClass
                  ├─ @ConditionalOnMissingBean
                  ├─ @ConditionalOnProperty
                  └─ ...
                            │
                            ▼
                  注册满足条件的配置类 Bean
```

---

## 二、@SpringBootApplication 源码分析

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@SpringBootConfiguration      // 本质是 @Configuration
@EnableAutoConfiguration      // 核心：开启自动装配
@ComponentScan(excludeFilters = {
    @Filter(type = FilterType.CUSTOM, classes = TypeExcludeFilter.class),
    @Filter(type = FilterType.CUSTOM, classes = AutoConfigurationExcludeFilter.class)
})
public @interface SpringBootApplication {
    // 排除特定自动配置类
    Class<?>[] exclude() default {};
    String[] excludeName() default {};
}
```

---

## 三、@EnableAutoConfiguration 与 ImportSelector

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@AutoConfigurationPackage
@Import(AutoConfigurationImportSelector.class) // 关键
public @interface EnableAutoConfiguration {
    Class<?>[] exclude() default {};
}
```

`AutoConfigurationImportSelector` 实现了 `DeferredImportSelector`（延迟导入，在普通 Bean 注册完成后才执行）：

```java
public class AutoConfigurationImportSelector implements DeferredImportSelector {

    @Override
    public String[] selectImports(AnnotationMetadata metadata) {
        // 1. 获取自动配置候选列表
        AutoConfigurationEntry entry = getAutoConfigurationEntry(metadata);
        return StringUtils.toStringArray(entry.getConfigurations());
    }

    protected AutoConfigurationEntry getAutoConfigurationEntry(AnnotationMetadata metadata) {
        // 2. 从 spring.factories / AutoConfiguration.imports 加载候选类
        List<String> configurations = getCandidateConfigurations(metadata, attributes);

        // 3. 去重
        configurations = removeDuplicates(configurations);

        // 4. 排除 exclude 指定的类
        Set<String> exclusions = getExclusions(metadata, attributes);
        configurations.removeAll(exclusions);

        // 5. 过滤（@Conditional 条件）
        configurations = getConfigurationClassFilter().filter(configurations);

        return new AutoConfigurationEntry(configurations, exclusions);
    }
}
```

---

## 四、spring.factories vs AutoConfiguration.imports

### Spring Boot 2.x（spring.factories）

```properties
# META-INF/spring.factories
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
  org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration,\
  org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration,\
  org.springframework.boot.autoconfigure.data.redis.RedisAutoConfiguration
```

### Spring Boot 3.x（AutoConfiguration.imports）

```
# META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
org.springframework.boot.autoconfigure.web.servlet.WebMvcAutoConfiguration
org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration
org.springframework.boot.autoconfigure.data.redis.RedisAutoConfiguration
```

---

## 五、@Conditional 条件注解详解

| 注解 | 生效条件 | 典型用途 |
|------|---------|---------|
| `@ConditionalOnClass` | classpath 存在指定类 | 依赖可选时 |
| `@ConditionalOnMissingClass` | classpath 不存在指定类 | 排除冲突 |
| `@ConditionalOnBean` | 容器中存在指定 Bean | 依赖其他 Bean |
| `@ConditionalOnMissingBean` | 容器中不存在指定 Bean | 允许用户覆盖 |
| `@ConditionalOnProperty` | 配置属性满足条件 | 功能开关 |
| `@ConditionalOnWebApplication` | 是 Web 应用 | Web 相关配置 |
| `@ConditionalOnExpression` | SpEL 表达式为 true | 复杂条件 |

```java
// RedisAutoConfiguration 示例
@Configuration(proxyBeanMethods = false)
@ConditionalOnClass(RedisOperations.class)          // classpath 有 Redis 依赖
@EnableConfigurationProperties(RedisProperties.class)
@Import({ LettuceConnectionConfiguration.class, JedisConnectionConfiguration.class })
public class RedisAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean(name = "redisTemplate") // 用户没有自定义才创建
    public RedisTemplate<Object, Object> redisTemplate(RedisConnectionFactory factory) {
        RedisTemplate<Object, Object> template = new RedisTemplate<>();
        template.setConnectionFactory(factory);
        return template;
    }
}
```

---

## 六、手写自定义 Starter

### 目录结构

```
my-oss-spring-boot-starter/
├── pom.xml
└── src/main/
    ├── java/com/example/oss/
    │   ├── OssClient.java              # 核心功能类
    │   ├── OssProperties.java          # 配置属性
    │   └── OssAutoConfiguration.java   # 自动配置类
    └── resources/META-INF/
        └── spring/
            └── org.springframework.boot.autoconfigure.AutoConfiguration.imports
```

### Step 1：配置属性类

```java
@ConfigurationProperties(prefix = "oss")
public class OssProperties {
    private String endpoint;
    private String accessKey;
    private String secretKey;
    private String bucketName;
    // getters & setters
}
```

### Step 2：核心功能类

```java
public class OssClient {

    private final OssProperties properties;

    public OssClient(OssProperties properties) {
        this.properties = properties;
    }

    public String upload(String filename, InputStream data) {
        // 上传逻辑
        return properties.getEndpoint() + "/" + properties.getBucketName() + "/" + filename;
    }

    public void delete(String filename) {
        // 删除逻辑
    }
}
```

### Step 3：自动配置类

```java
@AutoConfiguration
@ConditionalOnClass(OssClient.class)
@EnableConfigurationProperties(OssProperties.class)
@ConditionalOnProperty(prefix = "oss", name = "enabled", havingValue = "true", matchIfMissing = true)
public class OssAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean // 允许用户自定义覆盖
    public OssClient ossClient(OssProperties properties) {
        return new OssClient(properties);
    }
}
```

### Step 4：注册自动配置（Spring Boot 3.x）

```
# src/main/resources/META-INF/spring/
# org.springframework.boot.autoconfigure.AutoConfiguration.imports

com.example.oss.OssAutoConfiguration
```

### Step 5：使用方

```xml
<!-- 引入 starter -->
<dependency>
    <groupId>com.example</groupId>
    <artifactId>my-oss-spring-boot-starter</artifactId>
    <version>1.0.0</version>
</dependency>
```

```yaml
# application.yml
oss:
  endpoint: https://oss.example.com
  access-key: AKID_xxx
  secret-key: secret_xxx
  bucket-name: my-bucket
```

```java
// 直接注入使用
@RestController
public class FileController {

    @Autowired
    private OssClient ossClient; // 自动装配，无需手动配置

    @PostMapping("/upload")
    public String upload(@RequestParam MultipartFile file) throws IOException {
        return ossClient.upload(file.getOriginalFilename(), file.getInputStream());
    }
}
```

---

## 七、自动装配加载顺序控制

```java
// 在其他配置之前加载
@AutoConfiguration(before = DataSourceAutoConfiguration.class)
public class MyDataSourceAutoConfiguration { }

// 在其他配置之后加载
@AutoConfiguration(after = JdbcTemplateAutoConfiguration.class)
public class MyRepositoryAutoConfiguration { }
```

---

## 八、总结

1. `@SpringBootApplication` = `@ComponentScan` + `@Configuration` + `@EnableAutoConfiguration`
2. `AutoConfigurationImportSelector` 从 `spring.factories`（2.x）或 `AutoConfiguration.imports`（3.x）加载候选配置类
3. `@Conditional` 系列注解进行条件过滤，只有满足条件的配置才生效
4. 自定义 Starter 三要素：**配置属性类** + **自动配置类** + **注册文件**
5. `@ConditionalOnMissingBean` 保证用户可以覆盖默认配置，体现"约定优于配置"精神
