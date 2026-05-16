# Kubernetes 核心概念入门

<div class="post-meta">📅 2025-03-09 &nbsp;·&nbsp; 🏷️ <span class="tag">Kubernetes</span> <span class="tag">DevOps</span></div>

Kubernetes（K8s）是容器编排的事实标准，解决大规模容器的部署、扩容、自愈等问题。

---

## 一、核心架构

```
Master 节点（控制平面）
  ├── API Server    ── 所有操作的统一入口（REST API）
  ├── Scheduler     ── 决定 Pod 调度到哪个节点
  ├── Controller    ── 确保集群状态与期望状态一致
  └── etcd          ── 存储集群所有状态（分布式 KV）

Worker 节点（数据平面）
  ├── kubelet       ── 管理节点上的 Pod 生命周期
  ├── kube-proxy    ── 实现 Service 的网络代理
  └── Container Runtime（Docker / containerd）
```

---

## 二、核心资源对象

### Pod
```yaml
# Pod 是 K8s 最小调度单位，可包含多个容器
apiVersion: v1
kind: Pod
metadata:
  name: myapp
  labels:
    app: myapp
spec:
  containers:
    - name: myapp
      image: myapp:1.0
      ports:
        - containerPort: 8080
      resources:
        requests:          # 调度保证的最小资源
          memory: "256Mi"
          cpu: "250m"      # 250m = 0.25 核
        limits:            # 最大使用上限
          memory: "512Mi"
          cpu: "500m"
      env:
        - name: SPRING_PROFILES_ACTIVE
          value: prod
      livenessProbe:
        httpGet:
          path: /actuator/health
          port: 8080
        initialDelaySeconds: 30
        periodSeconds: 10
```

### Deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 3              # 副本数
  selector:
    matchLabels:
      app: myapp
  strategy:
    type: RollingUpdate    # 滚动更新
    rollingUpdate:
      maxSurge: 1          # 更新时最多多出 1 个 Pod
      maxUnavailable: 0    # 更新时不允许不可用
  template:               # Pod 模板
    metadata:
      labels:
        app: myapp
    spec:
      containers:
        - name: myapp
          image: myapp:1.0
```

### Service
```yaml
# Service 为 Pod 提供稳定的网络访问入口
apiVersion: v1
kind: Service
metadata:
  name: myapp-svc
spec:
  selector:
    app: myapp              # 匹配带此 label 的 Pod
  ports:
    - port: 80              # Service 端口
      targetPort: 8080      # Pod 端口
  type: ClusterIP           # 集群内访问（默认）
  # type: NodePort          # 通过节点 IP:端口暴露
  # type: LoadBalancer      # 云厂商负载均衡
```

---

## 三、配置管理

```yaml
# ConfigMap：非敏感配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  APP_ENV: production
  LOG_LEVEL: info
  application.yaml: |
    spring:
      datasource:
        url: jdbc:mysql://mysql:3306/mydb

---
# Secret：敏感配置（base64 编码，不是加密）
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
data:
  password: cGFzc3dvcmQ=    # echo -n 'password' | base64

# 在 Pod 中使用
spec:
  containers:
    - name: app
      envFrom:
        - configMapRef:
            name: app-config
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: password
      volumeMounts:
        - name: config
          mountPath: /config
  volumes:
    - name: config
      configMap:
        name: app-config
```

---

## 四、常用 kubectl 命令

```bash
# 查看资源
kubectl get pods -n default
kubectl get pods -A              # 所有命名空间
kubectl get pods -w              # 实时监听变化
kubectl describe pod myapp-xxx  # 详细信息（排错常用）
kubectl get events --sort-by=.lastTimestamp  # 查看事件

# 日志
kubectl logs myapp-xxx
kubectl logs -f myapp-xxx                    # 实时
kubectl logs myapp-xxx --previous           # 上次崩溃的日志

# 操作
kubectl apply -f deployment.yaml            # 创建/更新
kubectl delete -f deployment.yaml           # 删除
kubectl rollout restart deploy/myapp        # 重启 deployment
kubectl scale deploy/myapp --replicas=5     # 扩容
kubectl rollout status deploy/myapp         # 查看更新状态

# 调试
kubectl exec -it myapp-xxx -- bash          # 进入容器
kubectl port-forward pod/myapp-xxx 8080:8080  # 本地端口转发
kubectl top pods                            # 查看 Pod 资源使用
```

---

## 五、HPA 自动扩缩容

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: myapp-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: myapp
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70   # CPU 使用率超 70% 时扩容
```

---

## 总结

| 概念 | 说明 |
|------|------|
| Pod | 最小调度单位，包含一个或多个容器 |
| Deployment | 无状态应用部署，支持滚动更新/回滚 |
| Service | 稳定的服务访问入口，负载均衡 |
| ConfigMap / Secret | 配置与敏感信息管理 |
| Namespace | 集群内的逻辑隔离 |
| HPA | 基于指标的自动扩缩容 |
