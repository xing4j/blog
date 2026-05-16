# TypeScript 在 Vue 项目中的工程化实践

<div class="post-meta">📅 2026-02-10 &nbsp;·&nbsp; 🏷️ <span class="tag">TypeScript</span> <span class="tag">Vue</span></div>

TypeScript 为 Vue 项目带来类型安全和更好的 IDE 支持。本文总结 TS 在 Vue 3 项目中的核心配置和常见实践。

---

## 一、tsconfig.json 关键配置

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "jsx": "preserve",
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "baseUrl": ".",
    "paths": { "@/*": ["src/*"] },
    "types": ["vite/client"],
    "noUnusedLocals": true,
    "noUnusedParameters": true
  },
  "include": ["src/**/*.ts", "src/**/*.tsx", "src/**/*.vue"]
}
```

---

## 二、defineProps 类型定义

```vue
<script setup lang="ts">
// 方式1：运行时声明（基础）
const props = defineProps({
  title: { type: String, required: true },
  count: { type: Number, default: 0 }
})

// 方式2：类型声明（推荐）
interface Props {
  title: string
  count?: number
  items: string[]
  callback?: (id: number) => void
}
const props = defineProps<Props>()

// 方式3：类型声明 + 默认值（withDefaults）
const props = withDefaults(defineProps<Props>(), {
  count: 0,
  items: () => []
})
</script>
```

---

## 三、defineEmits 类型

```vue
<script setup lang="ts">
const emit = defineEmits<{
  'update:modelValue': [value: string]
  'submit': [data: FormData]
  'close': []
}>()

emit('update:modelValue', 'newValue')
emit('submit', formData)
</script>
```

---

## 四、Ref 和 Reactive 类型

```typescript
import { ref, reactive, computed, Ref } from 'vue'

// ref 自动推断
const count = ref(0)              // Ref<number>
const name = ref<string | null>(null) // 需要 null 时显式声明

// reactive 类型
interface User { id: number; name: string }
const user = reactive<User>({ id: 1, name: 'Alice' })

// computed 类型
const double = computed<number>(() => count.value * 2)

// 函数参数中的 Ref 类型
function useCount(initialCount: Ref<number>) {
  return computed(() => initialCount.value * 2)
}
```

---

## 五、API 接口类型定义

```typescript
// types/api.ts —— 统一类型定义
export interface ApiResponse<T> {
  code: number
  message: string
  data: T
}

export interface PageResult<T> {
  records: T[]
  total: number
  current: number
  size: number
}

// api/user.ts
export interface User {
  id: number
  username: string
  email: string
  roles: string[]
  createdAt: string
}

export const getUserList = (params: {
  page: number
  size: number
  keyword?: string
}): Promise<ApiResponse<PageResult<User>>> => {
  return request.get('/user/list', { params })
}
```

---

## 六、Pinia Store 类型

```typescript
// stores/user.ts
import { defineStore } from 'pinia'

interface UserState {
  token: string | null
  userInfo: User | null
  permissions: string[]
}

export const useUserStore = defineStore('user', {
  state: (): UserState => ({
    token: localStorage.getItem('token'),
    userInfo: null,
    permissions: []
  }),
  getters: {
    isLoggedIn: (state): boolean => !!state.token,
    hasPermission: (state) => (permission: string): boolean =>
      state.permissions.includes(permission)
  },
  actions: {
    async login(username: string, password: string) {
      const { data } = await authApi.login({ username, password })
      this.token = data.token
    }
  }
})
```

---

## 七、路由 meta 类型扩展

```typescript
// types/router.d.ts —— 扩展 Vue Router 的 RouteMeta
import 'vue-router'
declare module 'vue-router' {
  interface RouteMeta {
    title?: string
    requiresAuth?: boolean
    roles?: string[]
    icon?: string
    keepAlive?: boolean
  }
}

// 路由配置中使用
{
  path: '/user',
  meta: { title: '用户管理', requiresAuth: true, roles: ['admin'] }
}
```

---

## 总结

| 场景 | 推荐做法 |
|------|---------|
| Props 定义 | `defineProps<Interface>()` + `withDefaults` |
| API 类型 | 泛型 `ApiResponse<T>` 统一包装 |
| 响应式变量 | 让 TS 自动推断，复杂类型显式声明 |
| 路由 meta | `declare module 'vue-router'` 扩展 RouteMeta |
| 全局类型 | 放在 `src/types/` 目录，tsconfig 自动包含 |
