# Spring 事务失效的 8 大场景：踩过才懂的坑

<div class="post-meta">📅 2024-06-02 &nbsp;·&nbsp; 🏷️ <span class="tag">Spring</span></div>

代码加了 @Transactional，但数据库回滚没生效——这是 Spring 事务失效最典型的求助场景。表面是注解问题，根源是对 Spring AOP 代理机制和事务传播规则的误解。本文梳理 8 个高频失效场景，每个都给出可重现的反例和修复方案。

---

## 一、背景：Spring 事务的实现原理

Spring 声明式事务基于 **AOP 动态代理**实现。当你调用一个带 @Transactional 的方法时，实际上是在调用代理对象的方法：

```
调用方 → 代理对象（TransactionInterceptor）→ 目标对象.method()
                 ↓
         开启事务（begin transaction）
                 ↓
         执行业务方法
                 ↓
         提交/回滚事务（commit/rollback）
```
**所有失效场景都可以从这张图找到根源**：要么代理没被调用，要么代理拦截失败，要么事务配置不匹配异常类型。

---

## 二、8 大失效场景详解

### 场景 1：同类内部方法调用（最常见）

```java
@Service
public class OrderService {

    // ❌ 事务失效：this.updateStock() 调用的是目标对象本身，绕过了代理
    @Transactional
    public void placeOrder(Order order) {
        orderDao.save(order);
        this.updateStock(order.getItemId());  // 直接调用，非代理调用
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void updateStock(Long itemId) {
        stockDao.decrement(itemId);
        // 如果这里抛异常，不会在独立事务中回滚，会连带 placeOrder 一起回滚
    }
}
```
**修复方案 A**：通过 Spring 容器获取代理对象再调用：

```java
@Service
public class OrderService {
    @Autowired
    private ApplicationContext context;

    @Transactional
    public void placeOrder(Order order) {
        orderDao.save(order);
        // 通过代理对象调用，触发 AOP 拦截
        context.getBean(OrderService.class).updateStock(order.getItemId());
    }
}
```
**修复方案 B（推荐）**：将 updateStock 拆分到另一个 Service，通过依赖注入调用。

### 场景 2：方法访问修饰符不是 public

```java
@Service
public class UserService {
    // ❌ protected/private/package-private 方法上的 @Transactional 无效
    @Transactional
    protected void doCreate(User user) {
        userDao.save(user);
    }
}
```
Spring AOP 基于接口代理（JDK）或子类代理（CGLIB），两者都只能拦截 public 方法。

### 场景 3：异常类型不匹配

```java
@Service
public class PayService {
    // ❌ 默认只回滚 RuntimeException 和 Error，捕获到的受检异常不会回滚
    @Transactional
    public void pay(Long orderId) throws Exception {
        try {
            payDao.deduct(orderId);
        } catch (SQLException e) {
            throw new Exception("支付失败", e);  // 受检异常，默认不回滚！
        }
    }

    // ✅ 明确指定回滚的异常类型
    @Transactional(rollbackFor = Exception.class)
    public void pay(Long orderId) throws Exception {
        payDao.deduct(orderId);  // 任何异常都会触发回滚
    }
}
```
**最佳实践**：生产代码统一使用 @Transactional(rollbackFor = Exception.class)。

### 场景 4：异常被 catch 吞掉

```java
@Service
public class InventoryService {
    // ❌ 异常被内部捕获，事务感知不到异常，正常提交
    @Transactional
    public void deduct(Long itemId, int qty) {
        try {
            inventoryDao.deduct(itemId, qty);
        } catch (Exception e) {
            log.error("库存扣减失败", e);  // ← 吞掉异常，Spring 以为成功！
        }
    }

    // ✅ 捕获后重新抛出，或手动标记回滚
    @Transactional
    public void deduct(Long itemId, int qty) {
        try {
            inventoryDao.deduct(itemId, qty);
        } catch (Exception e) {
            log.error("库存扣减失败", e);
            TransactionAspectSupport.currentTransactionStatus().setRollbackOnly();
            // 或：throw new RuntimeException(e);
        }
    }
}
```
### 场景 5：Bean 未被 Spring 管理

```java
// ❌ 不是 Spring Bean，@Transactional 无效（AOP 代理不会注入）
public class LegacyOrderService {
    @Transactional
    public void create(Order order) { ... }
}

// 手动 new 出来的对象，@Transactional 不生效
LegacyOrderService service = new LegacyOrderService();
service.create(order);
```
### 场景 6：多线程调用（事务不跨线程）

```java
@Service
public class BatchService {
    @Transactional
    public void batchProcess(List<Long> ids) {
        ids.forEach(id -> {
            // ❌ 新线程中没有事务上下文，子线程中的操作不在父事务中
            new Thread(() -> processOne(id)).start();
        });
    }
}
```
Spring 事务通过 ThreadLocal 绑定到当前线程，跨线程则事务上下文丢失。多线程批处理场景需要每个线程独立管理事务。

### 场景 7：数据库引擎不支持事务

```sql
-- ❌ MyISAM 不支持事务，@Transactional 对其无效
CREATE TABLE orders (id INT) ENGINE=MyISAM;

-- ✅ 使用 InnoDB
CREATE TABLE orders (id INT) ENGINE=InnoDB;
```
### 场景 8：事务传播属性配置错误

```java
@Service
public class AService {
    @Transactional
    public void methodA() {
        bService.methodB();  // 调用 B
    }
}

@Service
public class BService {
    // ❌ PROPAGATION_NOT_SUPPORTED：挂起当前事务，以非事务方式运行
    //    methodB 里的操作不在事务中，抛异常也不回滚
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    public void methodB() {
        dao.update();
    }
}
```
---

## 三、事务传播行为速查表

| 传播行为 | 说明 | 典型使用场景 |
|---------|------|------------|
| REQUIRED（默认）| 有事务则加入，无则新建 | 99% 的场景 |
| REQUIRES_NEW | 总是新建事务，挂起当前 | 日志记录、不受父事务影响的操作 |
| SUPPORTS | 有事务则加入，无则非事务执行 | 只读查询（可选） |
| NOT_SUPPORTED | 总是非事务执行，挂起当前 | 不需要事务的耗时查询 |
| MANDATORY | 必须在事务中，否则抛异常 | 强制要求调用方开启事务 |
| NEVER | 绝不能在事务中执行，否则抛异常 | 强制禁止事务 |
| NESTED | 嵌套事务，支持部分回滚（savepoint）| 大事务中的子操作可单独回滚 |

---

## 四、总结与延伸

**8 个失效场景速记**：
1. 同类内部调用（绕过代理）
2. 非 public 方法（代理无法拦截）
3. 异常类型不匹配（默认只回滚 RuntimeException）
4. 异常被 catch 吞掉
5. Bean 未被 Spring 管理
6. 多线程调用（事务不跨线程）
7. 数据库引擎不支持事务（MyISAM）
8. 传播属性配置不当

**一条规则防 80% 的坑**：始终加 @Transactional(rollbackFor = Exception.class)，避免跨类内部调用。

**延伸阅读方向**：
- Spring AOP 代理机制：JDK 动态代理 vs CGLIB，选择时机与限制
- 分布式事务：Seata AT 模式如何实现跨服务的事务一致性
- 编程式事务 TransactionTemplate：复杂场景下更可控的事务管理
- 数据库 MVCC：理解 MySQL InnoDB 如何实现读已提交/可重复读
