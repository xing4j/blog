# Spring Boot 测试体系：@SpringBootTest 与 MockMvc

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
> - 👉 **SB-22 Spring Boot 测试体系：@SpringBootTest 与 MockMvc（本文）**

**深度等级**：⭐⭐ 进阶｜**阅读时长**：约 22 分钟｜**分类**：Spring 生态

---

## 导读

好的测试让重构有信心，坏的测试让 CI 变慢还误报。Spring Boot 提供了从单元测试到全量集成测试的完整工具链：`@SpringBootTest` 全量上下文、各类测试切片（`@WebMvcTest`、`@DataJpaTest`）、Testcontainers 真实数据库。本文梳理各种测试类型的使用场景与最佳实践。

---

## 一、测试层次与工具选型

```
单元测试 ─── JUnit 5 + Mockito，无 Spring Context，速度最快
    ↓
切片测试 ─── @WebMvcTest / @DataJpaTest / @JsonTest，只启动部分上下文
    ↓
集成测试 ─── @SpringBootTest，全量 Context，可对接真实数据库（Testcontainers）
    ↓
端到端测试 ─── Selenium / Playwright，浏览器级别，本文不涉及
```

**原则**：测试金字塔——单元测试数量最多、最快；集成测试数量少，只测关键路径。

---

## 二、单元测试：Mockito 隔离外部依赖

```java
// Spring Boot 3.2 + JDK 17 + JUnit 5 + Mockito
// 纯单元测试，不需要 Spring Context（不加任何 @SpringBootTest 等注解）
class OrderServiceTest {

    @Mock
    private OrderRepository orderRepo;

    @Mock
    private InventoryClient inventoryClient;

    @InjectMocks
    private OrderService orderService;

    @BeforeEach
    void setUp() {
        MockitoAnnotations.openMocks(this);
    }

    @Test
    void should_throw_when_stock_insufficient() {
        // Given
        given(inventoryClient.getStock(1L)).willReturn(0);

        // When / Then
        assertThatThrownBy(() -> orderService.placeOrder(new OrderRequest(1L, 5)))
            .isInstanceOf(BusinessException.class)
            .hasMessageContaining("库存不足");
    }
}
```

---

## 三、@WebMvcTest：Controller 层切片测试

`@WebMvcTest` 只加载 MVC 相关组件（Controller、Filter、ExceptionHandler 等），不加载 Service、Repository，是测试 Controller 层的标准方式：

```java
// 切片测试：只启动 MVC 层，速度比 @SpringBootTest 快 3~5 倍
@WebMvcTest(OrderController.class)
class OrderControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean // 注入 Mock 到 Spring Context
    private OrderService orderService;

    @Autowired
    private ObjectMapper objectMapper;

    @Test
    void should_return_200_when_order_created() throws Exception {
        // Given
        CreateOrderRequest request = new CreateOrderRequest(1L, List.of(new OrderItemRequest(100L, 2)));
        Order mockOrder = Order.builder().id(999L).status("PENDING").build();
        given(orderService.create(any())).willReturn(mockOrder);

        // When / Then
        mockMvc.perform(post("/orders")
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(request)))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.code").value(200))
            .andExpect(jsonPath("$.data.id").value(999));
    }

    @Test
    void should_return_400_when_request_invalid() throws Exception {
        // 空 items 触发 @NotEmpty 校验失败
        CreateOrderRequest badRequest = new CreateOrderRequest(1L, List.of());

        mockMvc.perform(post("/orders")
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(badRequest)))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.code").value(400));
    }
}
```

---

## 四、@DataJpaTest：Repository 层切片测试

`@DataJpaTest` 只加载 JPA 相关组件，默认使用内嵌的 H2 数据库（自动回滚），适合测试 JPQL 查询、自定义 Repository 方法：

```java
@DataJpaTest
// 如果需要使用真实数据库，用下面的注解替换掉自动配置
// @AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
class OrderRepositoryTest {

    @Autowired
    private OrderRepository orderRepository;

    @Test
    void should_find_orders_by_user_and_status() {
        // Given：数据在事务内写入，测试完成后自动回滚
        Order order1 = new Order(1L, "PENDING");
        Order order2 = new Order(1L, "PAID");
        orderRepository.saveAll(List.of(order1, order2));

        // When
        List<Order> pendingOrders = orderRepository.findByUserIdAndStatus(1L, "PENDING");

        // Then
        assertThat(pendingOrders).hasSize(1);
        assertThat(pendingOrders.get(0).getStatus()).isEqualTo("PENDING");
    }
}
```

---

## 五、@SpringBootTest：全量集成测试

```java
// 全量 Spring Context，适合测试跨层的关键链路
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureMockMvc
class OrderIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private OrderRepository orderRepository;

    @Test
    @Transactional // 测试数据自动回滚
    void should_create_order_and_persist_to_db() throws Exception {
        // Given
        CreateOrderRequest request = buildValidRequest();

        // When
        mockMvc.perform(post("/orders")
                .contentType(MediaType.APPLICATION_JSON)
                .content(toJson(request)))
            .andExpect(status().isOk());

        // Then：验证数据库中有记录
        assertThat(orderRepository.count()).isGreaterThan(0);
    }
}
```

