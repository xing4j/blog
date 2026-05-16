---
name: blog-post-management
description: '博客文章管理工作流。新增、删除、修改博客文章时使用，确保所有关联位置联动更新，避免遗漏。触发词：新增文章、删除文章、修改文章、添加博客、移除博客、改标题、改文件名、更新链接。'
argument-hint: '操作类型：add / delete / update，以及文章标题或文件名'
---

# 博客文章管理

## 项目结构说明

```
docs/
├── index.html              # Docsify 配置（nameLink 等）
├── README.md               # 首页：近期文章表格 + 分类列表（含篇数）
├── _sidebar.md             # 侧边栏：近期文章列表 + 分类列表（含篇数）
└── posts/
    ├── README.md           # 归档页：文章总数 + 各分类文章列表
    └── <date>-<slug>.md    # 文章正文
```

## 联动位置速查表

| 操作 | 需修改的位置 |
|------|------------|
| 新增文章 | ① 创建文章文件 ② posts/README.md（分类列表 + 总数） ③ docs/README.md（近期表格 + 分类篇数） ④ _sidebar.md（近期列表 + 分类篇数） |
| 删除文章 | ① 删除文章文件 ② posts/README.md（分类列表 + 总数） ③ docs/README.md（近期表格 + 分类篇数） ④ _sidebar.md（近期列表 + 分类篇数） |
| 修改标题/slug | ① 重命名文件 ② 更新 posts/README.md 中的链接文字和路径 ③ 更新 docs/README.md 中的链接（如在近期表格中） ④ 更新 _sidebar.md 中的链接（如在近期列表中） |

---

## 操作一：新增文章

### 步骤

1. **创建文章文件**  
   路径：`docs/posts/<YYYY-MM-DD>-<slug>.md`  
   文件名格式：`2026-05-16-my-topic.md`

2. **更新 `docs/posts/README.md`**
   - 在对应分类的 `## <分类名>` 下按日期降序插入：
     ```markdown
     - [文章标题](posts/<date>-<slug>.md) — `<YYYY-MM-DD>`
     ```
   - 更新顶部总数：`` > 共 N 篇文章 ``

3. **更新 `docs/README.md`**
   - 在近期文章表格中按日期降序插入一行：
     ```markdown
     | <YYYY-MM-DD> | [文章标题](posts/<date>-<slug>.md) | <分类> |
     ```
   - 更新对应分类的篇数：`[<分类> (N 篇)](posts/#<anchor>)`

4. **更新 `docs/_sidebar.md`**
   - 在 `近期文章` 列表中按日期降序插入：
     ```markdown
     - [文章标题](posts/<date>-<slug>.md)
     ```
   - 更新对应分类的篇数：`[<分类> (N)](posts/#<anchor>)`

---

## 操作二：删除文章

### 步骤

1. **删除文章文件**  
   `docs/posts/<date>-<slug>.md`

2. **更新 `docs/posts/README.md`**
   - 删除对应分类下的那一行
   - 更新顶部总数：`` > 共 N 篇文章 ``

3. **更新 `docs/README.md`**
   - 如文章在近期表格中，删除对应行
   - 更新对应分类的篇数

4. **更新 `docs/_sidebar.md`**
   - 如文章在近期列表中，删除对应行
   - 更新对应分类的篇数

---

## 操作三：修改文章（标题 / 文件名 / 分类变更）

### 步骤

1. **仅改标题（文件名不变）**
   - 修改文章文件内的 `# 标题`
   - 全局搜索旧标题文字，更新所有出现位置的链接文字：
     - `docs/posts/README.md`
     - `docs/README.md`
     - `docs/_sidebar.md`

2. **改文件名 / slug（链接路径变更）**
   - 重命名文件
   - 全局搜索旧文件名（如 `2026-05-16-old-slug.md`），更新所有引用路径：
     - `docs/posts/README.md`
     - `docs/README.md`
     - `docs/_sidebar.md`

3. **改分类**
   - 在 `docs/posts/README.md` 中将条目从旧分类移到新分类
   - 更新 `docs/README.md` 近期表格中的分类列
   - 更新 `docs/README.md` 和 `docs/_sidebar.md` 中两个分类的篇数

---

## 篇数计算规则

- `docs/posts/README.md` 顶部：所有分类文章数之和
- `docs/README.md` 分类列表：格式 `(N 篇)`，N = 该分类实际条目数
- `docs/_sidebar.md` 分类列表：格式 `(N)`，N = 该分类实际条目数

> **两处格式不同**：README.md 用 `(N 篇)`，_sidebar.md 用 `(N)`，注意区分。

---

## 近期文章显示规则

- `docs/_sidebar.md` 近期列表：保留最新 **8 篇**
- `docs/README.md` 近期表格：保留最新 **8 行**
- 超出时删除最旧的一条

---

## 完成后

所有修改完成后，执行：
```bash
git add -A
git commit -m "<动作>: <简短描述>"
git push
```
