<div class="post-meta">📅 2026-05-22 &nbsp;|&nbsp; 🏷️ AI</div>

# AI 时代开发者必懂：大模型、智能体、Prompt 与 Vibe Coding 全解析

## 一、背景：一场正在发生的范式转移

2022 年末 ChatGPT 发布，AI 辅助编程助手在短短两年间渗透进每个开发团队。然而很多开发者对"大模型""智能体""Prompt Engineering""Vibe Coding"等术语仍停留在字面理解，无法真正用好这些工具。

本文系统梳理 AI 时代开发者必须掌握的核心术语，从底层原理到工程实践，帮你建立完整的认知地图。

---

## 二、大模型（LLM）：AI 时代的基础设施

### 2.1 什么是大模型

大语言模型（Large Language Model，LLM）是基于 **Transformer 架构**、在海量文本数据上预训练的神经网络。"大"体现在两个维度：参数量（数十亿到数万亿）和训练数据规模（TB 级别）。

它的核心任务只有一个：**预测下一个 Token**。所有的对话、代码生成、翻译、摘要，本质上都是这个预测任务的不同应用形式。

### 2.2 Transformer 架构简要

```
输入文本 -> Tokenizer -> Embedding -> [Transformer 块] × N -> 输出 Token 概率
                                          ^
                               Multi-Head Attention
                               Feed Forward Network
```

**注意力机制（Attention）** 是 Transformer 的核心：它让模型预测每个词时能关注输入序列中任意位置的词，从而捕捉长距离依赖关系。这正是 LLM 理解复杂语义的基础。

### 2.3 从预训练到可用助手：三个阶段

| 阶段 | 目标 | 典型技术 |
|------|------|----------|
| 预训练（Pre-training）| 学习语言通用知识 | 自监督学习（预测下一词）|
| 有监督微调（SFT）| 学习遵循指令 | 高质量指令-回复数据 |
| 强化学习对齐（RLHF）| 符合人类偏好与安全要求 | 人类评分 + PPO 算法 |

经过三阶段，原始语言模型变成"听话、有用、安全"的对话助手。

### 2.4 主流模型横向对比

| 模型 | 厂商 | 擅长领域 | 上下文窗口 |
|------|------|----------|-----------|
| GPT-4o | OpenAI | 综合能力、多模态 | 128K |
| Claude 3.7 Sonnet | Anthropic | 长文档、代码推理 | 200K |
| Gemini 2.5 Pro | Google | 复杂推理、多模态 | 1M |
| DeepSeek-R1 | DeepSeek | 数学、代码、性价比 | 64K |
| Qwen 2.5 | 阿里 | 中文理解、工具调用 | 128K |

> **上下文窗口（Context Window）**：模型单次能处理的最大 Token 数。128K ≈ 约 10 万汉字。超出后模型对早期内容的"记忆"会退化。

---

## 三、Prompt 与 Prompt Engineering

### 3.1 Prompt 的组成

Prompt 是发给大模型的完整输入，包含三个角色：

```
System: 你是一名资深 Java 后端工程师，回答时附代码示例，使用中文。
User:   解释 ConcurrentHashMap 的分段锁机制。
Assistant: [上一轮模型回复，多轮对话时携带]
```

- **System Prompt**：设定角色、风格、约束，对用户不可见，最先被模型读取
- **User Prompt**：具体指令
- **Assistant**：多轮历史，让模型保持上下文连贯

### 3.2 核心技巧

**① Zero-shot vs Few-shot**

```
# Zero-shot：直接描述任务
将以下 JSON 转为 Java POJO 类

# Few-shot：给出示例让模型"悟"格式
输入示例：{"name": "张三", "age": 20}
输出示例：
public class User {
    private String name;
    private int age;
}
现在处理：{"id": 1, "email": "a@b.com"}
```

Few-shot 在输出格式固定的任务中效果显著更好，示例让模型直接推断出规范。

**② Chain of Thought（思维链，CoT）**

强制模型"先推理再给结论"，显著提升推理类任务准确率：

```
# 普通 Prompt（容易出错）
一个服务每秒 1000 请求，单次耗时 200ms，需要几个线程？

# CoT Prompt
一个服务每秒 1000 请求，单次耗时 200ms，需要几个线程？
请一步步推导，给出计算过程和结论。
```

模型推导：并发数 = 1000 req/s × 0.2s = 200 → 需约 200 线程（含余量）。

**③ 结构化 Prompt 模板**

```
角色：你是一名 Code Reviewer
任务：审查以下 Java 代码
代码：
```java
// 代码粘贴在此
```
要求：
- 优先指出安全漏洞（注入、越权等）
- 指出性能问题
- 给出修改建议附修复代码
输出格式：按严重程度排序的 Markdown 列表
```

