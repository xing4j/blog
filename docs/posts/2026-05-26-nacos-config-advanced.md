# SC-10 Nacos 配置治理进阶：多环境、灰度与动态刷新

> 📚 **本文属于「Spring Cloud 微服务实战」系列**
> - [SC-01 Spring Cloud 微服务全景：架构演进与组件选型](posts/2025-06-27-spring-cloud-overview.md)
> - [SC-02 Nacos 服务注册与配置中心实战](posts/2025-02-15-nacos-registry-config.md)
> - [SC-03 Spring Cloud Gateway：路由、过滤器与灰度发布](posts/2026-05-26-spring-cloud-gateway.md)
> - [SC-04 OpenFeign 深度实战：声明式调用、拦截器与熔断](posts/2025-09-06-openfeign-timeout-retry.md)
> - [SC-05 Spring Cloud LoadBalancer：负载均衡原理与自定义策略](posts/2026-05-26-spring-cloud-loadbalancer.md)
> - [SC-06 Sentinel 流量防护：限流、熔断与热点规则](posts/2025-04-26-sentinel-rate-limit.md)
> - [SC-07 分布式链路追踪：Micrometer Tracing + SkyWalking 实战](posts/2026-05-26-spring-cloud-tracing.md)
> - [SC-08 微服务安全：Gateway + JWT 统一鉴权方案](posts/2026-05-26-spring-cloud-security.md)
> - [SC-09 Seata 分布式事务：AT/TCC/Saga 三模式对比实战](posts/2025-01-11-seata-distributed-transaction.md)
> - 👉 **SC-10 Nacos 配置治理进阶：多环境、灰度与动态刷新（本文）**
> - [SC-11 微服务可观测性：Actuator + Prometheus + Grafana](posts/2026-05-26-spring-cloud-observability.md)
> - [SC-12 微服务最佳实践：接口幂等、版本兼容与蓝绿部署](posts/2026-05-26-microservice-best-practices.md)

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 20 分钟｜**分类**：微服务

## 导读

SC-02 讲了 Nacos 的基础用法，本文深入配置治理：如何用 Namespace + Group 隔离多套环境、如何用 `@RefreshScope` 实现不重启的配置热更新、如何做只推送给部分实例的灰度配置，以及如何加密存储敏感配置。

---

## 一、配置隔离模型：Namespace + Group + DataId

### 1.1 三层模型

```
Nacos
 |
 +-- Namespace: dev              (开发环境)
 |    +-- Group: order-service
 |    |    +-- DataId: order-service.yaml
 |    +-- Group: payment-service
 |         +-- DataId: payment-service.yaml
 |
 +-- Namespace: staging          (预发布环境)
 |    +-- Group: order-service
 |         +-- DataId: order-service.yaml
 |
 +-- Namespace: prod             (生产环境)
      +-- Group: DEFAULT_GROUP   (通用配置，所有服务共享)
      |    +-- DataId: common.yaml
      +-- Group: order-service
           +-- DataId: order-service.yaml
```

**设计原则**：
- `Namespace`：按**环境**划分（dev / staging / prod），做最强隔离，跨 Namespace 无法互访
- `Group`：按**服务**或**业务域**划分，同 Namespace 内分组管理
- `DataId`：具体的配置文件，命名规范：`${spring.application.name}.yaml`

### 1.2 Spring Boot 集成配置

```yaml
# bootstrap.yml（Spring Boot 3.x 需引入 spring-cloud-starter-bootstrap）
spring:
  application:
    name: order-service
  cloud:
    nacos:
      config:
        server-addr: nacos-server:8848
        namespace: ${NACOS_NAMESPACE:dev}   # 通过环境变量切换，dev/staging/prod
        group: order-service
        file-extension: yaml
        # 共享配置：多个服务共用的配置（如数据库连接池、Redis 连接）
        shared-configs:
          - data-id: common.yaml
            group: DEFAULT_GROUP
            refresh: true             # 共享配置也支持动态刷新
        # 扩展配置：优先级高于 shared-configs，低于主配置
        extension-configs:
          - data-id: order-service-db.yaml
            group: order-service
            refresh: true
```

**配置优先级（高到低）**：
主配置 `order-service.yaml` > 扩展配置 `extension-configs` > 共享配置 `shared-configs` > 本地 `application.yml`

---

## 二、动态刷新：@RefreshScope 深度解析

### 2.1 基础用法

