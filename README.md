# Blog

Personal tech blog powered by **[docsify](https://docsify.js.org)** + **GitHub Pages**.

🌐 Visit: **https://xing4j.github.io/blog/**

## Local Preview

```bash
npm i docsify-cli -g
docsify serve docs
# open http://localhost:3000
```

## Write a New Post

1. Create `docs/posts/YYYY-MM-DD-title.md`
2. Add a link to `docs/posts/README.md` (archive)
3. Add an entry to `docs/_sidebar.md`
4. `git push` → GitHub Actions deploys automatically

## Structure

```
docs/
├── index.html         # docsify entry
├── .nojekyll          # disable Jekyll
├── README.md          # homepage
├── _sidebar.md        # sidebar nav
├── _navbar.md         # top nav
├── _coverpage.md      # cover page
├── about.md           # about page
└── posts/
    ├── README.md      # archive
    └── *.md           # blog posts
```
