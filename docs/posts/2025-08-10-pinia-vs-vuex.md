# Pinia vs Vuex 状态管理选型与实践

<div class="post-meta">📅 2025-08-10 &nbsp;·&nbsp; 🏷️ <span class="tag">Vue</span> <span class="tag">Pinia</span> <span class="tag">Vuex</span></div>

## 一、Vuex 核心概念回顾

Vuex 是 Vue 2/3 时代的官方状态管理库，基于 **Flux 架构**，强制单向数据流。

### 1.1 Vuex 五大核心

```javascript
// store/index.js (Vuex 4)
import { createStore } from 'vuex'

export default createStore({
  // 1. state：响应式数据源（唯一数据来源）
  state: () => ({
    count: 0,
    userInfo: null,
    token: ''
  }),

  // 2. getters：派生状态（类似 computed）
  getters: {
    doubleCount: state => state.count * 2,
    isLogin: state => !!state.token,
    // 带参数的 getter
    getUserById: state => id => state.users.find(u => u.id === id)
  },

  // 3. mutations：同步修改 state 的唯一方式
  mutations: {
    INCREMENT(state, payload) {
      state.count += payload.amount ?? 1
    },
    SET_USER(state, user) {
      state.userInfo = user
    },
    SET_TOKEN(state, token) {
      state.token = token
    }
  },

  // 4. actions：处理异步逻辑，提交 mutation
  actions: {
    async login({ commit }, credentials) {
      const { data } = await api.login(credentials)
      commit('SET_TOKEN', data.token)
      commit('SET_USER', data.user)
    },
    async fetchCount({ commit, state }) {
      if (state.count > 0) return  // 避免重复请求
      const { data } = await api.getCount()
      commit('INCREMENT', { amount: data.count })
    }
  },

  // 5. modules：模块化拆分
  modules: {
    user: userModule,
    cart: cartModule
  }
})
```

### 1.2 Vuex 在组件中使用

```javascript
// Options API
export default {
  computed: {
    ...mapState(['count', 'userInfo']),
    ...mapGetters(['doubleCount', 'isLogin'])
  },
  methods: {
    ...mapMutations(['INCREMENT']),
    ...mapActions(['login'])
  }
}

// Composition API with useStore
import { useStore } from 'vuex'
import { computed } from 'vue'

export default {
  setup() {
    const store = useStore()
    const count = computed(() => store.state.count)
    const increment = () => store.commit('INCREMENT', { amount: 1 })
    return { count, increment }
  }
}
```

---

## 二、Pinia 核心概念

Pinia 是 Vue 官方推荐的新一代状态管理库（2022 年正式成为官方推荐），设计更简洁。

### 2.1 定义 Store

```javascript
// stores/counter.js
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'

// 方式一：Setup Store（推荐，类似 Composition API）
export const useCounterStore = defineStore('counter', () => {
  // state：普通 ref/reactive
  const count = ref(0)
  const userInfo = ref(null)

  // getters：computed
  const doubleCount = computed(() => count.value * 2)
  const isLogin = computed(() => !!userInfo.value)

  // actions：普通函数（可以是异步的）
  function increment(amount = 1) {
    count.value += amount
  }

  async function login(credentials) {
    const { data } = await api.login(credentials)
    userInfo.value = data.user
  }

  return { count, userInfo, doubleCount, isLogin, increment, login }
})

// 方式二：Options Store（类似 Vuex 风格）
export const useCartStore = defineStore('cart', {
  state: () => ({
    items: [],
    discount: 0
  }),
  getters: {
    totalPrice: state => state.items.reduce((sum, item) => sum + item.price, 0),
    finalPrice: state => state.totalPrice * (1 - state.discount)
  },
  actions: {
    addItem(item) {
      this.items.push(item)
    },
    async checkout() {
      await api.checkout(this.items)
      this.items = []
    }
  }
})
```

### 2.2 在组件中使用 Pinia

```vue
<script setup>
import { storeToRefs } from 'pinia'
import { useCounterStore } from '@/stores/counter'

const counterStore = useCounterStore()

// 解构需用 storeToRefs 保持响应性
const { count, doubleCount, isLogin } = storeToRefs(counterStore)
// actions 可以直接解构（函数不需要 storeToRefs）
const { increment, login } = counterStore
</script>

<template>
  <div>
    <p>Count: {{ count }}</p>
    <p>Double: {{ doubleCount }}</p>
    <button @click="increment()">+1</button>
    <button @click="counterStore.count++">直接修改（Pinia 允许）</button>
    <button @click="counterStore.$patch({ count: 10 })">批量修改</button>
  </div>
</template>
```