```java
// OrderLimitConfig.java  需要动态刷新的配置类
@Component
@RefreshScope           // 标注此注解，Nacos 配置变更时自动重新注入
public class OrderLimitConfig {

    @Value("${order.max-items-per-order:100}")
    private int maxItemsPerOrder;

    @Value("${order.flash-sale-enabled:false}")
    private boolean flashSaleEnabled;

    // Getter 省略
}
```

Nacos 控制台修改配置后，`@RefreshScope` Bean 会在下次访问时**懒加载重建**，新值立即生效，**无需重启服务**。

### 2.2 @RefreshScope 原理

```
Nacos 长轮询检测到配置变更
  |
  v
发布 RefreshEvent（Spring 事件）
  |
  v
ContextRefresher.refresh()
  |-- 重新绑定所有 @ConfigurationProperties Bean
  |-- 销毁所有 @RefreshScope Bean 的代理缓存
  v
下次访问 @RefreshScope Bean 时，从容器重新创建（重新注入 @Value）
```

**注意**：`@RefreshScope` 是懒重建，配置变更后 Bean 不立即销毁，而是在下次方法调用时才重建。高并发场景下可能有短暂的新旧配置交替问题。

### 2.3 @ConfigurationProperties 方式（推荐）

相比 `@Value`，`@ConfigurationProperties` + `@RefreshScope` 更适合管理成组的配置：

```java
// RateLimitProperties.java
@Component
@RefreshScope
@ConfigurationProperties(prefix = "rate-limit")
@Data
public class RateLimitProperties {

    private Map<String, ApiLimitConfig> apis = new HashMap<>();

    @Data
    public static class ApiLimitConfig {
        private int qps = 1000;       // 每秒请求数
        private int burstCapacity = 2000;
        private boolean enabled = true;
    }
}
```

对应 Nacos 中的配置：

```yaml
# order-service.yaml（在 Nacos 控制台编辑）
rate-limit:
  apis:
    createOrder:
      qps: 500
      burstCapacity: 1000
      enabled: true
    queryOrder:
      qps: 2000
      burstCapacity: 5000
      enabled: true
```

### 2.4 监听配置变更事件

需要在配置变更时执行特定逻辑（如刷新本地缓存）：

```java
// ConfigChangeListener.java
@Component
public class ConfigChangeListener implements ApplicationListener<RefreshScopeRefreshedEvent> {

    @Autowired
    private LocalCacheManager cacheManager;

    @Override
    public void onApplicationEvent(RefreshScopeRefreshedEvent event) {
        // 配置刷新后，清空本地缓存，触发重新加载
        log.info("Config refreshed, clearing local cache...");
        cacheManager.evictAll();
    }
}
```

---

## 三、灰度配置发布

### 3.1 Nacos 配置灰度功能

Nacos 2.1.x+ 支持**配置灰度**：将新配置先推送给指定 IP 的实例，验证无误再全量推送。

在 Nacos 控制台操作：
1. 编辑配置 → 选择"Beta 发布"
2. 填入灰度实例的 IP（如新版本的 Pod IP）
3. 点击"Beta 发布"，只有填写的 IP 收到新配置
4. 验证后点击"全量发布"，所有实例生效

### 3.2 代码层面的灰度配置读取

```java
// GrayConfigService.java  结合 Nacos SDK 手动实现更细粒度的灰度控制
@Service
public class GrayConfigService {

    @Autowired
    private NacosConfigManager nacosConfigManager;

    /**
     * 读取灰度配置：优先读 gray 版本，不存在则读稳定版
     * DataId 约定：xxx.yaml（稳定）/ xxx-gray.yaml（灰度）
     */
    public String getConfig(String dataId, String group) throws NacosException {
        // 先尝试读灰度配置
        String grayConfig = nacosConfigManager.getConfigService()
            .getConfig(dataId.replace(".yaml", "-gray.yaml"),
                group, 3000);

        if (grayConfig != null && isCurrentInstanceGray()) {
            return grayConfig;
        }
        // 灰度配置不存在或当前实例不是灰度实例，返回稳定配置
        return nacosConfigManager.getConfigService()
            .getConfig(dataId, group, 3000);
    }

    /** 判断当前实例是否是灰度实例（通过环境变量或 Nacos 元数据标记） */
    private boolean isCurrentInstanceGray() {
        return "true".equals(System.getenv("GRAY_INSTANCE"));
    }
}
```

