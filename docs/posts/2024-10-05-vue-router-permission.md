# Vue Router 路由守卫与动态路由权限方案

<div class="post-meta">📅 2024-10-05 &nbsp;·&nbsp; 🏷️ <span class="tag">Vue</span> <span class="tag">前端</span></div>

前端权限控制是中后台系统的核心需求。本文讲解 Vue Router 守卫机制，并给出基于后端动态路由的完整权限方案实现。

---

## 一、路由守卫类型

```javascript
const router = createRouter({ ... })

// 1. 全局前置守卫（最常用）
router.beforeEach((to, from, next) => {
  // to: 即将进入的路由
  // from: 当前路由
  // next(): 放行 | next('/login'): 重定向 | next(false): 中断
})

// 2. 全局后置守卫（无 next，常用于统计、关闭 loading）
router.afterEach((to, from) => {
  document.title = to.meta.title || 'My App'
  NProgress.done()
})

// 3. 路由独享守卫（写在路由配置中）
{
  path: '/admin',
  beforeEnter: (to, from, next) => { ... }
}

// 4. 组件内守卫（在组件中定义）
onBeforeRouteLeave((to, from) => {
  if (hasUnsavedChanges.value) {
    return confirm('有未保存的内容，确定离开？')
  }
})
```

---

## 二、完整权限控制方案

### 架构设计

```
用户登录
  ↓
获取 token + 用户信息（含权限）
  ↓
调用后端 /api/user/menus 获取菜单路由
  ↓
前端动态注册路由（router.addRoute）
  ↓
渲染侧边栏菜单
```

### 路由配置（静态路由 + 动态路由分离）

```javascript
// router/index.js
import { createRouter } from 'vue-router'

// 基础路由（所有人可访问）
export const constantRoutes = [
  { path: '/login', component: () => import('@/views/Login.vue') },
  { path: '/403', component: () => import('@/views/403.vue') },
  { path: '/', redirect: '/dashboard' }
]

// 动态路由（从后端获取，按权限加载）
export const asyncRoutes = []

const router = createRouter({
  history: createWebHistory(),
  routes: constantRoutes
})

export default router
```

### Pinia 权限 Store

```javascript
// stores/permission.js
import { defineStore } from 'pinia'
import { getUserMenus } from '@/api/user'
import router from '@/router'

export const usePermissionStore = defineStore('permission', {
  state: () => ({
    routes: [],          // 当前用户可访问的完整路由
    dynamicRoutes: []    // 动态加载的路由
  }),

  actions: {
    async generateRoutes(userInfo) {
      // 1. 从后端获取用户菜单
      const menus = await getUserMenus()

      // 2. 将后端菜单数据转换为 Vue Router 路由格式
      const accessRoutes = filterAsyncRoutes(menus)

      // 3. 动态注册路由
      accessRoutes.forEach(route => router.addRoute(route))

      // 4. 添加 404 兜底路由（必须最后添加）
      router.addRoute({ path: '/:pathMatch(.*)*', component: () => import('@/views/404.vue') })

      this.dynamicRoutes = accessRoutes
      this.routes = accessRoutes
    },

    resetRoutes() {
      // 退出登录时重置路由
      this.dynamicRoutes.forEach(route => router.removeRoute(route.name))
      this.routes = []
    }
  }
})

// 递归转换后端菜单为路由格式
function filterAsyncRoutes(menus) {
  return menus.map(menu => ({
    path: menu.path,
    name: menu.name,
    component: loadComponent(menu.component),
    meta: { title: menu.title, icon: menu.icon, permission: menu.permission },
    children: menu.children ? filterAsyncRoutes(menu.children) : []
  }))
}

// 动态加载组件（Vue 3 + Vite）
function loadComponent(component) {
  const modules = import.meta.glob('@/views/**/*.vue')
  return modules[`/src/views/${component}.vue`]
}
```

### 全局前置守卫

```javascript
// permission.js（路由守卫主文件）
import router from './router'
import { useUserStore } from '@/stores/user'
import { usePermissionStore } from '@/stores/permission'
import NProgress from 'nprogress'

const whiteList = ['/login', '/403']

router.beforeEach(async (to, from, next) => {
  NProgress.start()

  const userStore = useUserStore()
  const token = userStore.token

  if (token) {
    if (to.path === '/login') {
      next('/') // 已登录跳转首页
    } else {
      // 判断是否已加载用户信息（刷新后需重新加载）
      if (!userStore.userInfo) {
        try {
          await userStore.getUserInfo()
          const permissionStore = usePermissionStore()
          await permissionStore.generateRoutes()
          next({ ...to, replace: true }) // 重新进入（路由已注册）
        } catch (e) {
          userStore.logout()
          next(`/login?redirect=${to.path}`)
        }
      } else {
        next()
      }
    }
  } else {
    // 未登录
    if (whiteList.includes(to.path)) {
      next()
    } else {
      next(`/login?redirect=${to.path}`)
    }
  }
})

router.afterEach(() => NProgress.done())
```

---

## 三、按钮级权限控制

### 自定义指令

```javascript
// directives/permission.js
export const permissionDirective = {
  mounted(el, binding) {
    const { value } = binding
    const userStore = useUserStore()
    const permissions = userStore.permissions // ['user:add', 'user:edit']

    if (value && !permissions.includes(value)) {
      el.parentNode?.removeChild(el)
    }
  }
}

// main.js 注册
app.directive('permission', permissionDirective)
```

```vue
<!-- 模板中使用 -->
<el-button v-permission="'user:add'" type="primary">新增用户</el-button>
<el-button v-permission="'user:delete'" type="danger">删除</el-button>
```

### Composable 方式

```javascript
// composables/usePermission.js
export function usePermission() {
  const userStore = useUserStore()
  const hasPermission = (permission) => userStore.permissions.includes(permission)
  return { hasPermission }
}

// 组件中
const { hasPermission } = usePermission()
// <el-button v-if="hasPermission('user:add')">新增</el-button>
```

---

## 总结

| 实现环节 | 方案 |
|---------|------|
| 路由权限 | 全局前置守卫 + `router.addRoute` 动态注册 |
| 菜单数据 | 后端接口返回，前端递归转换 |
| 刷新问题 | `beforeEach` 检测 userInfo，无则重新加载 |
| 按钮权限 | 自定义指令 `v-permission` 或 `v-if` + composable |
| 退出重置 | `router.removeRoute` 清除动态路由 |

**延伸阅读**：
- [Vue Router 官方文档](https://router.vuejs.org/zh/) — 导航守卫、路由懒加载、滚动行为完整 API
- [Pinia vs Vuex 状态管理](./2025-08-10-pinia-vs-vuex.md) — 权限 Store 推荐用 Pinia 实现
- RBAC 权限模型设计 — 角色→权限→资源三级模型，适合中后台系统的权限体系
- [Vite 构建原理](./2025-09-21-vite-vs-webpack.md) — 前端工程化与权限路由的配合
