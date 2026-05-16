# Nacos 注册中心与配置中心实战

<div class="post-meta">📅 2025-02-15 &nbsp;·&nbsp; 🏷️ <span class="tag">Nacos</span> <span class="tag">微服务</span></div>

Nacos（Dynamic Naming and Configuration Service）是阿里巴巴开源的服务注册发现与配置管理平台，是 Spring Cloud Alibaba 生态的核心组件。本文深入讲解服务注册发现原理、配置动态刷新机制，以及命名空间/分组设计实践。

---

## 一、Nacos 整体架构

```
                    ┌─────────────────────────────┐
                    │         Nacos Server         │
                    │                              │
                    │  ┌────────────┐  ┌────────┐  │
                    │  │ 注册中心   │  │配置中心 │  │
                    │  │ Naming     │  │Config  │  │
                    │  └────────────┘  └────────┘  │
                    │  ┌──────────────────────────┐ │
                    │  │  持久化：MySQL / 内嵌Derby │ │
                    │  └──────────────────────────┘ │
                    └──────────────┬──────────────┘
                         ↑心跳      │推送变更
            ┌────────────┘          └────────────┐
            │                                    │
   ┌────────▼──────────┐              ┌──────────▼──────────┐
   │   Service A       │              │    Service B         │
   │ (Provider/Consumer│              │  (Consumer)          │
   └───────────────────┘              └─────────────────────┘
```

---

## 二、服务注册发现原理

### 2.1 注册流程

```
1. 服务启动时，NacosAutoServiceRegistration 触发注册
   Service → POST /nacos/v1/ns/instance
   请求体：{ip, port, serviceName, group, namespace, weight, metadata}

2. Nacos Server 存储实例信息
   临时实例（ephemeral=true）：存内存（AP模式）
   持久实例（ephemeral=false）：存磁盘（CP模式）

3. 心跳保活（临时实例）
   Client 每 5s 发送一次心跳：PUT /nacos/v1/ns/instance/beat
   Server 15s 未收到心跳 → 标记为不健康
   Server 30s 未收到心跳 → 剔除实例
```

### 2.2 服务发现流程

```
1. Consumer 启动，订阅所需服务
   GET /nacos/v1/ns/instance/list?serviceName=xxx

2. Nacos 返回服务实例列表（包含健康状态、权重）
   Consumer 本地缓存实例列表

3. Nacos Server 实例变更时，主动 Push 给所有订阅者（UDP 推送）

4. Consumer 定时全量拉取（10s），作为 Push 失败的兜底
```

### 2.3 临时实例 vs 持久实例

| 对比项 | 临时实例（ephemeral=true）| 持久实例（ephemeral=false）|
|-------|--------------------------|---------------------------|
| 存储方式 | 内存 | 磁盘/数据库 |
| 一致性模型 | AP（Distro 协议）| CP（Raft 协议）|
| 心跳机制 | 必须（默认5s）| 不需要（主动健康检查）|
| 不健康处理 | 超时后自动删除 | 保留，标记为不健康 |
| 适用场景 | 微服务实例 | 数据库/Redis 等基础设施 |

---

## 三、Spring Boot 集成注册中心

### 3.1 依赖与配置

```xml
<!-- pom.xml -->
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
</dependency>
```

```yaml
# bootstrap.yml（必须在 bootstrap 阶段配置）
spring:
  application:
    name: user-service
  cloud:
    nacos:
      discovery:
        server-addr: localhost:8848
        namespace: dev          # 命名空间（环境隔离）
        group: DEFAULT_GROUP
        # 心跳配置
        heart-beat-interval: 5000   # 心跳间隔（ms）
        heart-beat-timeout: 15000   # 心跳超时（ms）
        # 实例元数据（自定义标签，用于灰度路由）
        metadata:
          version: v2
          region: east
        # 权重（影响负载均衡）
        weight: 1
```

```java
// 主类开启服务发现
@SpringBootApplication
@EnableDiscoveryClient
public class UserServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(UserServiceApplication.class, args);
    }
}
```

