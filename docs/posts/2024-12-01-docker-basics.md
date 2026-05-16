# Docker 入门：镜像、容器、仓库核心概念

<div class="post-meta">📅 2024-12-01 &nbsp;·&nbsp; 🏷️ <span class="tag">Docker</span> <span class="tag">DevOps</span></div>

Docker 是最流行的容器化工具，解决了"在我机器上没问题"的经典困境。

---

## 一、核心概念

```
镜像（Image）  →  模板（只读，类比 Java 的 Class）
容器（Container） → 运行实例（类比 Java 的对象）
仓库（Registry）  → 存储镜像（类比 Maven Repository）

关系：
Docker Hub（仓库）
    ↓ docker pull
镜像（Image）
    ↓ docker run
容器（Container，可读写层）
```

---

## 二、常用命令

```bash
# ===== 镜像操作 =====
docker pull nginx:1.25           # 拉取镜像
docker images                    # 列出本地镜像
docker rmi nginx:1.25            # 删除镜像
docker image prune               # 清理无用镜像

# ===== 容器生命周期 =====
docker run -d -p 80:80 --name web nginx   # 后台运行，端口映射
docker run -it --rm ubuntu bash           # 交互式，退出即删
docker ps                                  # 运行中的容器
docker ps -a                              # 所有容器（含已停止）
docker stop web                           # 停止容器
docker start web                          # 启动已停止容器
docker restart web                        # 重启
docker rm web                             # 删除容器
docker rm -f web                          # 强制删除（运行中）

# ===== 容器操作 =====
docker exec -it web bash                  # 进入容器 shell
docker logs web                           # 查看日志
docker logs -f web                        # 实时日志
docker logs --tail 100 web               # 最近 100 行
docker inspect web                        # 查看容器详情
docker stats                              # 实时资源监控
docker cp web:/etc/nginx/nginx.conf ./   # 从容器复制文件
```

---

## 三、端口与挂载

```bash
# 端口映射
-p 宿主机端口:容器端口
docker run -d -p 8080:80 nginx   # 访问宿主机 8080 → 容器 80

# 目录挂载（数据持久化）
-v 宿主机路径:容器路径
docker run -d \
  -v /data/mysql:/var/lib/mysql \  # 数据目录挂载
  -v /conf/my.cnf:/etc/my.cnf \   # 配置文件挂载
  -e MYSQL_ROOT_PASSWORD=123456 \  # 环境变量
  --name mysql \
  mysql:8.0

# 命名数据卷（推荐，由 docker 管理）
docker volume create mysql-data
docker run -d -v mysql-data:/var/lib/mysql mysql:8.0
docker volume ls
docker volume inspect mysql-data
```

---

## 四、网络模式

```bash
# bridge（默认）：容器通过虚拟网桥通信
# host：容器直接使用宿主机网络（无端口映射）
# none：无网络

# 创建自定义网络（容器可通过名称互访）
docker network create mynet
docker run -d --name app --network mynet myapp:1.0
docker run -d --name redis --network mynet redis:7
# app 容器中可以用 redis:6379 访问 Redis（不需要 IP）
```

---

## 五、简单 Dockerfile

```dockerfile
FROM openjdk:17-jre-slim

WORKDIR /app

# 先复制 pom.xml 利用缓存（依赖不变时不重新下载）
COPY target/myapp.jar app.jar

EXPOSE 8080

ENV JAVA_OPTS="-Xmx512m -Xms256m"

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

```bash
docker build -t myapp:1.0 .          # 构建镜像（. 为上下文目录）
docker run -d -p 8080:8080 myapp:1.0 # 运行
docker tag myapp:1.0 registry.example.com/myapp:1.0
docker push registry.example.com/myapp:1.0  # 推送到私有仓库
```

---

## 六、常见问题排查

```bash
# 容器启动失败
docker logs container_id            # 查看错误日志

# 容器内命令找不到
docker exec -it myapp sh            # 用 sh 而不是 bash（精简镜像）

# 端口占用
docker ps | grep 8080               # 查看哪个容器占用了端口

# 磁盘占用过大
docker system df                    # 查看 docker 磁盘使用
docker system prune -a              # 清理所有未使用资源（慎用）
```

---

## 总结

| 命令 | 说明 |
|------|------|
| `docker pull` | 拉取镜像 |
| `docker run -d -p -v` | 运行容器（后台/端口映射/挂载）|
| `docker exec -it` | 进入容器 |
| `docker logs -f` | 实时查看日志 |
| `docker build -t` | 构建镜像 |
| `docker ps / stop / rm` | 管理容器生命周期 |