结构化后，模型输出格式稳定，且不容易遗漏要求。

### 3.3 常见反模式

| 反模式 | 问题 | 改进方向 |
|--------|------|----------|
| 描述太模糊："写个用户系统" | 输出方向不可控 | 指定技术栈、功能边界、输出格式 |
| 否定式约束："不要用 for 循环" | 模型容易忽略否定 | 改为正向描述："使用 Stream API" |
| 一次堆多个独立任务 | 后面的任务质量下降 | 拆分为多轮对话 |
| 无角色定位 | 回答风格和深度不稳定 | 先给 System Prompt 设定身份 |

---

## 四、智能体（AI Agent）：从对话到自主执行

### 4.1 为什么需要 Agent

单次对话的大模型有两个根本局限：

1. **知识截止**：训练数据有时间截止，不了解最新信息
2. **无法行动**：只能生成文字，不能执行代码、调用 API、操作文件

**AI Agent（智能体）** 通过赋予模型**工具调用能力（Function Calling）**，突破这两个限制，让模型从"回答者"变成"执行者"。

### 4.2 ReAct 框架：思考-行动-观察循环

ReAct（Reasoning + Acting）是目前最主流的 Agent 执行模式：

```
用户输入
   v
[思考] 需要哪些信息？用什么工具？
   v
[行动] 调用工具（搜索 / 执行代码 / 查数据库）
   v
[观察] 获取工具返回结果
   v
[思考] 结果够用了吗？还需要什么？
   v
…… 循环直到可以给出最终答案 ……
   v
最终回复
```

### 4.3 Function Calling 实战

主流模型都支持 Function Calling：开发者声明工具 schema，模型根据用户意图自动选择工具并生成调用参数。

```json
// 声明工具
{
  "name": "query_orders",
  "description": "查询指定用户的订单列表，支持按状态过滤",
  "parameters": {
    "type": "object",
    "properties": {
      "user_id": { "type": "string", "description": "用户 ID" },
      "status":  { "type": "string", "enum": ["pending", "paid", "shipped"] }
    },
    "required": ["user_id"]
  }
}
```

用户说"查一下用户 10086 的待付款订单"，模型自动生成：

```json
{ "user_id": "10086", "status": "pending" }
```

你的后端执行查询，把结果传回给模型，模型生成自然语言回复——全流程自动化。

### 4.4 Agent 的四个核心组件

```
+----------------------------------------+
|               AI Agent                 |
|                                        |
|  +---------+      +-----------------+  |
|  | Planning|      |     Memory      |  |
|  |Plan step|      | Short: chat hist|  |
|  |Pick tool|      | Long: vector DB |  |
|  +---------+      +-----------------+  |
|                                        |
|  +---------+      +-----------------+  |
|  |  Tools  |      |     Action      |  |
|  |Web Srch |      | Execute code    |  |
|  |Code Sbox|      | Call REST API   |  |
|  |Filesys. |      | Control browser |  |
|  +---------+      +-----------------+  |
+----------------------------------------+
```

---

## 五、Agent Skills 与 MCP

### 5.1 什么是 Skill

Skill（技能）是对 Agent 可执行能力的声明式封装。每个 Skill 包含三要素：

- **description**：告诉大模型"我能做什么"，是触发 Skill 的判断依据
- **argument-hint**：执行时需要哪些输入
- **实现内容**：具体的操作步骤或提示词模板

以 VS Code Copilot 的自定义 Skill 为例：

```markdown
---
name: security-review
description: '对 Java 代码进行 OWASP Top 10 安全审查，输出漏洞报告'
argument-hint: '文件路径或代码片段'
---

## 审查清单
1. SQL 注入（使用预编译语句？）
2. XSS（输入是否转义？）
3. 越权访问（鉴权是否在 Service 层做？）
4. 敏感信息泄露（日志/响应中是否有密码/token？）
```

模型读取 description 决定是否触发该 Skill，读取内容获取执行规范，从而产出结构一致的审查报告。

### 5.2 MCP：模型上下文协议

**MCP（Model Context Protocol）** 是 Anthropic 2024 年提出的开放标准，解决"每个 AI 工具都要单独集成每个数据源"的重复建设问题：

```
传统方式（M × N 适配）：
  Copilot ---> 数据库适配器
  Cursor  ---> Git 适配器      （每对组合都要单独开发）
  Claude  ---> Jira 适配器

MCP 方式（M + N 标准化）：
  Copilot -+
  Cursor  -+---> MCP Server ---> 数据库 / Git / Jira / 文件系统
  Claude  -+
```

MCP Server 暴露三类标准化能力：