### 3.2 手动调用服务发现 API

```java
@Service
public class ServiceDiscoveryExample {
    
    @Autowired
    private DiscoveryClient discoveryClient;
    
    @Autowired
    private NacosDiscoveryProperties nacosDiscoveryProperties;
    
    /**
     * 获取指定服务的所有实例
     */
    public void listInstances(String serviceName) {
        List<ServiceInstance> instances = discoveryClient.getInstances(serviceName);
        instances.forEach(instance -> {
            System.out.printf("Host: %s, Port: %d, Metadata: %s%n",
                instance.getHost(),
                instance.getPort(),
                instance.getMetadata()
            );
        });
    }
    
    /**
     * 获取所有注册的服务名
     */
    public void listServices() {
        List<String> services = discoveryClient.getServices();
        services.forEach(System.out::println);
    }
}
```

---

## 四、配置中心详解

### 4.1 配置文件命名规则

```
Nacos 配置 DataId 命名规则（优先级从高到低）：
1. ${spring.application.name}-${spring.profiles.active}.${file-extension}
   例：user-service-dev.yaml

2. ${spring.application.name}.${file-extension}
   例：user-service.yaml

3. ${spring.application.name}
   例：user-service

4. 扩展配置（extension-configs）

5. 共享配置（shared-configs）
```

### 4.2 配置中心集成

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-config</artifactId>
</dependency>
<!-- Spring Boot 3.x 需要额外引入 bootstrap 支持 -->
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-bootstrap</artifactId>
</dependency>
```

```yaml
# bootstrap.yml
spring:
  application:
    name: user-service
  profiles:
    active: dev
  cloud:
    nacos:
      config:
        server-addr: localhost:8848
        namespace: dev
        group: DEFAULT_GROUP
        file-extension: yaml    # 配置文件格式
        # 共享配置（公共配置，多服务共用）
        shared-configs:
          - data-id: common-db.yaml    # 公共数据库配置
            group: DEFAULT_GROUP
            refresh: true
          - data-id: common-redis.yaml  # 公共Redis配置
            group: DEFAULT_GROUP
            refresh: true
        # 扩展配置（服务特有，优先级高于shared）
        extension-configs:
          - data-id: user-service-extra.yaml
            group: CUSTOM_GROUP
            refresh: true
```

### 4.3 动态刷新配置

```java
/**
 * @RefreshScope：Bean 在配置变更时自动重新创建，属性自动刷新
 */
@RestController
@RefreshScope
@Slf4j
public class ConfigController {
    
    // 自动注入 Nacos 配置值，配置变更时自动更新
    @Value("${user.maxPageSize:10}")
    private int maxPageSize;
    
    @Value("${feature.newUserFlow:false}")
    private boolean enableNewUserFlow;
    
    @GetMapping("/config/pageSize")
    public int getPageSize() {
        return maxPageSize; // 返回最新值
    }
}

/**
 * 监听配置变更事件
 */
@Component
@Slf4j
public class NacosConfigListener {
    
    /**
     * 监听配置刷新事件（@RefreshScope 触发后发布）
     */
    @EventListener(RefreshScopeRefreshedEvent.class)
    public void onRefresh(RefreshScopeRefreshedEvent event) {
        log.info("配置已刷新，刷新的 Bean: {}", event.getName());
    }
    
    /**
     * 监听 Environment 变更（具体配置项变化）
     */
    @EventListener(EnvironmentChangeEvent.class)
    public void onEnvironmentChange(EnvironmentChangeEvent event) {
        log.info("配置项变更：{}", event.getKeys());
    }
}
```

### 4.4 @ConfigurationProperties（推荐方式）

```java
/**
 * 使用 @ConfigurationProperties 绑定配置对象
 * 配合 @RefreshScope 实现动态刷新
 */
@Data
@Component
@RefreshScope
@ConfigurationProperties(prefix = "user")
public class UserProperties {
    private int maxPageSize = 10;
    private int sessionTimeout = 30;
    private boolean enableSmsVerification = false;
    private List<String> blacklistIps = Collections.emptyList();
}

