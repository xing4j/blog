# Spring 事务失效的 8 种场景与解决方案

<div class="post-meta">📅 2024-06-02 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span> <span class="tag">事务</span></div>

Spring 事务是 AOP 代理实现的，很多场景下事务会悄然失效。本文整理 8 种高频失效场景，每种给出错误代码与修复方案。

---

## 场景一：同类内部方法调用（最常见）

### 失效原因

Spring 事务基于 AOP 代理。同类内部直接调用走的是 `this` 引用，绕过代理，事务注解失效。

```java
// ❌ 错误：update() 内部调用 insert()，insert 上的事务失效
@Service
public class OrderService {

    public void update(Order order) {
        // this.insert() 不走代理，事务不生效
        this.insert(order);
    }

    @Transactional
    public void insert(Order order) {
        orderMapper.insert(order);
    }
}
```

### 修复方案

```java
// ✅ 方案1：注入自身代理
@Service
public class OrderService {

    @Autowired
    private OrderService self; // 注入代理对象

    public void update(Order order) {
        self.insert(order); // 通过代理调用，事务生效
    }

    @Transactional
    public void insert(Order order) {
        orderMapper.insert(order);
    }
}

// ✅ 方案2：拆分到不同 Service
@Service
public class OrderInsertService {
    @Transactional
    public void insert(Order order) {
        orderMapper.insert(order);
    }
}
```

---

## 场景二：方法非 public 修饰

### 失效原因

Spring AOP（JDK 动态代理或 CGLIB）只拦截 `public` 方法，`private`/`protected` 方法上的 `@Transactional` 无效。

```java
// ❌ 错误：private 方法事务失效
@Service
public class UserService {

    @Transactional
    private void saveUser(User user) { // private，事务不生效
        userMapper.insert(user);
    }
}
```

### 修复方案

```java
// ✅ 改为 public
@Service
public class UserService {

    @Transactional
    public void saveUser(User user) {
        userMapper.insert(user);
    }
}
```

---

## 场景三：异常被吞（catch 后未重新抛出）

### 失效原因

Spring 事务在 catch 住异常后不感知，不会触发回滚。

```java
// ❌ 错误：catch 了异常但没抛出
@Transactional
public void transfer(Long fromId, Long toId, BigDecimal amount) {
    try {
        accountMapper.deduct(fromId, amount);
        accountMapper.increase(toId, amount);
    } catch (Exception e) {
        log.error("转账失败", e); // 异常被吞，事务不回滚！
    }
}
```

### 修复方案

```java
// ✅ 方案1：重新抛出异常
@Transactional
public void transfer(Long fromId, Long toId, BigDecimal amount) {
    try {
        accountMapper.deduct(fromId, amount);
        accountMapper.increase(toId, amount);
    } catch (Exception e) {
        log.error("转账失败", e);
        throw e; // 必须重新抛出
    }
}

// ✅ 方案2：手动标记回滚
@Transactional
public void transfer(Long fromId, Long toId, BigDecimal amount) {
    try {
        accountMapper.deduct(fromId, amount);
        accountMapper.increase(toId, amount);
    } catch (Exception e) {
        log.error("转账失败", e);
        TransactionAspectSupport.currentTransactionStatus().setRollbackOnly();
    }
}
```

---

## 场景四：异常类型不匹配

### 失效原因

`@Transactional` 默认只回滚 `RuntimeException` 和 `Error`，受检异常（checked exception）不触发回滚。

```java
// ❌ 错误：IOException 是受检异常，默认不回滚
@Transactional
public void readAndSave(String path) throws IOException {
    String content = Files.readString(Path.of(path));
    dataMapper.save(content);
    if (content.isEmpty()) {
        throw new IOException("文件为空"); // 不会回滚！
    }
}
```

### 修复方案

```java
// ✅ 方案1：指定 rollbackFor
@Transactional(rollbackFor = Exception.class)
public void readAndSave(String path) throws IOException {
    String content = Files.readString(Path.of(path));
    dataMapper.save(content);
    if (content.isEmpty()) {
        throw new IOException("文件为空"); // 正常回滚
    }
}

// ✅ 方案2：包装为 RuntimeException
@Transactional
public void readAndSave(String path) {
    try {
        String content = Files.readString(Path.of(path));
        dataMapper.save(content);
    } catch (IOException e) {
        throw new RuntimeException("文件处理失败", e);
    }
}
```

---

## 场景五：数据库引擎不支持事务

### 失效原因

MySQL 的 MyISAM 引擎不支持事务，使用 InnoDB 才行。