---

## 四、敏感配置加密

生产环境数据库密码、API 密钥等不应明文存储在 Nacos：

```xml
<!-- pom.xml  使用 Jasypt 加密 -->
<dependency>
    <groupId>com.github.ulisesbocchio</groupId>
    <artifactId>jasypt-spring-boot-starter</artifactId>
    <version>3.0.5</version>
</dependency>
```

```yaml
# application.yml
jasypt:
  encryptor:
    password: ${JASYPT_PASSWORD}   # 加密密钥从环境变量读取，不存 Nacos
    algorithm: PBEWITHHMACSHA512ANDAES_256

# Nacos 中存储的加密配置（ENC() 包裹的是密文）
spring:
  datasource:
    password: ENC(xK8mN2pQ7rL4vW9...)   # 用 jasypt 工具加密后的密文
  redis:
    password: ENC(aB3cD4eF5gH6iJ7...)
```

生成密文：
```bash
java -cp jasypt-3.0.5.jar \
  org.jasypt.intf.cli.JasyptPBEStringEncryptionCLI \
  input="your-db-password" \
  password="your-jasypt-key" \
  algorithm=PBEWITHHMACSHA512ANDAES_256
```

---

## 五、踩坑总结

**❌ 坑 1：@RefreshScope 与 @Scheduled 方法**

`@RefreshScope` Bean 重建后，`@Scheduled` 定时任务不会自动重新注册，导致定时任务失效：

```java
// ❌ 错误：@Scheduled 和 @RefreshScope 不能同时使用
@Component
@RefreshScope
public class ScheduledTask {
    @Scheduled(fixedRateString = "${task.interval:60000}")
    public void run() { ... }
}

// ✅ 正确：将定时任务配置类和业务逻辑分离
// 定时任务类不加 @RefreshScope，从 @RefreshScope 的配置 Bean 中读取间隔值
@Component
public class ScheduledTask {
    @Autowired
    private TaskProperties taskProps;  // 此 Bean 加 @RefreshScope

    @Scheduled(fixedDelay = 1000)
    public void run() {
        long interval = taskProps.getInterval();  // 每次执行时读最新值
        // ...
    }
}
```

**❌ 坑 2：Namespace ID 填错导致配置读取失败**

Nacos 的 `namespace` 配置填写的是 **Namespace ID（UUID）**，不是 Namespace Name：

```yaml
# ❌ 错误：填了 Namespace 名称
spring.cloud.nacos.config.namespace: production

# ✅ 正确：填 Namespace ID（在 Nacos 控制台命名空间管理中查看）
spring.cloud.nacos.config.namespace: a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

**❌ 坑 3：共享配置和主配置中存在同名 Key，优先级不明**

```yaml
# ✅ 明确优先级规则，避免同名 Key：主配置 > extension-configs > shared-configs
# 建议共享配置只放基础设施配置（连接池大小、超时时间），业务配置放主配置
```

---

## 六、文章小结

- **Namespace + Group + DataId** 三层模型实现了环境、服务、配置文件三个维度的隔离，多套环境靠 Namespace 隔离，同环境不同服务靠 Group 区分
- `@RefreshScope` 使 Bean 在 Nacos 配置变更后**懒重建**，实现热更新；`@ConfigurationProperties` 比零散的 `@Value` 更易于管理成组配置
- 配置灰度发布先推送少量实例验证，大幅降低配置变更的线上风险
- 敏感配置使用 **Jasypt 加密**后再存入 Nacos，加密密钥通过环境变量注入，做到密文上 Git、密钥不落盘

## 七、思考题

1. `@RefreshScope` Bean 在高并发场景下重建时，会不会出现部分线程用旧 Bean、部分线程用新 Bean 的问题？这是 Bug 还是设计取舍？
2. 如果 Nacos 集群不可用，服务是否还能正常启动？配置会丢失吗？如何配置本地快照兜底？
3. Nacos 配置中心和 Spring Cloud Config（基于 Git）相比，各自的优缺点是什么？

## 参考资料

- [Nacos 配置管理官方文档](https://nacos.io/zh-cn/docs/v2/guide/user/configuration-management.html)
- [Spring Cloud Alibaba Nacos Config 文档](https://sca.aliyun.com/docs/2023/user-guide/nacos/quick-start/)
- [Jasypt Spring Boot 使用指南](https://github.com/ulisesbocchio/jasypt-spring-boot)