- **Resources**：可读取的数据（文件、数据库记录）
- **Tools**：可执行的操作（运行命令、写入数据）
- **Prompts**：预定义的提示模板

任何支持 MCP 的客户端均可直接复用，一次接入多端使用。

---## 六、Vibe Coding：感应式编程

### 6.1 什么是 Vibe Coding

2025 年初，前特斯拉 AI 总监 **Andrej Karpathy** 造出了这个词：

> "You fully give in to the vibes, embrace exponentials, and forget that the code even exists."

核心思想：**不写代码，描述意图，让 AI 生成并迭代**。开发者的角色从"实现者"变为"指挥者"——你负责提需求、验结果，AI 负责写代码。

### 6.2 Vibe Coding vs 传统编码

| 维度 | 传统编码 | Vibe Coding |
|------|----------|-------------|
| 工作方式 | 逐行手写 | 描述需求，AI 生成 |
| 关注点 | 语法、实现细节 | 需求完整性、验证结果 |
| 调试方式 | 阅读理解代码逻辑 | 描述现象，AI 定位修复 |
| 代码所有权 | 完全理解每行 | 不一定理解具体实现 |
| 适用场景 | 核心系统、安全敏感模块 | 原型验证、脚本工具、胶水代码 |

### 6.3 实践技巧

**① 从高层描述开始，分轮细化**

```
# 第一轮：整体功能
实现一个 Spring Boot 接口，接收 CSV 文件，批量解析后插入数据库，返回成功/失败条数

# 第二轮：补充约束
加上：文件大小限制 10MB，CSV 格式校验，事务回滚，异步处理+进度查询接口
```

**② 先让 AI 写测试，再写实现**

AI 生成的代码容易遗漏边界 case，让它先输出测试用例，能有效暴露需求盲点。

**③ 不懂就问，理解行为边界**

```
这段代码做了什么？
如果并发 1000 请求会发生什么？
这里有没有潜在的线程安全问题？
```

你不需要读懂每行代码，但必须理解它的**输入、输出和边界行为**。

### 6.4 Vibe Coding 的风险

- **安全盲区**：AI 生成的代码可能含 SQL 注入、未校验的用户输入等漏洞
- **测试覆盖不足**：AI 倾向于只覆盖"正常路径"，异常路径易遗漏
- **技术债快速积累**：快速迭代产生的代码结构往往混乱，后期难维护

> **建议**：Vibe Coding 适合快速验证想法。涉及支付、权限、数据安全的核心逻辑，仍需人工严格审查。

---

## 七、SDD：规格驱动开发

### 7.1 什么是 SDD

**SDD（Specification-Driven Development，规格驱动开发）** 是以**结构化规格文档为核心**，驱动 AI 生成稳定、可预期代码的开发范式。

```
传统开发：需求文档 -> 开发者理解 -> 编码（信息损耗大）
TDD：     需求文档 -> 测试用例   -> 编码（让测试通过）
SDD：     需求文档 -> 规格文档   -> AI 生成代码 -> 人工验证
```

区别于 Vibe Coding 的随意描述，SDD 要求在写代码之前产出一份机器可理解的规格，作为 Prompt 的核心输入。

### 7.2 规格文档的要素

一份好的 Spec 应包含：

```markdown
## 功能：用户注册接口

### 接口定义
POST /api/users/register

### 输入参数
| 字段     | 类型   | 约束                         |
|----------|--------|------------------------------|
| username | String | 必填，4-20 字符，字母数字     |
| password | String | 必填，8-32 字符，含大小写+数字 |
| email    | String | 必填，合法 email 格式         |

### 业务规则
- username 全局唯一，重复返回 400 + 错误码 USER_EXISTS
- 密码 bcrypt(cost=12) 加密存储，禁止明文
- 注册成功后异步发送欢迎邮件

### 返回值
- 201：{ "userId": "xxx", "username": "xxx" }
- 400：{ "code": "USER_EXISTS", "message": "用户名已存在" }

### 测试用例
1. 正常注册 -> 201
2. 重复用户名 -> 400 USER_EXISTS
3. 密码不符合规则 -> 400 INVALID_PASSWORD
4. email 格式非法 -> 400 INVALID_EMAIL
```

这样的 Spec 作为 Prompt 输入，AI 能生成结构完整、边界清晰、测试覆盖充分的代码。

### 7.3 SDD vs Vibe Coding

| | Vibe Coding | SDD |
|--|-------------|-----|
| 规格化程度 | 低（口语描述） | 高（结构化文档）|
| 输出质量 | 不稳定 | 稳定可复现 |
| 适用阶段 | 快速原型探索 | 正式功能交付 |
| 可审计性 | 低 | 高（Spec 即文档）|

两者互补：Vibe Coding 用于**探索阶段**，SDD 用于**交付阶段**。

