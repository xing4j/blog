# qiankun 微前端框架：原理详解与实战指南

<div class="post-meta">📅 2026-05-17 &nbsp;·&nbsp; 🏷️ <span class="tag">Vue</span> <span class="tag">微前端</span></div>

微前端将微服务理念引入前端，让多个独立团队可以各自开发、部署自己的前端应用，再聚合到一个整体页面。qiankun 是目前国内最主流的微前端框架，基于 single-spa 封装，由蚂蚁集团开源。本文从原理到实战，全面介绍 qiankun 的使用。

---

## 一、微前端核心概念

### 1.1 为什么需要微前端

```
传统巨石应用的痛点：
- 代码库庞大，编译构建越来越慢
- 多团队协作冲突频繁，发布相互阻塞
- 技术栈统一要求高，无法渐进式升级
- 老旧代码难以重构，又不敢全量重写

微前端解决方案：
- 主应用（基座）：负责导航、公共布局、路由分发
- 子应用：独立仓库、独立开发、独立部署、独立运行
```

### 1.2 qiankun 的核心特性

- **技术栈无关**：React、Vue、Angular 子应用均可接入
- **样式隔离**：Shadow DOM 或 scoped CSS 防止样式污染
- **JS 沙箱**：子应用 JS 运行在独立沙箱，不污染全局变量
- **资源预加载**：空闲时预加载子应用，提升切换速度
- **父子通信**：提供 `props` 和全局状态两种通信方式

---

## 二、qiankun 工作原理

### 2.1 整体架构

```
┌─────────────────────────────────────────┐
│         Main Application (Shell)        │
│  ┌──────────┐  ┌──────────────────────┐ │
│  │  NavBar  │  │  Sub-app Mount Area  │ │
│  └──────────┘  │  ┌────────────────┐  │ │
│                │  │  Sub-App A(Vue)│  │ │
│                │  └────────────────┘  │ │
│                └──────────────────────┘ │
└─────────────────────────────────────────┘

路由变化 → qiankun 匹配激活规则 → 加载/卸载子应用
```

### 2.2 JS 沙箱机制

qiankun 提供三种沙箱实现：

```
1. SnapshotSandbox（快照沙箱）
   - 激活时：记录 window 快照
   - 卸载时：还原 window，保存差异
   - 缺点：不支持多实例并行

2. LegacySandbox（单例代理沙箱）
   - 用 Proxy 代理 window，记录新增/修改的属性
   - 卸载时还原，只操作有变化的属性，性能更好

3. ProxySandbox（多实例代理沙箱）✅ 推荐
   - 每个子应用有独立的 fakeWindow（Proxy）
   - 读写 fakeWindow，不影响真实 window
   - 支持多个子应用同时运行
```

### 2.3 样式隔离机制

```javascript
// 方式一：experimentalStyleIsolation（推荐）
// qiankun 会给子应用所有 CSS 选择器加上属性选择器前缀
// 子应用 .title { color: red } → div[data-qiankun="app-name"] .title { color: red }

// 方式二：strictStyleIsolation
// 使用 Shadow DOM 完全隔离，兼容性略差
registerMicroApps([{
  name: 'app1',
  sandbox: {
    strictStyleIsolation: false,        // Shadow DOM
    experimentalStyleIsolation: true,   // CSS 前缀（推荐）
  }
}])
```

---

## 三、主应用搭建

### 3.1 安装依赖

```bash
# 主应用安装 qiankun
npm install qiankun
```

### 3.2 注册并启动子应用

```javascript
// src/micro/index.js
import { registerMicroApps, start, initGlobalState } from 'qiankun'

// 初始化全局状态（用于主子应用通信）
const { onGlobalStateChange, setGlobalState } = initGlobalState({
  user: null,
  token: localStorage.getItem('token') || ''
})

// 注册子应用列表
registerMicroApps(
  [
    {
      name: 'app-vue',           // 子应用唯一标识，与子应用 package.json name 保持一致
      entry: '//localhost:8081', // 子应用入口地址（开发环境）
      container: '#sub-app',     // 挂载到主应用的哪个 DOM 节点
      activeRule: '/app-vue',    // 触发加载的路由前缀
      props: {                   // 向子应用传递的数据
        onGlobalStateChange,
        setGlobalState,
        routerBase: '/app-vue',
      }
    },
    {
      name: 'app-react',
      entry: '//localhost:8082',
      container: '#sub-app',
      activeRule: '/app-react',
      props: { onGlobalStateChange, setGlobalState }
    }
  ],
  {
    // 生命周期钩子
    beforeLoad:   [app => console.log('加载前', app.name)],
    beforeMount:  [app => console.log('挂载前', app.name)],
    afterMount:   [app => console.log('挂载后', app.name)],
    beforeUnmount:[app => console.log('卸载前', app.name)],
    afterUnmount: [app => console.log('卸载后', app.name)],
  }
)

// 启动 qiankun
start({
  prefetch: 'all',                    // 预加载：true/false/'all'/'popstate'
  sandbox: {
    experimentalStyleIsolation: true  // 启用样式隔离
  }
})
```

