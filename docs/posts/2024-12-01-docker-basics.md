# Docker 从入门到生产：镜像、容器与编排核心实践

<div class="post-meta">📅 2024-12-01 &nbsp;·&nbsp; 🏷️ <span class="tag">Docker</span> <span class="tag">容器化</span> <span class="tag">DevOps</span></div>

"在我机器上能跑"——这句话曾是开发和运维之间最大的矛盾来源。Docker 通过容器化技术解决了环境一致性问题，成为现代 DevOps 流水线的基础。本文从核心概念到生产实践，系统讲解 Docker 的使用方式。

---

## 一、核心概念：镜像、容器、仓库

```
镜像（Image）      容器（Container）      仓库（Registry）
    |                    |                      |
  只读模板           运行中的实例           镜像存储分发
  分层结构           可读写层叠加           Docker Hub/私有仓库
  可共享/复用        隔离的进程空间
```

- **镜像（Image）**：只读的文件系统快照，由多个只读层叠加而成（Union FS）。每条 `RUN`/`COPY`/`ADD` 指令产生一个新层
- **容器（Container）**：镜像的运行实例，在镜像层之上添加一个可写层。容器删除后，可写层随之消失
- **仓库（Registry）**：存储和分发镜像的服务。公共仓库 Docker Hub，私有仓库 Harbor/ECR/ACR

### 镜像分层原理

```
Dockerfile:
  FROM ubuntu:22.04      -> Layer 1: ubuntu 基础层（共享）
  RUN apt-get update    -> Layer 2: 软件包列表（可复用）
  COPY app.jar /app/    -> Layer 3: 应用文件（业务相关）
  CMD ["java", "-jar"]  -> 元数据（不产生层）

优势：
- 相同基础层在多个镜像间共享，节省磁盘空间
- 缓存机制：未变更的层直接复用，加快构建速度
```

---

## 二、常用命令速查

### 镜像操作

```bash
# 拉取镜像
docker pull nginx:1.25-alpine

# 查看本地镜像
docker images

# 构建镜像（当前目录 Dockerfile）
docker build -t my-app:1.0 .

# 为镜像打标签（推送前）
docker tag my-app:1.0 registry.example.com/my-app:1.0

# 推送到仓库
docker push registry.example.com/my-app:1.0

# 删除镜像
docker rmi my-app:1.0

# 清理悬空镜像（<none>）
docker image prune
```

### 容器生命周期

```bash
# 运行容器（-d 后台，-p 端口映射，--name 命名，--rm 退出后自动删除）
docker run -d -p 8080:8080 --name my-app --rm my-app:1.0

# 查看运行中的容器
docker ps

# 查看所有容器（含已停止）
docker ps -a

# 进入运行中的容器
docker exec -it my-app /bin/bash

# 查看容器日志（-f 跟踪，--tail 100 最近100行）
docker logs -f --tail 100 my-app

# 停止/启动/重启
docker stop my-app
docker start my-app
docker restart my-app

# 删除容器
docker rm my-app

# 强制删除运行中的容器
docker rm -f my-app
```

---

## 三、端口映射与数据挂载

### 端口映射

```bash
# -p 主机端口:容器端口
docker run -p 8080:8080 my-app        # 监听所有网卡
docker run -p 127.0.0.1:8080:8080 my-app  # 仅监听本地回环（更安全）
docker run -p 8080-8082:8080-8082 my-app  # 端口范围映射
```

### 数据挂载（Volume）

```bash
# Named Volume（推荐，Docker 管理）
docker run -v mysql-data:/var/lib/mysql mysql:8

# Bind Mount（开发环境常用，挂载宿主机目录）
docker run -v $(pwd)/config:/app/config:ro my-app  # :ro 只读

# 查看 Volume
docker volume ls
docker volume inspect mysql-data

# 清理未使用的 Volume
docker volume prune
```

**Named Volume vs Bind Mount**：

| | Named Volume | Bind Mount |
|---|---|---|
| 管理方式 | Docker 管理 | 宿主机目录 |
| 可移植性 | 高 | 低（依赖宿主机路径）|
| 性能 | 高 | 略低（macOS 尤其明显）|
| 适用场景 | 数据库数据、应用数据 | 开发时代码热重载 |

---

## 四、网络模式

```bash
# 查看网络
docker network ls

# 创建自定义网络（推荐，容器间可用服务名通信）
docker network create app-network

# 容器加入自定义网络
docker run --network app-network --name db mysql:8
docker run --network app-network --name app my-app  # 可以 ping db

# 查看容器网络信息
docker inspect my-app | grep -A 20 "Networks"
```