### webEnvironment 模式选择

| 模式 | 描述 | 适用场景 |
|------|------|---------|
| `MOCK`（默认）| 模拟 Servlet 环境，不启动真实服务器 | 配合 MockMvc，速度快 |
| `RANDOM_PORT` | 启动真实内嵌服务器，随机端口 | 测试真实 HTTP 调用、Servlet Filter |
| `DEFINED_PORT` | 启动真实内嵌服务器，固定端口 | 避免端口冲突时不推荐 |
| `NONE` | 不启动 Web 环境 | 只测 Service / Repository 层 |

---

## 六、Testcontainers：使用真实数据库测试

避免内嵌 H2 与生产 MySQL 行为差异，用 Testcontainers 启动真实 Docker 容器：

```xml
<!-- pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-testcontainers</artifactId>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>mysql</artifactId>
    <scope>test</scope>
</dependency>
```

```java
// Spring Boot 3.1+ 的 Testcontainers 整合（ServiceConnection）
@SpringBootTest
@Testcontainers
class OrderRepositoryContainerTest {

    @Container
    @ServiceConnection // 自动配置 DataSource，无需手动设置 URL/用户名密码
    static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.0.36");

    @Autowired
    private OrderRepository orderRepository;

    @Test
    void should_work_with_real_mysql() {
        Order order = new Order(1L, "PENDING");
        orderRepository.save(order);
        assertThat(orderRepository.findById(order.getId())).isPresent();
    }
}
```

---

## 七、测试切片对比

| 注解 | 加载内容 | 典型 Mock 对象 | 启动速度 |
|------|---------|--------------|---------|
| 无（纯 JUnit） | 无 Spring Context | `@Mock` (Mockito) | 极快（<100ms）|
| `@WebMvcTest` | Controller + MVC 组件 | `@MockBean` Service | 快（1~3s）|
| `@DataJpaTest` | JPA + 内嵌 DB | — | 快（1~3s）|
| `@JsonTest` | JSON 序列化组件 | — | 极快 |
| `@SpringBootTest` | 全量 Context | `@MockBean` 外部依赖 | 慢（5~30s）|

---

## 八、踩坑总结

❌ **每个 `@SpringBootTest` 测试类都会重启 Spring Context，导致测试套件运行时间超过 5 分钟**

✅ Spring 测试框架会缓存 ApplicationContext（相同配置的测试类复用同一个 Context）。触发 Context 重建的原因：①不同的 `properties`/`@TestPropertySource`；②不同的 `@MockBean`（每个不同的 Mock 组合都是新 Context）；③`@DirtiesContext` 注解。解决方案：将测试基类中公共 `@MockBean` 提取到统一的父类，减少 Context 变体数量。

❌ **`@DataJpaTest` 默认用 H2，测试全过但上了生产用 MySQL 却报 SQL 语法错误（如 `ON DUPLICATE KEY UPDATE`、`JSON` 列类型）**

✅ 两种方案：①在 `@DataJpaTest` 上加 `@AutoConfigureTestDatabase(replace = Replace.NONE)` 关闭内嵌 DB 替换，配合 Testcontainers 使用真实 MySQL；②将不兼容的 SQL 提取到 native query，并在测试时单独跳过或 Mock。

---

## 九、文章小结

- 测试金字塔：单元测试 > 切片测试 > 集成测试，数量与速度成反比
- `@WebMvcTest` 是测试 Controller 层的首选，只加载 MVC 组件，用 `@MockBean` 替代 Service
- `@DataJpaTest` 用内嵌 H2 测试 Repository，有方言差异时用 Testcontainers 换真实数据库
- `@SpringBootTest` 做全量集成测试，共享同配置的 Context 以减少重启次数
- Testcontainers + `@ServiceConnection` 是 Spring Boot 3.1+ 测试真实中间件的最简方式

---

## 十、思考题

1. 一个 `@SpringBootTest` 类使用了 `@MockBean OrderService`，另一个使用了 `@MockBean UserService`，Spring 测试框架会为这两个类分别创建新的 Context 吗？如何验证？

2. 对于依赖 Redis 的 Service 方法，用 `@MockBean` Mock 掉 Redis 连接，还是用 Testcontainers 启动真实 Redis？两种方案的取舍是什么？

---

## 参考资料

> 1. [Spring Boot 官方文档 - Testing](https://docs.spring.io/spring-boot/docs/current/reference/html/testing.html)
> 2. [Testcontainers for Java 官方文档](https://java.testcontainers.org/)
> 3. [JUnit 5 User Guide](https://junit.org/junit5/docs/current/user-guide/)
> 4. [SB-03 Spring MVC 请求处理：DispatcherServlet 与九大组件](posts/2026-05-24-spring-mvc-dispatcher.md)
