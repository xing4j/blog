# Service Mesh 与 Istio 实践

<div class="post-meta">📅 2026-04-30 &nbsp;·&nbsp; 🏷️ <span class="tag">微服务</span> <span class="tag">Istio</span></div>

Service Mesh（服务网格）将微服务间的通信治理下沉到基础设施层，让业务代码专注业务逻辑。

---

## 一、Service Mesh 核心概念

```
传统微服务治理：
业务代码 + SDK（Ribbon/Feign/Hystrix/...）
  → 治理逻辑耦合在业务代码中

Service Mesh：
业务 Pod                   Sidecar（Envoy）
  ↓ 所有流量都经过 Sidecar
  [业务容器] ←→ [Envoy] ←→ [Envoy] ←→ [业务容器]
                    ↑               ↑
               控制平面（Istiod）统一管理

好处：
- 业务代码无需 SDK，语言无关
- 流量治理、可观测性、安全认证统一下沉
```

---

## 二、Istio 架构

```
控制平面（Istiod）
  ├── Pilot：服务发现 + 流量规则下发
  ├── Citadel：证书管理（mTLS）
  └── Galley：配置校验

数据平面
  └── Envoy Sidecar（每个 Pod 自动注入）

主要 CRD（自定义资源）：
  ├── VirtualService   ── 流量路由规则
  ├── DestinationRule  ── 负载均衡、熔断策略
  ├── Gateway          ── 入口网关
  └── ServiceEntry     ── 外部服务注册
```

---

## 三、安装 Istio

```bash
# 下载 istioctl
curl -L https://istio.io/downloadIstio | sh -
export PATH=$PWD/istio-1.20.0/bin:$PATH

# 安装（demo profile 包含所有组件）
istioctl install --set profile=demo -y

# 为命名空间开启 Sidecar 自动注入
kubectl label namespace default istio-injection=enabled

# 验证安装
kubectl get pods -n istio-system
```

---

## 四、流量管理

### VirtualService 灰度发布

```yaml
# 将 10% 流量路由到 v2 版本
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: user-service
spec:
  hosts:
    - user-service
  http:
    - match:
        - headers:
            cookie:
              regex: ".*canary=true.*"
      route:
        - destination:
            host: user-service
            subset: v2
    - route:
        - destination:
            host: user-service
            subset: v1
          weight: 90
        - destination:
            host: user-service
            subset: v2
          weight: 10
```

```yaml
# DestinationRule 定义 subset（版本子集）
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: user-service
spec:
  host: user-service
  trafficPolicy:
    connectionPool:
      http:
        http1MaxPendingRequests: 100
    outlierDetection:
      consecutiveErrors: 5
      interval: 30s
      baseEjectionTime: 30s    # 熔断后驱逐时间
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

---

## 五、故障注入与超时

```yaml
# 注入 2s 延迟（测试超时处理）
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: order-service
spec:
  hosts:
    - order-service
  http:
    - fault:
        delay:
          percentage:
            value: 100
          fixedDelay: 2s
      route:
        - destination:
            host: order-service
```

---

## 六、可观测性

```bash
# 安装 Prometheus + Grafana + Kiali
kubectl apply -f samples/addons/prometheus.yaml
kubectl apply -f samples/addons/grafana.yaml
kubectl apply -f samples/addons/kiali.yaml

# 访问 Kiali 服务拓扑图
istioctl dashboard kiali

# 访问 Grafana 指标
istioctl dashboard grafana
```

**Kiali** 提供：服务调用图、流量拓扑、异常告警  
**Grafana** 提供：P99 延迟、RPS、错误率等 RED 指标

---

## 七、mTLS 双向认证

```yaml
# 强制所有服务使用 mTLS
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: default
spec:
  mtls:
    mode: STRICT  # 只允许 mTLS 流量

# 授权策略：只允许特定 Service Account 访问
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: user-service-authz
spec:
  selector:
    matchLabels:
      app: user-service
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/default/sa/order-service"]
      to:
        - operation:
            methods: ["GET", "POST"]
```

---

## 总结

| 功能 | Istio 方案 | 传统 SDK 方案 |
|------|-----------|-------------|
| 流量路由 | VirtualService | Ribbon/Feign |
| 熔断限流 | DestinationRule | Hystrix/Resilience4j |
| 链路追踪 | 自动注入 header | 手动集成 Sleuth |
| 安全认证 | mTLS + AuthorizationPolicy | 手动实现 |
| 服务拓扑 | Kiali | 无 |

Istio 适合 **Kubernetes 环境**，服务数量较多时投入产出比更高。小规模项目仍推荐传统 Spring Cloud 方案。