### 3.3 主应用 Vue Router 配置

```javascript
// src/router/index.js
import { createRouter, createWebHistory } from 'vue-router'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', redirect: '/home' },
    { path: '/home', component: () => import('@/views/Home.vue') },
    // 子应用路由通配符：所有 /app-vue/** 交给 qiankun 处理
    { path: '/app-vue/:pathMatch(.*)*', component: () => import('@/views/SubAppContainer.vue') },
    { path: '/app-react/:pathMatch(.*)*', component: () => import('@/views/SubAppContainer.vue') },
  ]
})

export default router
```

### 3.4 子应用容器组件

```vue
<!-- src/views/SubAppContainer.vue -->
<template>
  <!-- 子应用挂载节点，id 必须与 registerMicroApps 的 container 一致 -->
  <div id="sub-app" class="sub-app-wrapper"></div>
</template>

<style scoped>
.sub-app-wrapper {
  width: 100%;
  min-height: calc(100vh - 60px);  /* 减去导航高度 */
}
</style>
```

### 3.5 主应用入口引入微前端

```javascript
// src/main.js
import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import './micro/index'  // 引入 qiankun 配置，在 Vue 挂载前执行

createApp(App).use(router).mount('#app')
```

---

## 四、Vue 子应用改造

### 4.1 修改入口文件

```javascript
// src/main.js
import { createApp } from 'vue'
import App from './App.vue'
import { createRouter } from './router'

let app = null

// ——— qiankun 生命周期钩子 ———

// bootstrap：子应用初始化，只执行一次
export async function bootstrap() {
  console.log('app-vue bootstrapped')
}

// mount：每次激活时调用
export async function mount(props) {
  console.log('app-vue mounted, props:', props)

  // 从主应用接收参数
  const { container, routerBase, onGlobalStateChange, setGlobalState } = props

  // 监听全局状态变化
  onGlobalStateChange((state, prev) => {
    console.log('全局状态变化', state)
  })

  // 创建 router（传入 base，保证子应用路由带上前缀）
  const router = createRouter(routerBase || '/')

  app = createApp(App)
  app.use(router)

  // 挂载到 qiankun 指定的容器，避免和主应用 #app 冲突
  app.mount(container ? container.querySelector('#app') : '#app')
}

// unmount：每次卸载时调用
export async function unmount() {
  app.unmount()
  app = null
}

// ——— 独立运行（非 qiankun 环境）———
if (!window.__POWERED_BY_QIANKUN__) {
  const router = createRouter('/')
  createApp(App).use(router).mount('#app')
}
```

### 4.2 配置 publicPath

```javascript
// src/public-path.js（必须是第一个 import）
if (window.__POWERED_BY_QIANKUN__) {
  // 动态设置 webpack publicPath，确保子应用静态资源能正确加载
  __webpack_public_path__ = window.__INJECTED_PUBLIC_PATH_BY_QIANKUN__
}
```

```javascript
// src/main.js 第一行引入
import './public-path'
import { createApp } from 'vue'
// ...
```

### 4.3 修改 Router 支持动态 base

```javascript
// src/router/index.js
import { createRouter as _createRouter, createWebHistory } from 'vue-router'

const routes = [
  { path: '/', component: () => import('@/views/Home.vue') },
  { path: '/list', component: () => import('@/views/List.vue') },
  { path: '/detail/:id', component: () => import('@/views/Detail.vue') },
]

// 导出工厂函数，支持传入 base
export function createRouter(base = '/') {
  return _createRouter({
    history: createWebHistory(base),
    routes,
  })
}
```