// 使用
@Service
public class UserService {
    
    @Autowired
    private UserProperties userProperties;
    
    public List<User> listUsers(int page) {
        // 每次调用都获取最新配置
        int pageSize = userProperties.getMaxPageSize();
        return userMapper.selectPage(page, pageSize);
    }
}
```

---

## 五、命名空间与分组设计

### 5.1 三级隔离机制

```
Namespace（命名空间）→ Group（分组）→ DataId（配置文件）

推荐的隔离策略：
┌──────────────────────────────────────────────────────────┐
│  Namespace：环境隔离（不同命名空间数据完全隔离）             │
│  ├── dev（开发环境）                                      │
│  ├── test（测试环境）                                     │
│  ├── staging（预发布环境）                                │
│  └── prod（生产环境）                                     │
│                                                          │
│  Group：业务线/项目隔离                                    │
│  ├── ORDER_GROUP（订单业务线）                            │
│  ├── USER_GROUP（用户业务线）                             │
│  └── DEFAULT_GROUP（公共配置）                            │
│                                                          │
│  DataId：具体服务配置                                     │
│  ├── user-service.yaml                                   │
│  ├── user-service-dev.yaml（环境特有）                    │
│  └── common-db.yaml（共享配置）                          │
└──────────────────────────────────────────────────────────┘
```

### 5.2 命名空间隔离配置

```yaml
# 开发环境
spring:
  cloud:
    nacos:
      discovery:
        namespace: a1b2c3d4-dev   # Nacos 命名空间 ID（不是名称）
      config:
        namespace: a1b2c3d4-dev

# 生产环境
spring:
  cloud:
    nacos:
      discovery:
        namespace: e5f6g7h8-prod
      config:
        namespace: e5f6g7h8-prod
```

---

## 六、集群部署与持久化

### 6.1 MySQL 持久化配置

```bash
# 1. 初始化 Nacos 数据库
mysql -u root -p < nacos/conf/mysql-schema.sql

# 2. 修改 nacos/conf/application.properties
```

```properties
# nacos/conf/application.properties
spring.datasource.platform=mysql
db.num=1
db.url.0=jdbc:mysql://127.0.0.1:3306/nacos_config?characterEncoding=utf8&connectTimeout=1000&socketTimeout=3000&autoReconnect=true&useUnicode=true&useSSL=false&serverTimezone=UTC
db.user.0=nacos
db.password.0=nacos_password
```

### 6.2 集群配置

```bash
# nacos/conf/cluster.conf（列出所有集群节点）
192.168.1.10:8848
192.168.1.11:8848
192.168.1.12:8848
```

```
Nacos 集群架构：

       负载均衡（VIP）
           │
    ┌──────┼──────┐
    ▼      ▼      ▼
 Nacos1 Nacos2 Nacos3  ← Raft 协议选主
    └──────┼──────┘
           │
        MySQL（持久化）
```

### 6.3 集群节点状态查看

| 指标 | 查看方式 |
|------|---------|
| 集群状态 | `GET /nacos/v1/ns/operator/cluster/nodes` |
| 服务列表 | Nacos 控制台 → 服务管理 |
| 配置列表 | Nacos 控制台 → 配置管理 |
| 节点健康 | `GET /nacos/v1/console/health/liveness` |

---

## 七、常见问题排查

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| 服务注册失败 | Nacos 地址配置错误 | 检查 `server-addr` 格式（无 `http://`）|
| 配置不刷新 | 未加 `@RefreshScope` | Bean 添加 `@RefreshScope` 注解 |
| 读取不到配置 | DataId/Namespace 错误 | 确认 DataId 命名（带 profile 后缀）|
| 集群脑裂 | 网络分区 | 检查 cluster.conf，确保奇数节点 |
| 服务发现延迟 | 心跳超时 | 调小 `heartbeat-interval` |
| 配置加载顺序 | bootstrap 未生效 | 引入 `spring-cloud-starter-bootstrap` |