---

## 三、Pinia vs Vuex 全面对比

| 维度 | Vuex 4 | Pinia |
|------|--------|-------|
| **设计理念** | Flux 架构，严格单向数据流 | 轻量化，接近 Composition API |
| **TypeScript 支持** | 较差，需要大量类型声明 | 原生 TypeScript，类型推断完善 |
| **模块化** | 需要显式 modules，命名空间繁琐 | 每个 store 天然独立 |
| **Mutation** | 必须通过 mutation 修改 state | 无 mutation，直接修改 |
| **异步处理** | actions 处理异步 | actions 直接写异步，更自然 |
| **DevTools** | 完整支持 | 完整支持（时间旅行调试） |
| **Bundle 大小** | ~10 KB | ~1 KB（小 10 倍） |
| **直接修改 state** | ❌ 禁止（开发模式报错） | ✅ 允许（`store.x = val`） |
| **Vue 版本** | Vue 2 / Vue 3 | Vue 2.7+ / Vue 3 |
| **官方推荐** | Vue 2 时代官方 | Vue 3 时代官方推荐 |

---

## 四、Pinia 持久化（pinia-plugin-persistedstate）

```bash
npm install pinia-plugin-persistedstate
```

```javascript
// main.js
import { createPinia } from 'pinia'
import piniaPluginPersistedstate from 'pinia-plugin-persistedstate'

const pinia = createPinia()
pinia.use(piniaPluginPersistedstate)

createApp(App).use(pinia).mount('#app')
```

```javascript
// stores/user.js
export const useUserStore = defineStore('user', {
  state: () => ({
    token: '',
    userInfo: null,
    preferences: { theme: 'light', lang: 'zh' }
  }),
  persist: {
    // 持久化配置
    key: 'user-store',           // localStorage 的 key
    storage: localStorage,        // 存储介质（也可用 sessionStorage）
    paths: ['token', 'userInfo'], // 只持久化指定字段
    // serializer 可自定义序列化（如加密）
    serializer: {
      deserialize: (value) => JSON.parse(atob(value)),
      serialize: (value) => btoa(JSON.stringify(value))
    }
  }
})
```

---

## 五、多 Store 组合

Pinia 的多 store 可以互相引用，比 Vuex modules 更直观：

```javascript
// stores/auth.js
import { useUserStore } from './user'
import { usePermissionStore } from './permission'

export const useAuthStore = defineStore('auth', () => {
  const userStore = useUserStore()
  const permissionStore = usePermissionStore()

  async function login(credentials) {
    const { data } = await api.login(credentials)
    userStore.setToken(data.token)
    userStore.setUser(data.user)

    // 登录后拉取权限
    await permissionStore.fetchPermissions(data.user.roleId)
  }

  async function logout() {
    await api.logout()
    userStore.$reset()      // 重置到初始状态
    permissionStore.$reset()
    router.push('/login')
  }

  return { login, logout }
})
```

```javascript
// 组合多个 store 的数据
import { useUserStore } from '@/stores/user'
import { useCartStore } from '@/stores/cart'

// 在组件中同时使用
const userStore = useUserStore()
const cartStore = useCartStore()

// $subscribe：监听 state 变化
cartStore.$subscribe((mutation, state) => {
  console.log('Cart changed:', mutation.type, state.items.length)
})

// $onAction：监听 action 调用
cartStore.$onAction(({ name, args, after, onError }) => {
  console.log(`Action ${name} called`)
  after(result => console.log('Action result:', result))
  onError(error => console.error('Action error:', error))
})
```

---

## 六、TypeScript 支持对比

### Vuex 的 TypeScript 痛点

```typescript
// Vuex 需要大量手动类型声明
import { Store } from 'vuex'

interface State {
  count: number
  user: User | null
}

// 需要声明所有 mutation、action 类型
type Mutations = {
  INCREMENT: (state: State, payload: { amount: number }) => void
}

// 使用时类型推断缺失
const store = useStore()
store.state.count       // ✅ 有类型
store.commit('INCREMENT', ...)  // ❌ 字符串，无类型检查
store.dispatch('login', ...)    // ❌ 字符串，无类型检查
```

### Pinia 的 TypeScript 优势

