# Docker Compose 多服务编排实战

<div class="post-meta">📅 2025-09-13 &nbsp;·&nbsp; 🏷️ <span class="tag">Docker</span> <span class="tag">DevOps</span></div>

Docker Compose 用于定义和运行多容器 Docker 应用，一个 YAML 文件描述整个环境，`docker compose up` 一键启动。

---

## 一、基本结构

```yaml
# docker-compose.yml
version: '3.9'

services:        # 服务定义
  web:           # 服务名
    image: nginx:1.25
    ports:
      - "80:80"
    depends_on:
      - app
    networks:
      - frontend

  app:
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      - SPRING_PROFILES_ACTIVE=prod
    depends_on:
      db:
        condition: service_healthy
    networks:
      - frontend
      - backend

  db:
    image: mysql:8.0
    volumes:
      - db-data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: mydb
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - backend

volumes:
  db-data:

networks:
  frontend:
  backend:
    internal: true  # 不暴露到外部网络
```

---

## 二、常用命令

```bash
# 启动（-d 后台，--build 重新构建）
docker compose up -d
docker compose up -d --build

# 停止并删除容器（不删数据卷）
docker compose down

# 停止并删除容器 + 数据卷（清空数据）
docker compose down -v

# 查看服务状态
docker compose ps

# 查看日志
docker compose logs -f           # 所有服务
docker compose logs -f app       # 指定服务

# 重启单个服务
docker compose restart app

# 扩容（将 app 服务扩到 3 个实例）
docker compose up -d --scale app=3

# 进入服务容器
docker compose exec app bash

# 查看服务配置（合并后的最终配置）
docker compose config
```

---

## 三、完整 Spring Boot + Redis + MySQL 示例

```yaml
# docker-compose.yml
version: '3.9'

services:
  app:
    build: .
    container_name: springboot-app
    ports:
      - "8080:8080"
    environment:
      SPRING_DATASOURCE_URL: jdbc:mysql://db:3306/mydb?useSSL=false&characterEncoding=utf8
      SPRING_DATASOURCE_USERNAME: root
      SPRING_DATASOURCE_PASSWORD: ${MYSQL_PASSWORD}
      SPRING_REDIS_HOST: redis
      SPRING_REDIS_PORT: 6379
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - app-net

  db:
    image: mysql:8.0
    container_name: mysql
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_DATABASE: mydb
      MYSQL_CHARSET: utf8mb4
    volumes:
      - mysql-data:/var/lib/mysql
      - ./sql/init.sql:/docker-entrypoint-initdb.d/init.sql  # 初始化 SQL
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-u", "root", "-p${MYSQL_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - app-net

  redis:
    image: redis:7-alpine
    container_name: redis
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      retries: 3
    networks:
      - app-net

  nginx:
    image: nginx:1.25-alpine
    container_name: nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
    depends_on:
      - app
    networks:
      - app-net

volumes:
  mysql-data:
  redis-data:

networks:
  app-net:
```

```bash
# .env 文件（敏感配置，不提交到 git）
MYSQL_PASSWORD=StrongPassword123
REDIS_PASSWORD=RedisPass456
```

---

## 四、多环境配置

```bash
# 结构
docker-compose.yml          # 基础配置（公共部分）
docker-compose.dev.yml      # 开发环境覆盖
docker-compose.prod.yml     # 生产环境覆盖

# 启动开发环境（合并两个文件）
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d

# docker-compose.dev.yml 示例
version: '3.9'
services:
  app:
    volumes:
      - .:/app   # 挂载源码（热重载）
    environment:
      SPRING_PROFILES_ACTIVE: dev
  db:
    ports:
      - "3306:3306"   # 开发时暴露端口，方便用工具连接
```

---

## 总结

| 场景 | 命令 |
|------|------|
| 启动全部服务 | `docker compose up -d --build` |
| 查看服务日志 | `docker compose logs -f [service]` |
| 停止并清理 | `docker compose down -v` |
| 进入容器 | `docker compose exec [service] bash` |
| 多环境区分 | `-f` 参数叠加 compose 文件 |

**延伸阅读**：
- [Docker Compose 官方文档](https://docs.docker.com/compose/) — 完整配置字段参考
- [Docker 基础入门](./2024-12-01-docker-basics.md) — 镜像/容器/网络前置知识
- [Dockerfile 最佳实践](./2025-06-21-dockerfile-best-practices.md) — Compose 依赖的 Dockerfile 优化
- Docker Compose vs K8s — 本地开发用 Compose，生产环境用 K8s，互补而非替代
