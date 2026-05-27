# CI/CD 流水线：GitHub Actions 实战

<div class="post-meta">📅 2025-12-13 &nbsp;·&nbsp; 🏷️ <span class="tag">CI/CD</span> <span class="tag">DevOps</span></div>

CI/CD 让代码提交到上线的过程自动化。本文以 GitHub Actions 为例，实现 Spring Boot 的完整流水线。

---

## 一、CI/CD 流程概览

```
开发者 git push
    v
GitHub Actions 触发
    v CI 阶段
    +-- 代码检出
    +-- 编译 & 单元测试
    +-- 代码质量扫描（SonarQube）
    +-- 构建 Docker 镜像并推送
    v CD 阶段
    +-- 部署到测试环境
    +-- 集成测试
    +-- 审批后部署到生产环境
```

---

## 二、基础 CI 流水线

```yaml
# .github/workflows/ci.yml
name: CI Pipeline

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'
          cache: 'maven'        # 自动缓存 Maven 依赖

      - name: Build and test
        run: mvn clean verify -q

      - name: Upload test report
        if: always()            # 即使测试失败也上传
        uses: actions/upload-artifact@v4
        with:
          name: test-report
          path: target/surefire-reports/
```

---

## 三、Docker 构建 + 推送

```yaml
  docker-build:
    needs: build-and-test       # 依赖上一个 job
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'  # 只有 main 分支执行

    steps:
      - uses: actions/checkout@v4

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'
          cache: 'maven'

      - name: Build jar
        run: mvn package -DskipTests -q

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Docker Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ secrets.REGISTRY_URL }}
          username: ${{ secrets.REGISTRY_USERNAME }}
          password: ${{ secrets.REGISTRY_PASSWORD }}

      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ secrets.REGISTRY_URL }}/myapp:latest
            ${{ secrets.REGISTRY_URL }}/myapp:${{ github.sha }}
          cache-from: type=gha   # GitHub Actions 缓存构建层
          cache-to: type=gha,mode=max
```

---

## 四、自动部署到 K8s

```yaml
  deploy-staging:
    needs: docker-build
    runs-on: ubuntu-latest
    environment: staging        # 可配置审批规则

    steps:
      - uses: actions/checkout@v4

      - name: Set up kubectl
        uses: azure/setup-kubectl@v3

      - name: Configure kubeconfig
        run: |
          echo "${{ secrets.KUBECONFIG }}" | base64 -d > kubeconfig.yaml
          export KUBECONFIG=kubeconfig.yaml

      - name: Update deployment image
        run: |
          kubectl set image deploy/myapp \
            myapp=${{ secrets.REGISTRY_URL }}/myapp:${{ github.sha }} \
            -n staging
          kubectl rollout status deploy/myapp -n staging --timeout=300s
```

---

## 五、矩阵测试

```yaml
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        java-version: [17, 21]  # 同时测试多个 JDK 版本

    steps:
      - uses: actions/checkout@v4
      - name: Set up JDK ${{ matrix.java-version }}
        uses: actions/setup-java@v4
        with:
          java-version: ${{ matrix.java-version }}
          distribution: 'temurin'
      - run: mvn test
```

---

## 六、代码质量检查

```yaml
      - name: SonarQube Scan
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
          SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}
        run: |
          mvn sonar:sonar \
            -Dsonar.projectKey=myapp \
            -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml

      - name: Check SonarQube Quality Gate
        uses: sonarsource/sonarqube-quality-gate-action@v1.1.0
        timeout-minutes: 5
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
```

---

## 七、定时任务与手动触发

```yaml
on:
  # 定时触发（每天凌晨 2 点执行集成测试）
  schedule:
    - cron: '0 2 * * *'
  # 手动触发（可传参数）
  workflow_dispatch:
    inputs:
      environment:
        description: '部署环境'
        required: true
        default: 'staging'
        type: choice
        options: [staging, production]
```

---

## 总结

| 功能 | Actions 用法 |
|------|-------------|
| 缓存依赖 | `actions/setup-java` 的 `cache: maven` |
| 镜像推送 | `docker/build-push-action` |
| 多版本测试 | `strategy.matrix` |
| 环境审批 | `environment: production`（在 Settings 配置 Reviewer）|
| 敏感信息 | Settings → Secrets and variables → Actions |

**延伸阅读**：
- [GitHub Actions 文档](https://docs.github.com/cn/actions) — 完整的 workflow 语法和触发事件
- [K8s 生产部署](./2025-11-06-k8s-deployment.md) — CI/CD 目标环境的 K8s 配置
- [Dockerfile 最佳实践](./2025-06-21-dockerfile-best-practices.md) — 流水线中 Docker 镜像构建优化
- GitLab CI vs GitHub Actions vs Jenkins — 三大 CI/CD 工具的选型对比
