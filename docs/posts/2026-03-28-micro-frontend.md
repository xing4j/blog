# 微前端方案对比：qiankun / Module Federation

<div class="post-meta">📅 2026-03-28 &nbsp;·&nbsp; 🏷️ <span class="tag">微前端</span> <span class="tag">前端架构</span></div>

微前端将大型前端应用拆分为独立部署的子应用，解决大型团队协作和技术栈差异问题。

---

## 一、微前端解决的问题

```
传统大型 SPA 的问题：
- 代码库庞大，构建缓慢（10分钟+）
- 多团队协作冲突，发布互相阻塞
- 历史包袱，无法局部升级技术栈
- 单点故障：一个模块报错，整体崩溃

微前端解决方案：
主应用（基座）
├── 子应用 A（React，团队A负责）
├── 子应用 B（Vue 2，遗留系统）
└── 子应用 C（Vue 3，团队C负责）
```

---

## 二、qiankun

基于 single-spa 封装，是国内使用最广泛的微前端方案。

### 主应用配置

```javascript
// main-app/src/main.js
import { registerMicroApps, start } from 'qiankun'

registerMicroApps([
  {
    name: 'user-center',
    entry: '//localhost:7101', // 子应用地址
    container: '#subapp-container',
    activeRule: '/user',
    props: {
      // 主应用传给子应用的数据
      token: () => store.getters.token,
      onMessage: (msg) => console.log('from child:', msg)
    }
  },
  {
    name: 'order-system',
    entry: '//localhost:7102',
    container: '#subapp-container',
    activeRule: '/order'
  }
])

start({ prefetch: 'all' }) // 预加载所有子应用
```

### 子应用改造（Vue 3）

```javascript
// sub-app/src/main.js
import { createApp } from 'vue'
import App from './App.vue'

let app = null

// qiankun 生命周期
export async function bootstrap() {
  console.log('子应用 bootstrap')
}

export async function mount(props) {
  const { container, token } = props
  app = createApp(App)
  app.config.globalProperties.$token = token
  app.mount(container ? container.querySelector('#app') : '#app')
}

export async function unmount() {
  app.unmount()
  app = null
}

// 独立运行（开发环境）
if (!window.__POWERED_BY_QIANKUN__) {
  createApp(App).mount('#app')
}
```

子应用 vite.config.js 配置：

```javascript
export default {
  server: {
    port: 7101,
    headers: {
      'Access-Control-Allow-Origin': '*' // 允许主应用跨域加载
    }
  },
  base: process.env.NODE_ENV === 'production'
    ? '//cdn.example.com/user-center/'
    : '/'
}
```

---

## 三、Module Federation（webpack 5）

原生 webpack 方案，共享模块无需 iframe 或沙箱。

```javascript
// 子应用 webpack.config.js
const { ModuleFederationPlugin } = require('@module-federation/enhanced')

module.exports = {
  plugins: [
    new ModuleFederationPlugin({
      name: 'userCenter',
      filename: 'remoteEntry.js',
      exposes: {
        './UserList': './src/components/UserList.vue',
        './useUser': './src/composables/useUser.js'
      },
      shared: {
        vue: { singleton: true, requiredVersion: '^3.0.0' }
      }
    })
  ]
}

// 主应用 webpack.config.js
new ModuleFederationPlugin({
  name: 'shell',
  remotes: {
    userCenter: 'userCenter@//localhost:7101/remoteEntry.js'
  },
  shared: { vue: { singleton: true } }
})

// 主应用中使用子应用组件
const UserList = defineAsyncComponent(
  () => import('userCenter/UserList')
)
```

---

## 四、方案对比

| 维度 | qiankun | Module Federation |
|------|---------|-----------------|
| **隔离机制** | JS沙箱（Proxy）+ CSS隔离 | 无隔离，共享同一作用域 |
| **通信方式** | props / 全局状态（initGlobalState）| 直接共享模块/状态 |
| **独立部署** | ✅ 完全独立 | ✅ 独立部署 |
| **技术栈限制** | 无限制（任意框架）| 需要 webpack 5 |
| **性能** | 子应用加载有开销 | 共享模块性能更好 |
| **适合场景** | 多团队/多技术栈聚合 | 同技术栈，组件/代码共享 |
| **学习成本** | 中等 | 中等 |

---

## 五、通信方案

```javascript
// qiankun 全局状态通信
import { initGlobalState } from 'qiankun'

// 主应用初始化
const actions = initGlobalState({ user: null, theme: 'light' })

actions.onGlobalStateChange((state, prev) => {
  console.log('state changed:', state)
})

// 子应用中
export async function mount(props) {
  props.onGlobalStateChange((state) => {
    // 监听变化
  })
  props.setGlobalState({ user: { name: 'Alice' } }) // 修改
}
```

---

## 总结

- **qiankun**：成熟稳定，适合大型多团队项目，有完整的沙箱隔离
- **Module Federation**：更轻量，适合组件/代码共享，同技术栈更友好
- **选型建议**：新项目优先 qiankun，若已是 webpack 5 + 同技术栈考虑 MF
