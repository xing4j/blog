<div class="post-meta">📅 2026-05-22 &nbsp;|&nbsp; 🏷️ AI</div>

# SDD、宪章与 Skill：AI 辅助开发的工程方法论全景

## 一、背景：从"使用 AI"到"工程化 AI"

绝大多数开发者使用 AI 编码助手的方式是：打开对话框，描述需求，复制代码。这本质上是把 AI 当作"高级搜索引擎"。

真正发挥 AI 价值的团队，正在做一件不同的事——**对 AI 的行为进行工程化约束**：给它注入项目上下文、规定它的工作流程、限制它不该做的操作。

本文系统梳理这一领域的核心概念：

- **SDD（Spec-Driven Development）**：一种以"规格说明书"为中心驱动 AI 实现代码的开发模式
- **宪章（Charter/Constitution）**：跨工具的"AI 行为准则"文件
- **Skill**：可复用的 AI 工作流封装单元

---

## 二、SDD：规格驱动开发

### 2.1 什么是 SDD

**Spec-Driven Development（规格驱动开发）** 是一种将"写规格说明书"提升为核心开发活动的工程方法论。其核心主张是：

> **先写清楚要做什么（Spec），再让 AI 规划怎么做（Plan），最后分解成可执行的任务（Tasks）。**

这与传统"边想边写代码"的方式有本质区别：它迫使开发者在动手前完成需求澄清，把模糊的需求转化为 AI 可以精确执行的结构化指令。

### 2.2 SDD 的工作流

```
需求/想法
   │
   ▼
Constitution（宪章）← 项目全局约束、架构原则、质量标准
   │
   ▼
Spec（规格说明）← 用户故事、验收标准、功能/非功能需求、边界条件
   │
   ▼
Plan（技术方案）← 架构决策、模块划分、技术选型、实现路径
   │
   ▼
Tasks（任务清单）← 可执行的原子任务，每条对应一段代码改动
   │
   ▼
Implement（AI 实现）← 逐任务驱动 Copilot/Claude 生成代码
```

### 2.3 GitHub Spec Kit

**GitHub Spec Kit** 是微软推出的、基于 SDD 模式的 GitHub Copilot 扩展工具，提供一套完整的 CLI + Copilot Chat 工作流。

**初始化：**
```bash
# 安装 specify CLI（需要 Node.js）
npm install -g @github/specify

# 在项目根目录初始化
specify init --here --ai copilot --script ps
```

初始化后会生成以下目录结构：

```
.specify/
  memory/
    constitution.md     ← 项目宪章（全局约束）
specs/
  <feature-name>/
    spec.md             ← 功能规格说明
    plan.md             ← 技术实现方案
    tasks.md            ← 任务清单
```

**在 Copilot Chat 中使用（`/speckit.*` 工作流）：**

| 命令 | 作用 |
|------|------|
| `/speckit.spec` | 根据需求描述生成 `spec.md` |
| `/speckit.plan` | 根据 spec 生成 `plan.md` |
| `/speckit.tasks` | 根据 spec + plan 生成 `tasks.md` |
| `/speckit.implement` | 逐任务驱动 AI 实现代码 |