```typescript
// Pinia 原生支持，零配置
export const useCounterStore = defineStore('counter', () => {
  const count = ref<number>(0)
  const user = ref<User | null>(null)

  async function fetchUser(id: string): Promise<void> {
    user.value = await api.getUser(id)
  }

  return { count, user, fetchUser }
})

// 使用时完整类型推断
const store = useCounterStore()
store.count         // 类型: number ✅
store.user          // 类型: User | null ✅
store.fetchUser('1')  // 参数类型检查 ✅

// 自定义类型（泛型 state）
interface UserState {
  list: User[]
  loading: boolean
  pagination: Pagination
}

export const useUserListStore = defineStore('userList', {
  state: (): UserState => ({
    list: [],
    loading: false,
    pagination: { page: 1, size: 10, total: 0 }
  })
})
```

---

## 七、从 Vuex 迁移到 Pinia

### 迁移对照表

| Vuex 概念 | Pinia 对应 |
|-----------|------------|
| `state` | `ref()` / `reactive()` |
| `getters` | `computed()` |
| `mutations` | 普通同步函数（或直接赋值） |
| `actions` | 普通 / async 函数 |
| `modules` | 多个独立 `defineStore` |
| `mapState` | `storeToRefs()` |
| `mapGetters` | `storeToRefs()` |
| `mapMutations` | 直接解构 store |
| `mapActions` | 直接解构 store |
| `store.commit()` | `store.xxx()` |
| `store.dispatch()` | `store.xxx()` |
| `store.getters.xxx` | `store.xxx` |

### 迁移示例

```javascript
// 迁移前：Vuex module
const userModule = {
  namespaced: true,
  state: () => ({ token: '', name: '' }),
  mutations: {
    SET_TOKEN(state, token) { state.token = token },
    SET_NAME(state, name) { state.name = name }
  },
  actions: {
    async fetchProfile({ commit }) {
      const { data } = await api.getProfile()
      commit('SET_NAME', data.name)
    }
  }
}

// 迁移后：Pinia store
export const useUserStore = defineStore('user', () => {
  const token = ref('')
  const name = ref('')

  // SET_TOKEN + SET_NAME 合并为直接赋值
  async function fetchProfile() {
    const { data } = await api.getProfile()
    name.value = data.name
  }

  return { token, name, fetchProfile }
})
```

---

## 八、最佳实践建议

```javascript
// 1. 按业务模块拆分 store（一个功能一个 store）
stores/
  user.ts        // 用户信息、认证
  permission.ts  // 路由权限
  app.ts         // 全局 UI 状态（loading、theme）
  cart.ts        // 购物车

// 2. 避免在 store 外部直接修改（保持可追踪性）
// ❌ 不推荐
userStore.token = 'xxx'

// ✅ 推荐：通过 action 修改，便于 DevTools 追踪
userStore.setToken('xxx')

// 3. 使用 $reset() 在退出/路由切换时重置状态
router.beforeEach(() => {
  if (!store.isLogin) {
    store.$reset()
  }
})
```

**选型建议**：新项目一律使用 Pinia，它更简洁、TypeScript 友好、体积小，是 Vue 官方推荐的标准方案。旧项目如无特殊原因可暂时保留 Vuex，迁移时参考上述对照表逐步替换。

---

## 九、总结与延伸

**核心要点**：
1. **Pinia 已成为 Vue 3 官方推荐的状态管理库**，相比 Vuex 4 更轻量（无 mutations）、TypeScript 原生支持更好、支持多个独立 Store
2. Pinia 的 `$patch` 批量更新比单独赋值性能更好（一次响应式触发 vs 多次），复杂更新推荐 `$patch(state => {...})`
3. **状态持久化**推荐 `pinia-plugin-persistedstate`，可精确指定持久化的字段和存储位置
4. 跨 Store 依赖直接 `import` 另一个 Store 的 `action` 即可，比 Vuex 的 `rootGetters` 简洁得多
5. 从 Vuex 迁移时，一个 module 对应一个 Pinia Store，`state/getters/mutations/actions` → `state/getters/actions`

**延伸阅读**：
- [Pinia 官方文档](https://pinia.vuejs.org/zh/) — 完整 API 参考与插件开发指南
- [pinia-plugin-persistedstate](https://github.com/prazdevs/pinia-plugin-persistedstate) — 状态持久化首选插件
- [Vue 3 Composition API](https://vuejs.org/guide/reusability/composables.html) — Pinia Setup Store 与 Composable 的配合
- [Vue Router 权限控制](./2024-10-05-vue-router-permission.md) — 权限 Store 在路由守卫中的实践
