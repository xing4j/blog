# RESTful vs RPC：接口设计选型

<div class="post-meta">📅 2026-03-02 &nbsp;·&nbsp; 🏷️ <span class="tag">系统设计</span> <span class="tag">API 设计</span></div>

REST 和 RPC 是微服务间通信的两大主流方案，各有适用场景。

---

## 一、核心对比

| 维度 | RESTful | RPC（gRPC/Dubbo）|
|------|---------|-----------------|
| **风格** | 面向资源（HTTP + JSON）| 面向方法调用 |
| **协议** | HTTP/1.1 | HTTP/2（gRPC）/ 私有协议 |
| **序列化** | JSON（文本，可读）| Protobuf/Hessian（二进制，小）|
| **性能** | 较低（文本解析）| 更高（二进制，多路复用）|
| **强类型** | 弱（需手写 DTO 映射）| 强（IDL 定义，代码生成）|
| **跨语言** | ✅ 任意语言 | ✅（gRPC）/ ❌（部分 RPC 框架）|
| **调试** | ✅ 浏览器/Postman 直接测 | ❌ 需专用工具 |
| **适用场景** | 开放 API、前后端分离 | 内部微服务调用 |

---

## 二、RESTful API 设计规范

```
资源名称使用名词复数：
GET    /users          查询用户列表
GET    /users/{id}     查询单个用户
POST   /users          创建用户
PUT    /users/{id}     全量更新（覆盖）
PATCH  /users/{id}     部分更新
DELETE /users/{id}     删除用户

嵌套资源：
GET    /users/{id}/orders        用户的订单列表
POST   /users/{id}/orders        为用户创建订单
GET    /users/{id}/orders/{oid}  用户的某个订单

HTTP 状态码规范：
200 OK           - 查询/更新成功
201 Created      - 创建成功（POST）
204 No Content   - 删除成功
400 Bad Request  - 请求参数错误
401 Unauthorized - 未认证
403 Forbidden    - 无权限
404 Not Found    - 资源不存在
409 Conflict     - 资源冲突（如重复创建）
500 Internal Server Error - 服务器异常
```

---

## 三、RESTful 统一返回格式

```java
@Data
public class ApiResponse<T> {
    private int code;
    private String message;
    private T data;
    private long timestamp = System.currentTimeMillis();

    public static <T> ApiResponse<T> success(T data) {
        ApiResponse<T> resp = new ApiResponse<>();
        resp.code = 200;
        resp.message = "success";
        resp.data = data;
        return resp;
    }

    public static <T> ApiResponse<T> fail(int code, String message) {
        ApiResponse<T> resp = new ApiResponse<>();
        resp.code = code;
        resp.message = message;
        return resp;
    }
}

// 全局异常处理
@RestControllerAdvice
public class GlobalExceptionHandler {
    @ExceptionHandler(BusinessException.class)
    public ApiResponse<Void> handleBusiness(BusinessException e) {
        return ApiResponse.fail(e.getCode(), e.getMessage());
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ApiResponse<Void> handleValidation(MethodArgumentNotValidException e) {
        String message = e.getBindingResult().getFieldErrors().stream()
            .map(err -> err.getField() + ": " + err.getDefaultMessage())
            .collect(Collectors.joining(", "));
        return ApiResponse.fail(400, message);
    }
}
```

---

## 四、gRPC 示例

```protobuf
// user.proto
syntax = "proto3";
package user;

service UserService {
  rpc GetUser (GetUserRequest) returns (UserResponse);
  rpc ListUsers (ListUsersRequest) returns (stream UserResponse);  // 流式
}

message GetUserRequest {
  int64 id = 1;
}

message UserResponse {
  int64 id = 1;
  string name = 2;
  string email = 3;
}
```

```java
// Spring Boot gRPC 服务端（grpc-spring-boot-starter）
@GrpcService
public class UserGrpcService extends UserServiceGrpc.UserServiceImplBase {

    @Override
    public void getUser(GetUserRequest req, StreamObserver<UserResponse> observer) {
        User user = userRepository.findById(req.getId())
            .orElseThrow(() -> Status.NOT_FOUND.withDescription("用户不存在").asException());
        
        UserResponse response = UserResponse.newBuilder()
            .setId(user.getId())
            .setName(user.getName())
            .setEmail(user.getEmail())
            .build();
        
        observer.onNext(response);
        observer.onCompleted();
    }
}

// gRPC 客户端调用
@GrpcClient("user-service")
private UserServiceGrpc.UserServiceBlockingStub userStub;

UserResponse user = userStub.getUser(GetUserRequest.newBuilder().setId(1L).build());
```

---

## 五、接口版本管理

```java
// REST 版本管理方案

// 方案1：URL 版本（最直观）
@GetMapping("/v1/users/{id}")
@GetMapping("/v2/users/{id}")

// 方案2：请求头版本（URL 保持干净）
@GetMapping(value = "/users/{id}", headers = "API-Version=2")

// 方案3：Accept 媒体类型
@GetMapping(value = "/users/{id}", produces = "application/vnd.myapp.v2+json")
```

---

## 六、选型建议

```
对外 API（给第三方/前端）：
-> RESTful + OpenAPI（Swagger）规范
-> 易调试、通用性强、文档完善

内部微服务调用（高性能场景）：
-> gRPC（强类型、性能好、双向流支持）
-> Dubbo（Java 生态成熟，配置简单）

混合场景：
-> Gateway 对外暴露 REST，内部用 gRPC/Dubbo
-> Transcoder 做 REST-gRPC 自动转换
```

---

## 总结

- **REST** 适合：对外接口、前后端分离、需要通用性和可读性
- **gRPC** 适合：内部微服务、高性能低延迟、多语言异构系统  
- **Dubbo** 适合：Java 为主的微服务体系，与 Spring Cloud 生态集成好
