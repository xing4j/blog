# Dockerfile 最佳实践：构建小而快的镜像

<div class="post-meta">📅 2025-06-21 &nbsp;·&nbsp; 🏷️ <span class="tag">Docker</span> <span class="tag">DevOps</span></div>

Dockerfile 编写质量直接影响镜像大小和构建速度。本文总结 Java/Node 项目的最佳实践。

---

## 一、分层缓存原则

```
Docker 镜像由多个 Layer（层）叠加而成
每条指令 = 一个 Layer
Layer 不变 → 使用缓存，不重新执行

错误示例（每次都重新复制所有内容）：
COPY . .
RUN mvn package

优化示例（利用缓存）：
COPY pom.xml .           # 依赖文件单独复制
RUN mvn dependency:go-offline  # 下载依赖（缓存）
COPY src ./src           # 再复制源码
RUN mvn package          # 只有源码变化才重新构建
```

---

## 二、多阶段构建

```dockerfile
# ===== Java Spring Boot 多阶段构建 =====

# 阶段1：构建（builder）
FROM maven:3.9-amazoncorretto-17 AS builder
WORKDIR /app
COPY pom.xml .
# 先下载依赖（利用缓存层）
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

# 阶段2：运行（最终镜像只包含 JRE + jar）
FROM amazoncorretto:17-alpine
WORKDIR /app
# 只从 builder 阶段复制 jar，不包含 maven、源码等
COPY --from=builder /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

```dockerfile
# ===== Node.js 前端多阶段构建 =====
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

**效果**：Java 镜像从 ~800MB（带 Maven）→ ~180MB（纯 JRE + jar）

---

## 三、选择合适的基础镜像

```dockerfile
# 镜像大小对比（以 Java 17 为例）
openjdk:17              # ~470MB（不推荐，包含开发工具）
openjdk:17-jre          # ~320MB（仅运行时）
openjdk:17-jre-slim     # ~220MB（去除非必要包）
amazoncorretto:17-alpine # ~180MB（推荐：Alpine 基础，安全更新及时）
eclipse-temurin:17-jre-alpine # ~170MB（推荐：OpenJDK 官方发行版）

# 原则：
# 1. 使用具体版本标签，不用 :latest
# 2. 优先用 Alpine（基于 musl，更小）
# 3. 若需要 glibc（如某些 native 库），用 -slim
```

---

## 四、.dockerignore

```
# .dockerignore（类比 .gitignore）
.git
.gitignore
target/
*.log
*.md
.DS_Store
node_modules/
.env
.env.*
```

不配置 `.dockerignore` 会导致 `COPY . .` 把 `target/`、`node_modules/` 等无用目录发送给 Docker daemon，拖慢构建。

---

## 五、JVM 容器感知配置

```dockerfile
# JVM 默认按宿主机内存计算堆大小，容器中会超限 OOM
# 使用 UseContainerSupport（JDK 8u191+ / JDK 11+ 默认开启）
ENV JAVA_OPTS="\
  -XX:+UseContainerSupport \
  -XX:MaxRAMPercentage=75.0 \
  -XX:InitialRAMPercentage=50.0 \
  -XX:+UseG1GC \
  -XX:+ExitOnOutOfMemoryError"

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

---

## 六、非 root 用户运行

```dockerfile
# 安全实践：不以 root 运行
FROM amazoncorretto:17-alpine
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY --chown=appuser:appgroup target/*.jar app.jar
USER appuser   # 切换到非 root 用户
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

---

## 七、HEALTHCHECK

```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD curl -f http://localhost:8080/actuator/health || exit 1
```

---

## 完整示例

```dockerfile
# ===== 生产级 Spring Boot Dockerfile =====
FROM maven:3.9-amazoncorretto-17 AS builder
WORKDIR /build
COPY pom.xml .
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q && \
    java -Djarmode=layertools -jar target/*.jar extract

FROM amazoncorretto:17-alpine
RUN addgroup -S spring && adduser -S spring -G spring
WORKDIR /app
COPY --from=builder --chown=spring:spring /build/dependencies/ ./
COPY --from=builder --chown=spring:spring /build/spring-boot-loader/ ./
COPY --from=builder --chown=spring:spring /build/snapshot-dependencies/ ./
COPY --from=builder --chown=spring:spring /build/application/ ./
USER spring
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=5s \
  CMD wget -qO- http://localhost:8080/actuator/health || exit 1
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS org.springframework.boot.loader.JarLauncher"]
```

---

## 总结

| 实践 | 效果 |
|------|------|
| 多阶段构建 | 镜像体积减少 60%+ |
| 分层缓存优化 | 增量构建加速 |
| .dockerignore | 减少构建上下文 |
| Alpine 基础镜像 | 体积小、攻击面小 |
| 非 root 用户 | 安全加固 |
| HEALTHCHECK | 容器健康检测 |