---

## 八、其他重要术语速查

### RAG：检索增强生成

**RAG（Retrieval-Augmented Generation）** 解决大模型"不了解你公司内部知识"的问题：

```
用户提问
   v
① 将问题向量化（Embedding）
② 在向量数据库中检索语义最相关的文档片段
③ 将文档片段 + 原始问题拼成 Prompt
④ 发给大模型生成回答
```

典型应用：企业知识库问答、代码库智能检索、AI 客服。

### Embedding：向量嵌入

将文本转为高维向量，使**语义相似的文本在向量空间中距离接近**：

```
"Java 线程池" 和 "Java concurrent executor"
  -> 向量余弦相似度 ≈ 0.92（语义相近，检索可以命中）

"Java 线程池" 和 "MySQL 索引"
  -> 向量余弦相似度 ≈ 0.31（语义不相关）
```

常用模型：OpenAI `text-embedding-3-small`、阿里 `text-embedding-v3`。

### Fine-tuning：微调

在预训练模型基础上，用特定领域数据继续训练，让模型"专精"某一领域：

| 方式 | 成本 | 效果 | 适用场景 |
|------|------|------|----------|
| 全量微调 | 极高（需 GPU 集群）| 最好 | 大厂定制基础模型 |
| LoRA 微调 | 中等（单卡可训）| 较好 | 企业私有化部署 |
| Prompt 调优 | 低（无需训练）| 一般 | 固定格式任务 |

### Temperature：随机性控制

控制模型输出的**多样性**：

- `temperature = 0`：确定性输出，每次相同 → 适合代码生成、数据提取
- `temperature = 0.7`：适度随机 → 适合对话、内容生成（默认值）
- `temperature > 1`：高度随机，容易跑偏 → 一般不推荐

### Hallucination：幻觉

模型生成**看似合理但实际错误**的内容，典型表现：

- 编造不存在的 Java API 方法名
- 引用不存在的论文或文档链接
- 自信地给出错误的推导逻辑

**应对策略**：要求模型标注不确定内容、用 RAG 补充真实知识、代码生成后执行测试验证。

### Token

大模型的基本处理单位，计费、限速、速度都以 Token 为单位：

- 1 个汉字 ≈ 1.5–2 个 Token
- 1 个英文单词 ≈ 1–1.5 个 Token
- 1K Token ≈ 750 个英文单词 ≈ 500 个汉字

---

## 九、总结与延伸

### 知识脉络图

```
大模型（LLM）
+-- 架构：Transformer + Attention 机制
+-- 训练：预训练 -> SFT -> RLHF
+-- 关键参数：上下文窗口、Temperature、Token

Prompt 工程
+-- 技巧：Zero-shot / Few-shot / CoT / 结构化模板
+-- 反模式：模糊描述、否定约束、任务堆砌

AI Agent（智能体）
+-- 本质：LLM + Function Calling + 循环推理
+-- 框架：ReAct（思考-行动-观察）
+-- 组件：规划 + 记忆 + 工具 + 行动

生态扩展
+-- Skill：Agent 能力的声明式封装
+-- MCP：工具集成的标准化协议
+-- RAG：外部知识检索增强

开发范式
+-- Vibe Coding：意图驱动，快速原型
+-- SDD：规格驱动，稳定交付
```

### 开发者行动建议

1. **立即上手**：选择 GitHub Copilot / Cursor / Claude 之一，用结构化 Prompt 完成一个真实小功能
2. **掌握 CoT**：在复杂推理类任务中加入"请一步步思考"，输出质量立竿见影
3. **尝试 SDD**：下次写新接口前，先花 20 分钟写规格文档，再让 AI 生成代码
4. **理解 Function Calling**：读一遍 OpenAI 或 Spring AI 的工具调用示例，这是理解 Agent 的最快路径

### 延伸阅读

- [Attention Is All You Need（2017）](https://arxiv.org/abs/1706.03762) — Transformer 原始论文，LLM 的理论起点
- [Prompt Engineering Guide](https://www.promptingguide.ai/zh) — 最系统的 Prompt 工程中文指南
- [ReAct: Synergizing Reasoning and Acting in LLMs](https://arxiv.org/abs/2210.03629) — ReAct Agent 原始论文
- [Model Context Protocol 官方文档](https://modelcontextprotocol.io/) — MCP 规范与 Server 开发指南
- [LangChain 官方文档](https://python.langchain.com/) — Python 生态 Agent 开发框架
- [Spring AI 官方文档](https://docs.spring.io/spring-ai/reference/) — Java/Spring 生态 AI 集成方案
- [LLM Visualization](https://bbycroft.net/llm) — 可视化理解 Transformer 内部结构
