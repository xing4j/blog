# JUnit 5 + Mockito 单元测试实战

<div class="post-meta">📅 2026-05-15 &nbsp;·&nbsp; 🏷️ <span class="tag">测试</span> <span class="tag">JUnit</span></div>

单元测试是保证代码质量的基石。本文介绍 JUnit 5 + Mockito 在 Spring Boot 项目中的最佳实践。

---

## 一、基础配置

```xml
<!-- Spring Boot Test（含 JUnit 5 + Mockito）-->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-test</artifactId>
    <scope>test</scope>
</dependency>
```

---

## 二、JUnit 5 核心注解

```java
@ExtendWith(MockitoExtension.class)
class OrderServiceTest {

    @Mock
    private OrderMapper orderMapper;      // Mock 依赖

    @Mock
    private StockService stockService;

    @InjectMocks
    private OrderService orderService;   // 被测类，自动注入 Mock

    @BeforeEach
    void setUp() {
        // 每个测试方法前执行
    }

    @AfterEach
    void tearDown() {
        // 每个测试方法后执行
    }

    @Test
    @DisplayName("下单成功：库存足够时创建订单")
    void createOrder_WhenStockSufficient_ShouldSucceed() {
        // Given（准备数据和 Mock 行为）
        OrderRequest req = new OrderRequest(1L, 1, new BigDecimal("99.90"));
        when(stockService.checkStock(1L, 1)).thenReturn(true);
        when(orderMapper.insert(any(Order.class))).thenReturn(1);

        // When（执行被测方法）
        Order order = orderService.createOrder(req);

        // Then（验证结果）
        assertNotNull(order);
        assertEquals(OrderStatus.PENDING, order.getStatus());
        verify(orderMapper, times(1)).insert(any(Order.class));
    }

    @Test
    @DisplayName("下单失败：库存不足时抛出异常")
    void createOrder_WhenStockInsufficient_ShouldThrow() {
        // Given
        OrderRequest req = new OrderRequest(1L, 100, new BigDecimal("99.90"));
        when(stockService.checkStock(1L, 100)).thenReturn(false);

        // Then
        assertThrows(BusinessException.class, 
            () -> orderService.createOrder(req),
            "库存不足时应抛出 BusinessException");
        
        verify(orderMapper, never()).insert(any());  // 不应该插入订单
    }
}
```

---

## 三、Mockito 常用 API

```java
// ===== Stub（打桩）=====

// 返回固定值
when(userService.findById(1L)).thenReturn(new User(1L, "Alice"));

// 参数匹配器
when(orderMapper.selectByUserId(anyLong())).thenReturn(List.of());
when(userService.findByName(eq("admin"))).thenReturn(adminUser);

// 抛出异常
when(stockService.deductStock(1L, 1)).thenThrow(new StockException("库存不足"));

// void 方法打桩
doNothing().when(emailService).sendConfirmation(any());
doThrow(new MailException("邮件发送失败")).when(emailService).sendConfirmation(eq("bad@test.com"));

// ===== Verify（验证）=====

verify(orderMapper).insert(any(Order.class));          // 被调用了1次
verify(emailService, times(2)).sendConfirmation(any()); // 被调用了2次
verify(stockService, never()).deductStock(anyLong(), anyInt()); // 从未被调用
verify(orderMapper, atLeast(1)).insert(any());         // 至少1次

// ===== ArgumentCaptor（捕获参数）=====
ArgumentCaptor<Order> orderCaptor = ArgumentCaptor.forClass(Order.class);
verify(orderMapper).insert(orderCaptor.capture());
Order capturedOrder = orderCaptor.getValue();
assertEquals(OrderStatus.PENDING, capturedOrder.getStatus());
assertEquals(new BigDecimal("99.90"), capturedOrder.getAmount());
```

---

## 四、参数化测试

```java
@ParameterizedTest
@CsvSource({
    "VALID, 99.90, true",
    "INVALID_STATUS, 99.90, false",
    "VALID, -1.00, false",     // 负数金额
    "VALID, 0.00, false"       // 零金额
})
@DisplayName("订单校验：多种场景")
void validateOrder_ParameterizedCases(String status, String amount, boolean expectedValid) {
    OrderRequest req = new OrderRequest(status, new BigDecimal(amount));
    assertEquals(expectedValid, orderService.isValidOrder(req));
}

@ParameterizedTest
@MethodSource("provideOrders")
void processOrder_MultipleOrders(Order order, OrderStatus expectedStatus) {
    Order result = orderService.process(order);
    assertEquals(expectedStatus, result.getStatus());
}

static Stream<Arguments> provideOrders() {
    return Stream.of(
        Arguments.of(new Order(OrderType.NORMAL), OrderStatus.PAID),
        Arguments.of(new Order(OrderType.PRE_SALE), OrderStatus.WAITING),
        Arguments.of(new Order(OrderType.FLASH), OrderStatus.PROCESSED)
    );
}
```

---

## 五、Spring 集成测试

```java
// 加载完整 Spring 上下文（适合集成测试）
@SpringBootTest
@Transactional  // 测试完自动回滚
class OrderServiceIntegrationTest {
    
    @Autowired
    private OrderService orderService;
    
    @Test
    void createOrderAndQuery_ShouldWorkCorrectly() {
        OrderRequest req = new OrderRequest(1L, 1, new BigDecimal("99.90"));
        Order created = orderService.createOrder(req);
        
        Order found = orderService.findById(created.getId());
        assertNotNull(found);
        assertEquals(created.getId(), found.getId());
    }
}

// 只加载 Web 层（Controller 层测试）
@WebMvcTest(OrderController.class)
class OrderControllerTest {
    
    @Autowired
    private MockMvc mockMvc;
    
    @MockBean
    private OrderService orderService;  // @MockBean 注入 Spring 容器
    
    @Test
    void createOrder_ShouldReturn201() throws Exception {
        when(orderService.createOrder(any())).thenReturn(new Order(1L, ...));
        
        mockMvc.perform(post("/api/orders")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {"productId": 1, "quantity": 1, "amount": "99.90"}
                    """))
            .andExpect(status().isCreated())
            .andExpect(jsonPath("$.data.id").value(1L));
    }
}
```

---

## 六、测试覆盖率

```xml
<!-- pom.xml：JaCoCo 覆盖率 -->
<plugin>
    <groupId>org.jacoco</groupId>
    <artifactId>jacoco-maven-plugin</artifactId>
    <configuration>
        <rules>
            <rule>
                <element>CLASS</element>
                <limits>
                    <limit>
                        <counter>LINE</counter>
                        <value>COVEREDRATIO</value>
                        <minimum>0.80</minimum>  <!-- 行覆盖率 80% -->
                    </limit>
                </limits>
            </rule>
        </rules>
    </configuration>
</plugin>
```

```bash
# 生成覆盖率报告
mvn clean test jacoco:report
# 报告位置：target/site/jacoco/index.html
```

---

## 总结

| 场景 | 方案 |
|------|------|
| 纯 Service 单元测试 | `@ExtendWith(MockitoExtension.class)` |
| Controller 层测试 | `@WebMvcTest` + MockMvc |
| 完整集成测试 | `@SpringBootTest` + `@Transactional` |
| Mock 外部依赖 | `@Mock` + `when().thenReturn()` |
| 验证调用行为 | `verify()` + `ArgumentCaptor` |
| 多场景测试 | `@ParameterizedTest` + `@CsvSource` |
