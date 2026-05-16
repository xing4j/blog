# K8s 生产部署：Ingress、PVC 与 StatefulSet

<div class="post-meta">📅 2025-11-06 &nbsp;·&nbsp; 🏷️ <span class="tag">Kubernetes</span> <span class="tag">DevOps</span></div>

K8s 基础概念之外，生产环境还需要掌握 Ingress、持久化存储和有状态应用部署。

---

## 一、Ingress：HTTP 路由

Ingress 是 K8s 集群的 HTTP/HTTPS 入口，类似 Nginx 反向代理。

```yaml
# 安装 Nginx Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

---
# Ingress 路由规则
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.example.com
      secretName: tls-secret     # TLS 证书 Secret
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /user
            pathType: Prefix
            backend:
              service:
                name: user-service
                port:
                  number: 80
          - path: /order
            pathType: Prefix
            backend:
              service:
                name: order-service
                port:
                  number: 80
```

---

## 二、持久化存储（PVC/PV）

```yaml
# StorageClass（云厂商通常预置）
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: kubernetes.io/aws-ebs
parameters:
  type: gp3

---
# PVC：申请存储
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
spec:
  accessModes:
    - ReadWriteOnce     # 单节点读写（适合数据库）
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 20Gi

---
# 在 Pod 中使用 PVC
spec:
  volumes:
    - name: mysql-storage
      persistentVolumeClaim:
        claimName: mysql-pvc
  containers:
    - name: mysql
      volumeMounts:
        - name: mysql-storage
          mountPath: /var/lib/mysql
```

---

## 三、StatefulSet：有状态应用

StatefulSet 为每个 Pod 提供固定的网络标识和存储，适合 MySQL、Kafka、Elasticsearch。

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
spec:
  serviceName: mysql-headless
  replicas: 3
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
        - name: mysql
          image: mysql:8.0
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/mysql
  # 为每个 Pod 自动创建独立 PVC
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 20Gi

---
# Headless Service（DNS 解析到具体 Pod IP）
apiVersion: v1
kind: Service
metadata:
  name: mysql-headless
spec:
  clusterIP: None    # Headless
  selector:
    app: mysql
  ports:
    - port: 3306
# Pod DNS：mysql-0.mysql-headless.default.svc.cluster.local
#          mysql-1.mysql-headless.default.svc.cluster.local
```

---

## 四、资源配额与限制

```yaml
# Namespace 级别资源配额
apiVersion: v1
kind: ResourceQuota
metadata:
  name: dev-quota
  namespace: dev
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "50"

---
# LimitRange：Pod 默认资源限制
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: dev
spec:
  limits:
    - type: Container
      default:           # 未指定 limits 时的默认值
        memory: 256Mi
        cpu: 200m
      defaultRequest:    # 未指定 requests 时的默认值
        memory: 128Mi
        cpu: 100m
```

---

## 五、滚动更新与回滚

```bash
# 更新镜像
kubectl set image deploy/myapp myapp=myapp:2.0

# 查看更新进度
kubectl rollout status deploy/myapp

# 查看历史版本
kubectl rollout history deploy/myapp

# 回滚到上一版本
kubectl rollout undo deploy/myapp

# 回滚到指定版本
kubectl rollout undo deploy/myapp --to-revision=2
```

---

## 六、Pod 调度控制

```yaml
# 节点亲和性：优先调度到 SSD 节点
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 1
          preference:
            matchExpressions:
              - key: disk-type
                operator: In
                values: ["ssd"]

  # Pod 反亲和性：同一服务的 Pod 分散到不同节点
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app: myapp
          topologyKey: kubernetes.io/hostname
```

---

## 总结

| 资源 | 用途 |
|------|------|
| Ingress | HTTP/HTTPS 入口路由 |
| PVC/PV | 持久化存储 |
| StatefulSet | 有状态应用（数据库/消息队列）|
| ResourceQuota | 命名空间资源限额 |
| 滚动更新 | 零停机发布，支持一键回滚 |
