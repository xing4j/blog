# Spring Boot 配置体系详解：来源类型、优先级与覆盖原则

> 📚 **本文属于「Spring Boot 原理与实战」系列**
> - [SB-01 Spring IoC 容器：BeanFactory 体系与 BeanDefinition 注册](posts/2026-05-24-spring-ioc-container.md)
> - [SB-02 Spring Bean 生命周期深度解析](posts/2024-07-27-spring-bean-lifecycle.md)
> - [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
> - [SB-04 Spring 事务传播行为：7 种传播级别与底层实现](posts/2026-05-24-spring-transaction-propagation.md)
> - [SB-05 Spring 事务失效的 8 种场景](posts/2024-06-02-spring-transaction-failure.md)
> - [SB-06 Spring AOP 代理机制：JDK vs CGLIB](posts/2024-08-22-spring-aop-proxy.md)
> - [SB-07 Spring Boot 启动流程：SpringApplication.run 全链路](posts/2026-05-24-spring-boot-startup.md)
> - [SB-08 Spring Boot 自动装配原理深度解析](posts/2024-10-27-spring-boot-autoconfigure.md)
> - 👉 **SB-09 Spring Boot 配置体系详解（本文）**
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

**深度等级**：⭐ 入门｜**阅读时长**：约 15 分钟｜**分类**：Spring 生态

<div class="post-meta">📅 2026-05-16 &nbsp;·&nbsp; 🏷️ <span class="tag">Java</span> <span class="tag">Spring Boot</span></div>

## 导读

Spring Boot 提供了极为灵活的外部化配置机制，支持从多种来源读取属性，并通过明确的优先级规则决定最终生效值。本文系统梳理配置来源类型、完整优先级顺序及覆盖原则，帮助你在多环境部署时做到心中有数。

---

## 一、配置来源类型总览

Spring Boot 将所有配置来源抽象为 `PropertySource`，并按照既定的优先级顺序组成一条 **属性查找链**。常见来源分为以下几类：

| 类别 | 典型来源 |
|------|---------|
| **命令行** | `--key=value` 启动参数 |
| **JVM 系统属性** | `-Dkey=value` |
| **操作系统环境变量** | `export KEY=VALUE` |
| **外部配置文件** | jar 包外的 `application.properties` / `application.yml` |
| **内部配置文件** | jar 包内的 `application.properties` / `application.yml` |
| **Profile 专属配置** | `application-{profile}.properties` / `.yml` |
| **注解声明** | `@PropertySource`、`@TestPropertySource` |
| **代码默认值** | `SpringApplication.setDefaultProperties()` |
| **测试专用** | `@SpringBootTest#properties`、`@TestPropertySource` |

---

## 二、完整优先级顺序（从高到低）

Spring Boot 官方文档（[Externalized Configuration](https://docs.spring.io/spring-boot/docs/current/reference/html/features.html#features.external-config)）定义了如下优先级，**序号越小优先级越高**，后者会被前者覆盖：

```
 1. Devtools 全局设置（~/.spring-boot-devtools.properties，仅 devtools 激活时生效）
 2. 测试注解 @TestPropertySource
 3. @SpringBootTest#properties 属性
 4. 命令行参数（--server.port=8081）
 5. SPRING_APPLICATION_JSON 内联 JSON（环境变量或系统属性中）
 6. ServletConfig init 参数
 7. ServletContext init 参数
 8. JNDI 属性（java:comp/env）
 9. Java 系统属性（System.getProperties()，即 -Dkey=value）
10. 操作系统环境变量
11. RandomValuePropertySource（random.* 占位符）
12. jar 包外的 Profile 专属配置文件（application-{profile}.properties / .yml）
13. jar 包内的 Profile 专属配置文件
14. jar 包外的通用配置文件（application.properties / .yml）
15. jar 包内的通用配置文件
16. @PropertySource 注解声明的配置
17. 默认属性（SpringApplication.setDefaultProperties()）
```

> **记忆口诀**：越"外"越优先，越"动态"越优先，越"静态打包"越靠后。

---

## 三、各类来源详解与示例

### 3.1 命令行参数（优先级 4）

```bash
java -jar app.jar --server.port=9090 --spring.datasource.url=jdbc:mysql://prod-db/mydb
```

- 以 `--` 开头，会自动转换为 Spring 属性。
- 优先级极高，适合在运维层面临时覆盖配置，**无需修改任何配置文件**。
- 若不希望命令行参数生效，可在代码中禁用：

```java
SpringApplication app = new SpringApplication(MyApp.class);
app.setAddCommandLineProperties(false);
app.run(args);
```

---

### 3.2 SPRING_APPLICATION_JSON（优先级 5）

可通过环境变量或系统属性传入一段 JSON，批量设置多个属性：

```bash
# 环境变量方式
export SPRING_APPLICATION_JSON='{"server":{"port":9090},"app":{"name":"prod"}}'
java -jar app.jar

# 系统属性方式
java -Dspring.application.json='{"server.port":9090}' -jar app.jar
```

适合在 Docker / Kubernetes 等容器化环境中通过单个变量注入多个配置。

---

### 3.3 JVM 系统属性（优先级 9）

```bash
java -Dserver.port=9090 -Dspring.profiles.active=prod -jar app.jar
```

- 通过 `System.getProperties()` 读取。
- 优先级低于命令行参数，但高于操作系统环境变量。

---

### 3.4 操作系统环境变量（优先级 10）

```bash
export SERVER_PORT=9090
export SPRING_DATASOURCE_URL=jdbc:mysql://prod-db/mydb
java -jar app.jar
```

**命名转换规则（Relaxed Binding）：**

Spring Boot 支持宽松绑定，以下写法等价于 `spring.datasource.url`：

| 环境变量写法 | 对应属性 |
|---|---|
| `SPRING_DATASOURCE_URL` | `spring.datasource.url` |
| `spring.datasource.url` | `spring.datasource.url` |
| `spring_datasource_url` | `spring.datasource.url` |

> 在 Kubernetes 中推荐使用全大写+下划线形式，既符合 Linux 环境变量规范，又兼容 Spring 宽松绑定。

---

### 3.5 外部 vs 内部配置文件（优先级 12-15）

**外部配置文件**指与 jar 包同目录（或指定目录）下的配置文件，**优先级高于打包在 jar 内的配置文件**。

```
/opt/app/
├── app.jar
└── application.properties   ← 优先级高于 jar 内部的同名文件
```

#### 默认搜索路径（优先级由高到低）

Spring Boot 启动时按以下顺序搜索配置文件，靠前的路径优先级更高：

```
1. file:./config/          （jar 所在目录的 config 子目录）
2. file:./config/*/        （config 子目录下的任意子目录，Spring Boot 2.4+）
3. file:./                 （jar 所在目录）
4. classpath:/config/      （classpath 下的 config 目录）
5. classpath:/             （classpath 根目录，即 src/main/resources/）
```

#### 自定义搜索路径的两个参数

Spring Boot 提供了两个参数来调整配置文件的搜索路径，它们的行为截然不同：

**`--spring.config.additional-location`：追加额外路径（推荐）**

在默认搜索路径的基础上，**追加**一组新路径，且这些追加的路径优先级**高于**所有默认路径：

```bash
# 追加单个目录（目录路径必须以 / 结尾）
java -jar app.jar --spring.config.additional-location=file:/etc/myapp/

# 追加多个路径（逗号分隔，越靠后优先级越高）
java -jar app.jar --spring.config.additional-location=file:/etc/myapp/,file:/run/secrets/

# 追加具体文件
java -jar app.jar --spring.config.additional-location=file:/etc/myapp/database.yml

# 也可通过环境变量设置
export SPRING_CONFIG_ADDITIONAL_LOCATION=file:/etc/myapp/
```

生效后的完整优先级链（高 → 低）：

```
file:/run/secrets/（追加路径，后者优先）
file:/etc/myapp/（追加路径）
file:./config/（默认路径）
file:./config/*/
file:./
classpath:/config/
classpath:/（jar 内部）
```

**`--spring.config.location`：完全替换搜索路径**

**丢弃**所有默认路径，只从指定的路径中加载配置。适合对配置来源有严格管控的场景：

```bash
# 只从指定文件加载，默认路径全部失效
java -jar app.jar --spring.config.location=file:/etc/myapp/application.properties

# 指定多个路径（逗号分隔，越靠后优先级越高）
java -jar app.jar --spring.config.location=classpath:/default.yml,file:/etc/myapp/override.yml
```

> **注意**：使用 `--spring.config.location` 后，jar 内部的 `application.properties` 也不再自动加载，务必确保指定路径中包含所有必要配置。

#### 两者对比

| 参数 | 行为 | 默认路径 | 适用场景 |
|------|------|---------|---------|
| `--spring.config.additional-location` | **追加**，默认路径保留 | ✅ 仍生效 | 在内置配置基础上叠加外部配置 |
| `--spring.config.location` | **替换**，默认路径丢弃 | ❌ 失效 | 完全接管配置来源，严格管控 |

---

### 3.6 Profile 专属配置（优先级 12-13）

```
application.properties          ← 通用基础配置
application-dev.properties      ← dev 环境追加/覆盖
application-prod.properties     ← prod 环境追加/覆盖
```

激活 Profile：

```bash
# 命令行
java -jar app.jar --spring.profiles.active=prod

# 环境变量
export SPRING_PROFILES_ACTIVE=prod

# application.properties 中（通常用于设置默认 profile）
spring.profiles.default=dev
```

**Profile 配置覆盖通用配置**，相同的 key 以 Profile 专属文件为准。

---

### 3.7 @PropertySource（优先级 16）

```java
@Configuration
@PropertySource("classpath:custom.properties")
@PropertySource("classpath:db-${spring.profiles.active}.properties")
public class AppConfig { }
```

- 优先级较低，会被配置文件、环境变量等覆盖。
- **不支持 YAML 文件**，只能加载 `.properties`。
- 适合加载模块专属的静态配置。

---

## 四、覆盖原则详解

### 4.1 高优先级 → 低优先级，单向覆盖

同一个 key 出现在多个来源时，高优先级来源的值生效，低优先级来源的值**被忽略**（而非合并）：

```
命令行: server.port=9090
application.properties: server.port=8080

最终生效: server.port=9090
```

### 4.2 Profile 专属配置覆盖通用配置

```yaml
# application.yml（通用）
server:
  port: 8080
logging:
  level:
    root: INFO

# application-prod.yml（prod 专属）
server:
  port: 80
logging:
  level:
    com.example: WARN
```

激活 `prod` 后，`server.port` 变为 `80`，`logging.level.root` 仍为 `INFO`（未在 prod 中声明，沿用通用配置）。

> **原则**：Profile 专属配置与通用配置**合并**，相同 key 以专属配置为准。

### 4.3 外部配置文件覆盖内部配置文件

打包后，运维人员可在部署目录放置 `application.properties` 覆盖 jar 内部的配置，实现**不重新打包即可修改配置**：

```
部署目录/application.properties（优先）> jar 内部/application.properties（兜底）
```

### 4.4 多 Profile 同时激活时的顺序

```bash
spring.profiles.active=common,prod
```

当多个 Profile 同时激活时，**后声明的 Profile 优先级更高**：

```
application-prod.properties > application-common.properties > application.properties
```

### 4.5 YAML 同文件多文档块（Multi-document）

```yaml
# application.yml
server:
  port: 8080
---
spring:
  config:
    activate:
      on-profile: prod
server:
  port: 80
```

`---` 分隔多个文档块，后面的文档块中激活的配置会覆盖前面的同名属性。

---

## 五、实战建议

| 场景 | 推荐方式 |
|------|---------|
| 本地开发差异化配置 | `application-dev.yml` + `spring.profiles.active=dev` |
| 敏感信息（密码、密钥） | 操作系统环境变量 / Kubernetes Secret 挂载文件 |
| 容器化部署批量注入 | `SPRING_APPLICATION_JSON` 或多个环境变量 |
| 运维追加外部配置（不破坏内置配置） | `--spring.config.additional-location=file:/etc/myapp/` |
| 完全接管配置来源（严格管控） | `--spring.config.location=file:/etc/myapp/app.yml` |
| 运维紧急覆盖单个属性 | 命令行参数 `--key=value` |
| 模块化静态配置 | `@PropertySource` 加载独立 `.properties` 文件 |
| CI/CD 流水线注入 | 命令行参数 `--key=value` 或环境变量 |

---

## 六、快速验证当前生效配置

在开发阶段，可通过 Actuator 查看最终合并后的所有属性及其来源：

```bash
# 添加依赖
# implementation 'org.springframework.boot:spring-boot-starter-actuator'

# 开放端点
management.endpoints.web.exposure.include=env
management.endpoint.env.show-values=always

# 访问
curl http://localhost:8080/actuator/env
curl http://localhost:8080/actuator/env/server.port
```

响应示例：

```json
{
  "property": {
    "source": "commandLineArgs",
    "value": "9090"
  },
  "activeProfiles": ["prod"]
}
```

`source` 字段直接告诉你该属性来自哪个配置来源，排查配置不生效问题时非常实用。

---

## 总结

```
优先级（高 → 低）：
命令行参数 > JVM 系统属性 > OS 环境变量
> 外部 Profile 配置 > 内部 Profile 配置
> 外部通用配置 > 内部通用配置
> @PropertySource > 默认属性

覆盖规则：
• 高优先级单向覆盖低优先级
• Profile 专属与通用配置合并，相同 key 专属优先
• 外部文件覆盖 jar 内部文件
• 多 Profile 时后声明者优先
```

理解这套规则后，面对多环境部署、容器化注入、运维紧急修改等场景，就能精准判断配置的最终来源，避免"明明改了配置却不生效"的困惑。

---

## 踩坑总结

❌ **K8s 中通过 ConfigMap 注入了环境变量 `SERVER_PORT=9090`，但应用仍然监听 8080**

✅ Spring Boot 的 relaxed binding 会将环境变量 `SERVER_PORT` 映射到 `server.port`，但有时候 K8s Pod 的环境变量注入顺序或命名不对。排查步骤：①访问 `/actuator/env/server.port` 查看该属性来自哪个 source；②确认环境变量名符合 Spring Boot 的 relaxed binding 规则（大写 + 下划线替换点和连字符）。

❌ **激活了 `spring.profiles.active=prod`，但 `application-prod.yml` 中的配置没有覆盖 `application.yml` 中相同的 key**

✅ Profile 专属配置文件（优先级 12/13）与通用配置文件（优先级 14/15）会**合并**，相同 key 时专属优先。如果没有生效，检查：①两个文件是否在同一位置（都在 jar 内或都在 jar 外）；②key 拼写是否完全一致；③是否在 Nacos 等配置中心也有同名 key 以更高优先级覆盖了。

---

## 文章小结

- Spring Boot 配置优先级遵循"越外越优先，越动态越优先"原则，共 17 个级别
- 命令行参数（`--key=value`）优先级最高，适合运维临时修改；默认属性（`setDefaultProperties`）优先级最低
- Profile 专属配置与通用配置是**合并关系**，相同 key 时专属优先，而非完全覆盖
- 多个 Profile 同时激活时，后声明的优先级更高
- `/actuator/env` 端点可直接查看每个属性来自哪个 source，是排查配置不生效的最快方法

---

## 思考题

1. 你的应用用了 `@PropertySource("classpath:custom.properties")` 加载了一个自定义配置文件。当 `application.yml` 和 `custom.properties` 中有相同的 key，哪个生效？为什么？

2. Nacos 配置中心的属性属于哪种 `PropertySource`？在 Spring Boot 标准 17 个级别中处于哪个位置？如何验证？

---

## 参考资料

> 1. [Spring Boot 官方文档 - Externalized Configuration](https://docs.spring.io/spring-boot/docs/current/reference/html/features.html#features.external-config)
> 2. [SB-08 Spring Boot 自动装配原理深度解析](posts/2024-10-27-spring-boot-autoconfigure.md)
> 3. [SB-18 Spring Boot Actuator：健康检查与自定义端点](posts/2026-05-24-spring-boot-actuator.md)