### 4.4 修改 Webpack/Vite 配置

```javascript
// vue.config.js（webpack）
const { name } = require('./package.json')

module.exports = {
  devServer: {
    port: 8081,
    headers: {
      // 允许主应用跨域加载子应用资源
      'Access-Control-Allow-Origin': '*',
    }
  },
  configureWebpack: {
    output: {
      // 必须：将子应用打包为 UMD 格式，qiankun 才能识别生命周期函数
      library: `${name}-[name]`,
      libraryTarget: 'umd',
      chunkLoadingGlobal: `webpackJsonp_${name}`,
    }
  }
}
```

```javascript
// vite.config.js（Vite 子应用需要额外插件）
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import qiankun from 'vite-plugin-qiankun'
import { name } from './package.json'

export default defineConfig({
  plugins: [
    vue(),
    qiankun(name, { useDevMode: true })  // vite-plugin-qiankun
  ],
  server: {
    port: 8081,
    cors: true,  // 允许跨域
  }
})
```

---

## 五、主子应用通信

### 5.1 全局状态通信（推荐）

```javascript
// ——— 主应用：初始化并设置状态 ———
import { initGlobalState } from 'qiankun'

const { onGlobalStateChange, setGlobalState } = initGlobalState({
  user: { name: '张三', role: 'admin' },
  token: 'xxx'
})

// 主应用监听状态变化
onGlobalStateChange((state, prev) => {
  console.log('主应用收到状态变更', state)
}, true) // true = 立即触发一次

// 主应用更新状态（登录成功后）
function onLoginSuccess(userInfo) {
  setGlobalState({ user: userInfo, token: userInfo.token })
}
```

```javascript
// ——— 子应用：mount 时接收并使用 ———
export async function mount(props) {
  const { onGlobalStateChange, setGlobalState } = props

  // 监听状态
  onGlobalStateChange((state) => {
    store.commit('SET_USER', state.user)
  }, true)

  // 子应用修改全局状态（注意：只能修改已有字段，不能新增）
  function logout() {
    setGlobalState({ user: null, token: '' })
  }
}
```

### 5.2 Props 传递（简单数据/方法）

```javascript
// 主应用注册时传入
registerMicroApps([{
  name: 'app-vue',
  props: {
    basePath: '/app-vue',
    // 传递主应用方法给子应用调用
    openGlobalModal: (config) => mainAppStore.openModal(config),
    getToken: () => localStorage.getItem('token'),
  }
}])

// 子应用 mount 时接收
export async function mount({ openGlobalModal, getToken }) {
  app.provide('openGlobalModal', openGlobalModal)
  app.provide('getToken', getToken)
}
```

### 5.3 EventBus 通信

```javascript
// shared/event-bus.js（主子应用共用，通过 CDN 或 npm 包共享）
class EventBus {
  constructor() { this.events = {} }
  on(event, cb) {
    (this.events[event] = this.events[event] || []).push(cb)
  }
  emit(event, data) {
    (this.events[event] || []).forEach(cb => cb(data))
  }
  off(event, cb) {
    this.events[event] = (this.events[event] || []).filter(fn => fn !== cb)
  }
}

// 挂载到 window（主子应用都能访问）
window.__EVENT_BUS__ = window.__EVENT_BUS__ || new EventBus()
export default window.__EVENT_BUS__
```

---

## 六、生产环境部署

### 6.1 Nginx 配置

```nginx
# 主应用
server {
  listen 80;
  server_name example.com;
  root /usr/share/nginx/html/main;

  location / {
    try_files $uri $uri/ /index.html;
  }

  # 反向代理到子应用（开发环境用端口区分，生产用路径区分）
  location /app-vue/ {
    proxy_pass http://localhost:8081/;
    proxy_set_header Host $host;
    add_header Access-Control-Allow-Origin *;
  }

  location /app-react/ {
    proxy_pass http://localhost:8082/;
    proxy_set_header Host $host;
    add_header Access-Control-Allow-Origin *;
  }
}

# 子应用（独立部署）
server {
  listen 8081;
  root /usr/share/nginx/html/app-vue;

  location / {
    try_files $uri $uri/ /index.html;
    # 允许主应用跨域加载
    add_header Access-Control-Allow-Origin *;
  }
}
```

### 6.2 生产环境子应用 entry 配置