**常见网络模式**：

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| bridge（默认）| 容器通过虚拟网桥连接，NAT 访问外网 | 单机多容器 |
| host | 容器与宿主机共享网络 | 高性能需求，省去 NAT 开销 |
| none | 无网络，完全隔离 | 安全性要求极高的任务 |
| 自定义 bridge | 容器间可用服务名 DNS 解析 | **推荐，代替 --link** |

---

## 五、编写生产级 Dockerfile

```dockerfile
# 多阶段构建：构建阶段
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
# 先复制 pom.xml 利用缓存（依赖不变时跳过下载）
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

# 运行阶段：使用更小的 JRE 镜像
FROM eclipse-temurin:17-jre-alpine AS runtime
WORKDIR /app

# 非 root 用户运行（安全实践）
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

# 复制构建产物
COPY --from=build /app/target/*.jar app.jar

# JVM 容器感知（避免使用宿主机内存配置）
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD wget -q -O- http://localhost:8080/actuator/health | grep -q '"status":"UP"' || exit 1

EXPOSE 8080
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

---

## 六、容器资源限制

生产环境必须设置资源限制，防止单个容器耗尽宿主机资源：

```bash
# 限制 CPU 和内存
docker run \
  --cpus="1.5" \              # 最多使用 1.5 个 CPU
  --memory="512m" \           # 内存限制 512MB
  --memory-swap="512m" \      # 禁用 swap（等于 memory 值）
  --pids-limit 100 \          # 限制进程数（防 fork 炸弹）
  my-app:1.0
```

```bash
# 查看容器资源使用情况（实时监控）
docker stats
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
```

---

## 七、常见问题排查

### 容器无法启动

```bash
# 查看退出的容器日志
docker logs <container-id>

# 查看容器详细信息（端口、挂载、环境变量等）
docker inspect <container-id>

# 以不同命令覆盖启动（排查 ENTRYPOINT 问题）
docker run -it --entrypoint /bin/sh my-app
```

### 镜像构建失败

```bash
# 查看构建缓存
docker builder du

# 清理构建缓存
docker builder prune

# 无缓存重新构建
docker build --no-cache -t my-app:1.0 .
```

### 容器间网络不通

```bash
# 检查容器是否在同一网络
docker network inspect app-network

# 在容器内测试连通性
docker exec -it app ping db
docker exec -it app curl http://db:3306
```
---

## 八、私有镜像仓库（Harbor）

```bash
# 使用 Harbor 私有仓库
# 登录
docker login harbor.example.com

# 拉取/推送
docker pull harbor.example.com/library/my-app:1.0
docker push harbor.example.com/library/my-app:1.0

# 在 K8s 中使用私有仓库（创建 imagePullSecret）
kubectl create secret docker-registry harbor-secret \
  --docker-server=harbor.example.com \
  --docker-username=admin \
  --docker-password=Harbor12345
```

---

## 九、Docker 生产最佳实践

| 实践 | 说明 |
|------|------|
| 使用多阶段构建 | 构建产物和运行时分离，最终镜像只包含必要文件 |
| 指定精确版本标签 | 不用 `latest`，用 `nginx:1.25.3-alpine` 保证可重现 |
| 设置资源限制 | `--memory` 和 `--cpus` 防止容器耗尽宿主机资源 |
| 非 root 用户运行 | 减小容器逃逸的攻击面 |
| 配置 HEALTHCHECK | 让 Docker/K8s 能感知应用的真实健康状态 |
| 使用 .dockerignore | 排除 node_modules、.git 等无关文件，减小构建上下文 |
| 善用分层缓存 | 变化少的层放前面（如依赖安装），变化多的层放后面 |

---

## 十、总结与延伸

**核心要点**：
1. **镜像 = 只读层叠加，容器 = 镜像 + 可写层**。理解分层结构是优化构建缓存的基础
2. 自定义 bridge 网络支持容器间**服务名 DNS 解析**，是替代已废弃 `--link` 的正确方式
3. Named Volume 适合数据持久化，Bind Mount 适合开发环境代码热重载
4. 生产 Dockerfile 三要素：**多阶段构建（减小镜像体积）+ 非 root 用户（安全）+ HEALTHCHECK（可观测）**
5. 容器资源限制是生产必备，未限制的容器可能导致宿主机 OOM 影响其他服务

**延伸阅读**：
- [Docker 官方文档](https://docs.docker.com/) — 完整 CLI 参考与 Dockerfile 指令说明
- [Dockerfile 最佳实践](./2025-06-21-dockerfile-best-practices.md) — 多阶段构建与镜像优化深度实践
- [Docker Compose 编排](./2025-09-13-docker-compose.md) — 多服务本地开发环境搭建
- [Kubernetes 基础](./2025-03-09-kubernetes-basics.md) — 容器编排的下一步
