# Hello World — 博客搭建记录

<div class="post-meta">📅 2026-05-15 &nbsp;·&nbsp; 🏷️ <span class="tag">docsify</span> <span class="tag">GitHub Pages</span></div>

终于搭建好了自己的博客，记录一下选型与搭建过程。

## 为什么选择 docsify + GitHub Pages

相比 Hugo、Hexo 等静态站点生成器，**docsify** 最大的特点是：

- **无需构建**：浏览器直接渲染 Markdown，无需生成 HTML 文件
- **部署零成本**：一个 `index.html` 即可运行，GitHub Pages 免费托管
- **维护轻量**：专注写 Markdown，其他全交给 docsify

两者结合，是个人博客的极简方案。

## 目录结构

```text
docs/
├── index.html        # docsify 入口（唯一需要的 HTML）
├── .nojekyll         # 禁用 Jekyll 处理
├── README.md         # 首页
├── _sidebar.md       # 侧边栏导航
├── _navbar.md        # 顶部导航
├── _coverpage.md     # 封面页
├── about.md          # 关于页
└── posts/            # 文章目录
    ├── README.md     # 文章归档
    └── *.md          # 各篇文章
```

## 使用的 docsify 插件

| 插件 | 用途 |
|------|------|
| `docsify/plugins/search` | 全文搜索 |
| `docsify-copy-code` | 代码块一键复制 |
| `docsify-pagination` | 上一篇/下一篇导航 |
| `prismjs` | 代码语法高亮 |

## 本地预览

```bash
# 安装 docsify-cli
npm i docsify-cli -g

# 启动本地服务
docsify serve docs
```

访问 `http://localhost:3000` 即可实时预览，保存 Markdown 后自动刷新。

## 写新文章

1. 在 `docs/posts/` 下新建 `YYYY-MM-DD-title.md`
2. 在 `docs/posts/README.md` 归档列表中添加链接
3. 在 `docs/_sidebar.md` 中添加侧边栏条目
4. `git push` 后 GitHub Actions 自动部署

## 参考

- [docsify 官方文档](https://docsify.js.org)
- [GitHub Pages 文档](https://docs.github.com/pages)
- [GitHub Actions 部署](https://docs.github.com/actions)