```sql
-- ❌ MyISAM 不支持事务
CREATE TABLE `order` (
  `id` bigint PRIMARY KEY,
  `amount` decimal(10,2)
) ENGINE=MyISAM;

-- ✅ 改为 InnoDB
CREATE TABLE `order` (
  `id` bigint PRIMARY KEY,
  `amount` decimal(10,2)
) ENGINE=InnoDB;
```

排查方式：

```sql
SHOW TABLE STATUS WHERE Name = 'order';
-- 查看 Engine 列
```

---

## 场景六：传播行为配置错误

### 失效原因

`PROPAGATION_NOT_SUPPORTED` / `PROPAGATION_NEVER` 会主动挂起或拒绝事务。

```java
// ❌ 错误：NOT_SUPPORTED 会挂起外层事务
@Transactional
public void outerMethod() {
    innerMethod(); // 内层挂起事务，innerMethod 不在事务中执行
    orderMapper.insert(order);
}

@Transactional(propagation = Propagation.NOT_SUPPORTED)
public void innerMethod() {
    logMapper.insert(log); // 非事务执行，outerMethod 回滚不影响它
}
```

### 常见传播行为速查

| 传播行为 | 说明 | 适用场景 |
|---------|------|---------|
| `REQUIRED`（默认）| 有事务加入，无则创建 | 通用 |
| `REQUIRES_NEW` | 总是创建新事务，挂起外层 | 独立记录日志 |
| `NESTED` | 嵌套事务（保存点） | 子操作可独立回滚 |
| `NOT_SUPPORTED` | 以非事务方式运行，挂起外层 | 查询不需要事务 |
| `NEVER` | 不允许在事务中运行，否则抛异常 | 强制非事务 |

---

## 场景七：多线程环境下事务失效

### 失效原因

Spring 事务通过 `ThreadLocal` 绑定到线程，新线程中不携带原有事务上下文。

```java
// ❌ 错误：子线程中的操作不在主事务内
@Transactional
public void batchProcess(List<Order> orders) {
    orders.parallelStream().forEach(order -> {
        // 新线程！不在事务中，抛异常也不会回滚主线程事务
        orderMapper.insert(order);
    });
}
```

### 修复方案

```java
// ✅ 方案：编程式事务，每个线程独立管理
@Autowired
private TransactionTemplate transactionTemplate;

public void batchProcess(List<Order> orders) {
    List<CompletableFuture<Void>> futures = orders.stream().map(order ->
        CompletableFuture.runAsync(() ->
            transactionTemplate.execute(status -> {
                try {
                    orderMapper.insert(order);
                    return null;
                } catch (Exception e) {
                    status.setRollbackOnly();
                    throw e;
                }
            })
        )
    ).collect(Collectors.toList());
    CompletableFuture.allOf(futures.toArray(new CompletableFuture[0])).join();
}
```

---

## 场景八：手动 catch 未重新抛出（嵌套调用）

### 失效原因

外层方法 catch 了内层方法的异常，Spring 感知不到，不触发外层事务回滚。

```java
// ❌ 错误
@Transactional
public void outer() {
    try {
        inner(); // inner 抛出异常
    } catch (Exception e) {
        log.warn("inner failed, continue"); // 外层事务感知不到，不回滚
    }
    otherMapper.insert(xxx); // 会被提交！
}

@Transactional(propagation = Propagation.REQUIRED)
public void inner() {
    throw new RuntimeException("inner error");
    // 内层事务已标记 rollback-only，但外层 catch 住了
    // 外层事务提交时会抛 UnexpectedRollbackException
}
```

### 修复方案

```java
// ✅ 内层用 REQUIRES_NEW，相互独立
@Transactional(propagation = Propagation.REQUIRES_NEW)
public void inner() {
    throw new RuntimeException("inner error"); // 内层独立回滚，不影响外层
}

@Transactional
public void outer() {
    try {
        inner();
    } catch (Exception e) {
        log.warn("inner failed, continue"); // 外层事务正常提交
    }
    otherMapper.insert(xxx);
}
```

---

## 总结速查表

| # | 失效场景 | 根本原因 | 解决方案 |
|---|---------|---------|---------|
| 1 | 同类内部调用 | 绕过代理 | 注入自身/拆分Service |
| 2 | 非 public 方法 | AOP 不拦截 | 改为 public |
| 3 | 异常被吞 | 事务不感知 | 重新 throw / setRollbackOnly |
| 4 | 异常类型不匹配 | 默认仅回滚 RuntimeException | `rollbackFor=Exception.class` |
| 5 | 数据库不支持 | 引擎问题 | 改用 InnoDB |
| 6 | 传播行为错误 | 误用 NOT_SUPPORTED 等 | 理清传播行为语义 |
| 7 | 多线程 | ThreadLocal 不跨线程 | 编程式事务 |
| 8 | catch 未重抛（嵌套）| rollback-only 冲突 | REQUIRES_NEW 隔离 |