> 参考：[Microsoft Learn — Spec-Driven Development with GitHub Spec Kit](https://learn.microsoft.com/training/modules/spec-driven-development-github-copilot-spec-kit/)

---

## 三、宪章（Charter / Constitution）

### 3.1 宪章是什么

宪章是一个**注入给 AI 的"项目上下文+行为规范"文件**，回答以下问题：

- 这个项目是什么，有哪些核心原则？
- 使用什么技术栈，有哪些禁止引入的依赖？
- 代码风格和命名规范是什么？
- 哪些操作绝对不允许（如删文件、force push）？
- 安全和权限方面有什么强制要求？

宪章不是给人看的文档，而是**给 AI 的系统提示（System Prompt）的持久化版本**。

### 3.2 各工具的宪章实现

不同 AI 编码工具以不同的文件和格式实现宪章，本质相同，但作用范围和触发时机有差异：

#### GitHub Copilot — `copilot-instructions.md`

```
位置：.github/copilot-instructions.md
      （或 AGENTS.md 放项目根目录）
```

**特点：**
- 每次 Copilot Chat 对话自动加载，**始终生效**
- 对 VS Code Agent 模式下所有代码操作实时约束
- 支持文件级指令（`.github/instructions/*.instructions.md`），可通过 `applyTo` 匹配特定文件类型

```markdown
# 项目宪章示例

## 技术栈约束
- 后端：Java 17 + Spring Boot 3.x，禁止引入 Hutool
- 前端：Vue 3 + TypeScript，禁止使用 Options API

## 禁止事项
- 不得执行 git push --force
- 不得删除任何数据库表或执行 DROP TABLE
- 不得跳过单元测试（--no-verify）
```

#### GitHub Spec Kit — `constitution.md`

```
位置：.specify/memory/constitution.md
```

**特点：**
- **仅在执行 `/speckit.*` 工作流时读取**
- 专门用于约束 Spec、Plan、Tasks 的生成质量
- 适合写：架构决策记录（ADR）、质量标准、领域术语表

```markdown
# Constitution

## 架构原则
- 遵循 DDD 分层：domain / application / infra / interface
- 禁止 domain 层依赖 infra 层

## 质量标准
- 所有公开 API 必须有 OpenAPI 注释
- 核心业务逻辑覆盖率 ≥ 80%
```

#### Claude Code — `CLAUDE.md`

```
位置：CLAUDE.md（项目根目录）
      也可放 ~/.claude/CLAUDE.md（用户级全局）
```

**特点：**
- Anthropic 官方 CLI 工具 [Claude Code](https://docs.anthropic.com/claude/docs/claude-code) 的项目记忆文件
- 每次启动 Claude Code 会话时自动读取
- 支持多级：根目录（项目级）→ 子目录（模块级）→ 用户目录（个人偏好）

```markdown
# CLAUDE.md

## 构建命令
- 构建：`mvn clean package -DskipTests`
- 运行测试：`mvn test`
- 启动应用：`java -jar target/app.jar`

## 代码规范
- 所有注释用中文
- Service 层方法必须有事务注解

## 禁止操作
- 不得修改 pom.xml 中的 Spring Boot 版本
```

#### Cursor — `.cursor/rules/`

```
位置：.cursor/rules/*.mdc     ← 推荐（支持 glob 匹配）
      .cursorrules            ← 旧版，全局生效
```

**特点：**
- `.mdc` 文件支持 YAML frontmatter，可用 `globs` 字段指定对哪些文件生效
- 支持"始终生效"和"按需加载"两种模式

```
---
description: Java 代码规范
globs: ["src/**/*.java"]
alwaysApply: true
---

## Java 规范
- 统一使用 R<T> 作为 API 返回类型
- 异常统一通过 BusinessException 抛出
```

#### Windsurf — `.windsurfrules`

```
位置：.windsurfrules（项目根目录）
```

**特点：**
- Codeium 的 Windsurf IDE 使用
- 格式简单，纯 Markdown 文本
- 全局对当前项目的所有 AI 交互生效

### 3.3 宪章横向对比

| 工具 | 文件位置 | 触发时机 | 主要用途 |
|------|---------|---------|---------|
| GitHub Copilot | `.github/copilot-instructions.md` | 每次对话自动加载 | 编码约束、禁止操作 |
| Spec Kit | `.specify/memory/constitution.md` | `/speckit.*` 命令执行时 | 规格生成约束 |
| Claude Code | `CLAUDE.md` | 会话启动时 | 项目记忆、构建命令 |
| Cursor | `.cursor/rules/*.mdc` | 按 glob 匹配或始终 | 文件级编码规范 |
| Windsurf | `.windsurfrules` | 每次对话自动加载 | 全局编码约束 |

> **结论**：这些文件本质相同，都是"注入给 AI 的上下文"。如果同时使用多种工具，维护多份宪章是合理的——它们服务于不同的工作流。

---

## 四、Skill：可复用的 AI 工作流单元

### 4.1 什么是 Skill

Skill 是 **VS Code GitHub Copilot Agent 定制体系**中的一种原语（Primitive）。它将"一个复杂的、多步骤的 AI 工作流"封装成一个可复用单元，包含：

- **`SKILL.md`**：工作流的执行说明（给 AI 读的步骤指南）
- **配套资产**：模板文件、脚本、示例等

一句话定义：**Skill = 领域专属的 SOP（Standard Operating Procedure）文件**。

### 4.2 Skill 的起源

Skill 来自 GitHub Copilot 在 VS Code 中逐步构建的"Agent 定制体系"。这套体系包含多种原语：

```
定制原语体系
├── copilot-instructions.md  → 全局始终生效的指令（宪章）
├── *.instructions.md        → 文件级按需指令
├── *.prompt.md              → 单次任务提示词
├── *.agent.md               → 自定义子 Agent
├── hooks/*.json             → 生命周期钩子（确定性行为）
└── skills/<name>/SKILL.md  → 可复用工作流（Skill）← 本节重点
```

Skill 解决的问题是：某些工作流**太复杂**（多步骤、需要配套文件），不适合写进全局宪章（会占用过多上下文），也不是一次性任务（不值得写成 prompt）。

### 4.3 Skill 的目录结构

```
.github/
  skills/
    <skill-name>/
      SKILL.md          ← 核心：工作流说明
      templates/        ← 可选：模板文件
      scripts/          ← 可选：辅助脚本
      examples/         ← 可选：示例文件
```

### 4.4 `SKILL.md` 的结构

```markdown
---
name: my-skill-name
description: "Use when: 用户要做 X 或 Y 任务时。包含关键词：keyword1, keyword2。"
---

# Skill 标题

## 步骤一：做什么

说明...

## 步骤二：做什么

说明...（可引用配套资产文件）

## 注意事项

...
```

**YAML frontmatter 关键字段：**

| 字段 | 说明 |
|------|------|
| `name` | 必须与目录名一致 |
| `description` | **最关键**：AI 根据此字段的语义相似度决定是否加载该 Skill |

### 4.5 Skill 的触发机制

Skill 不通过命令触发，而通过**语义匹配**触发：

```
用户说："帮我创建一个新的 MCP 服务"
        ↓
Copilot 扫描所有 Skill 的 description 字段
        ↓
发现 mcp-builder/SKILL.md 的 description 包含 "MCP server" 等语义
        ↓
自动读取 SKILL.md 内容，按步骤执行
```

**触发原则：**
- `description` 是唯一的"发现入口"，关键词必须写进去
- 描述要使用 `"Use when: ..."` 句式，明确列出触发场景
- 避免太通用的描述（会误触发），也避免太具体（会漏触发）

### 4.6 Skill vs 其他原语的选择

| 场景 | 推荐原语 |
|------|---------|
| 适用于项目所有代码的规范 | `copilot-instructions.md` |
| 针对特定文件类型的规范 | `*.instructions.md`（`applyTo` 匹配）|
| 一次性、有参数的任务 | `*.prompt.md` |
| 多步骤、有配套文件的复杂工作流 | `skills/<name>/SKILL.md` ✅ |
| 需要工具隔离或返回单一输出的子任务 | `*.agent.md` |
| 确定性地阻止或审批某类操作 | `hooks/*.json` |

### 4.7 一个实际 Skill 示例

以"创建 API 端点"为例：

**目录：**
```
.github/skills/create-api-endpoint/
  SKILL.md
  templates/
    Controller.java.tpl
    ServiceImpl.java.tpl
    Mapper.java.tpl
```

**SKILL.md：**
```markdown
---
name: create-api-endpoint
description: "Use when: 用户要新建一个 REST API 接口、新增 Controller、创建增删改查接口。
  关键词：新增接口、新建 API、Controller、CRUD。"
---

# 创建 API 端点工作流

## 步骤一：确认领域模块

询问用户：接口属于哪个领域模块（如 book、document、user）？

## 步骤二：生成分层文件

按 `domain/<module>/` 结构生成：
- `controller/XxxController.java`（参考 templates/Controller.java.tpl）
- `service/XxxService.java` + `impl/XxxServiceImpl.java`
- `mapper/XxxMapper.java` + 对应 XML
- `dto/XxxDTO.java`、`vo/XxxVO.java`

## 步骤三：注册路由

确认 URL 遵循 `/{module}/{action}` 格式，返回值统一使用 `R<T>`。

## 步骤四：生成单元测试

在 `src/test/` 下生成对应的 Service 层测试。
```

---

## 五、三者的关系与协作

```
                    ┌─────────────────────────┐
                    │  Charter / Instructions  │
                    │  copilot-instructions.md │  ← 全程约束所有 AI 行为
                    │      CLAUDE.md           │
                    └───────────┬─────────────┘
                                │ 提供全局上下文
                    ┌───────────▼─────────────┐
                    │     SDD Workflow         │
  用户提需求 ──────► │  Constitution → Spec     │  ← Spec Kit 驱动
                    │  → Plan → Tasks          │
                    └───────────┬─────────────┘
                                │ 生成任务
                    ┌───────────▼─────────────┐
                    │         Skills           │
                    │  create-api-endpoint     │  ← 逐任务按 Skill 执行
                    │  setup-module            │
                    │  ...                     │
                    └─────────────────────────┘
```

**最佳实践：**

1. **先建宪章**：在项目初始写好 `copilot-instructions.md`，定义不可逾越的红线
2. **用 SDD 规划**：新功能开发时，通过 Spec Kit 生成 spec → plan → tasks，而不是直接写代码
3. **用 Skill 加速**：将团队反复执行的工作流（如"新增 CRUD 模块"）封装成 Skill，一次定义，持续复用
4. **定期回顾宪章**：随项目演进更新约束规则，避免过时规则误导 AI

---

## 六、快速上手清单

```
□ 创建 .github/copilot-instructions.md（项目宪章）
□ 填写技术栈约束、代码规范、禁止操作
□ 安装 specify CLI，初始化 .specify/ 目录
□ 为下一个新功能跑一遍 SDD 流程（spec → plan → tasks）
□ 识别团队中重复 3 次以上的工作流，封装成 Skill
□ 如使用 Claude Code，维护项目根目录的 CLAUDE.md
```

---

## 七、参考资料

- [GitHub Copilot 定制化指令文档](https://docs.github.com/copilot/customizing-copilot/adding-repository-custom-instructions-for-github-copilot)
- [Microsoft Learn — Spec-Driven Development with GitHub Spec Kit](https://learn.microsoft.com/training/modules/spec-driven-development-github-copilot-spec-kit/)
- [Claude Code 官方文档 — CLAUDE.md](https://docs.anthropic.com/claude/docs/claude-code-memory)
- [Cursor Rules 文档](https://docs.cursor.com/context/rules-for-ai)
- [VS Code Copilot Agent Customization](https://code.visualstudio.com/docs/copilot/copilot-customization)