```javascript
// 根据环境区分子应用地址
const isDev = process.env.NODE_ENV === 'development'

registerMicroApps([
  {
    name: 'app-vue',
    // 开发：直接用 devServer 地址；生产：用相对路径或完整域名
    entry: isDev ? '//localhost:8081' : '/app-vue/',
    container: '#sub-app',
    activeRule: '/app-vue',
  }
])
```

---

## 七、常见问题与解决方案

### 7.1 子应用样式污染主应用

```javascript
// 启用样式隔离
start({
  sandbox: { experimentalStyleIsolation: true }
})

// 或者子应用使用 BEM 规范 + 统一前缀
// .app-vue__header { } 而非 .header { }
```

### 7.2 子应用静态资源 404

```javascript
// 原因：子应用打包后资源路径相对路径无法在主应用中正确解析
// 解决：配置 publicPath

// src/public-path.js
if (window.__POWERED_BY_QIANKUN__) {
  __webpack_public_path__ = window.__INJECTED_PUBLIC_PATH_BY_QIANKUN__
}
// 并在 main.js 第一行引入此文件
```

### 7.3 全局变量冲突

```javascript
// 原因：子应用污染了 window 上的全局变量
// 解决：启用 JS 沙箱（默认已开启 ProxySandbox）

// 若子应用使用了某些库会在 window 上挂载全局变量，
// 且需要在卸载后清除，可在 unmount 中手动清理
export async function unmount() {
  delete window.someGlobalLib
  app.unmount()
}
```

### 7.4 子应用路由与主应用路由冲突

```javascript
// 子应用 router base 要加上 activeRule 前缀
// 主应用 activeRule: '/app-vue'
// 子应用 router base: '/app-vue'

// 子应用内部跳转用相对路由（不带 /app-vue 前缀）
router.push('/list')       // 实际访问 /app-vue/list

// 跳转到其他子应用，用 history.pushState 或主应用提供的方法
window.history.pushState(null, '', '/app-react/home')
```

### 7.5 多个子应用并行渲染

```javascript
// qiankun 默认同一时刻只激活一个子应用
// 若需要同时渲染多个子应用，使用 loadMicroApp API

import { loadMicroApp } from 'qiankun'

// 手动加载（不依赖路由规则）
const microApp = loadMicroApp({
  name: 'app-widget',
  entry: '//localhost:8083',
  container: '#widget-container',
  props: { theme: 'dark' }
})

// 手动卸载
microApp.unmount()
```

---

## 八、完整项目结构

```
micro-frontend/
├── main-app/                 # 主应用（基座）
│   ├── src/
│   │   ├── micro/
│   │   │   └── index.js     # qiankun 注册配置
│   │   ├── router/
│   │   │   └── index.js     # 主应用路由
│   │   ├── views/
│   │   │   ├── Home.vue
│   │   │   └── SubAppContainer.vue  # 子应用容器
│   │   └── main.js
│   └── package.json
│
├── app-vue/                  # Vue 子应用
│   ├── src/
│   │   ├── public-path.js   # webpack publicPath 配置
│   │   ├── router/
│   │   │   └── index.js     # 支持动态 base 的 router
│   │   └── main.js          # 导出 bootstrap/mount/unmount
│   ├── vue.config.js        # UMD 打包配置
│   └── package.json
│
└── app-react/                # React 子应用
    ├── src/
    │   ├── public-path.js
    │   └── index.js         # 导出 bootstrap/mount/unmount
    ├── config-overrides.js  # UMD 打包配置
    └── package.json
```

---

## 九、总结

| 场景 | 方案 |
|------|------|
| 路由驱动激活子应用 | `registerMicroApps` + `activeRule` |
| 手动按需加载子应用 | `loadMicroApp` |
| 主→子传参 | `props` |
| 主子双向通信 | `initGlobalState` |
| 样式隔离 | `experimentalStyleIsolation: true` |
| JS 隔离 | 默认 ProxySandbox（自动开启） |
| 静态资源正确加载 | `public-path.js` + UMD 打包 |
| 多子应用同屏 | `loadMicroApp` 多次调用 |

qiankun 的核心价值在于**渐进式迁移**和**团队自治**：可以先将新功能作为子应用接入，逐步将老系统模块迁移为独立子应用，而无需一次性重写整个系统。
