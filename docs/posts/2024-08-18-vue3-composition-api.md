# Vue 3 Composition API vs Options API 迁移指南

<div class="post-meta">📅 2024-08-18 &nbsp;·&nbsp; 🏷️ <span class="tag">Vue 3</span> <span class="tag">前端</span></div>

Vue 3 的 Composition API 带来了更灵活的逻辑组织方式。本文对比两种 API 风格的差异，并给出实用的迁移指南。

---

## 一、核心对比

```vue
<!-- Options API（Vue 2 / Vue 3 均支持） -->
<script>
export default {
  data() {
    return { count: 0, user: null }
  },
  computed: {
    doubleCount() { return this.count * 2 }
  },
  methods: {
    increment() { this.count++ },
    async fetchUser(id) {
      this.user = await getUserById(id)
    }
  },
  mounted() {
    this.fetchUser(1)
  }
}
</script>

<!-- Composition API（Vue 3 推荐） -->
<script setup>
import { ref, computed, onMounted } from 'vue'

const count = ref(0)
const user = ref(null)

const doubleCount = computed(() => count.value * 2)

const increment = () => count.value++

const fetchUser = async (id) => {
  user.value = await getUserById(id)
}

onMounted(() => fetchUser(1))
</script>
```

---

## 二、逻辑复用：Composable vs Mixin

Options API 的 Mixin 有命名冲突和来源不明确的问题；Composition API 通过 **Composable（组合函数）** 解决：

```javascript
// useUser.js —— 可复用的用户逻辑
import { ref, onMounted } from 'vue'
import { getUserById } from '@/api/user'

export function useUser(userId) {
  const user = ref(null)
  const loading = ref(false)
  const error = ref(null)

  const fetchUser = async () => {
    loading.value = true
    try {
      user.value = await getUserById(userId)
    } catch (e) {
      error.value = e.message
    } finally {
      loading.value = false
    }
  }

  onMounted(fetchUser)

  return { user, loading, error, fetchUser }
}

// 组件中使用（来源清晰，无命名冲突）
<script setup>
import { useUser } from '@/composables/useUser'
const { user, loading } = useUser(1)
</script>
```

---

## 三、生命周期对应关系

| Options API | Composition API |
|-------------|----------------|
| `beforeCreate` | `setup()` 本身 |
| `created` | `setup()` 本身 |
| `beforeMount` | `onBeforeMount` |
| `mounted` | `onMounted` |
| `beforeUpdate` | `onBeforeUpdate` |
| `updated` | `onUpdated` |
| `beforeUnmount` | `onBeforeUnmount` |
| `unmounted` | `onUnmounted` |
| `errorCaptured` | `onErrorCaptured` |

---

## 四、响应式 API 对应

```javascript
// data() → ref / reactive
const count = ref(0)           // 基本类型
const state = reactive({       // 对象类型
  name: 'Alice',
  age: 18
})

// computed → computed()
const fullName = computed(() => `${state.firstName} ${state.lastName}`)

// watch → watch / watchEffect
watch(count, (newVal, oldVal) => {
  console.log(`count: ${oldVal} → ${newVal}`)
})

watchEffect(() => {
  // 自动追踪依赖，无需声明监听目标
  console.log(`count is: ${count.value}`)
})
```

---

## 五、迁移步骤

```
Step 1：升级依赖
npm install vue@3 @vitejs/plugin-vue

Step 2：逐组件迁移（无需全量改造）
Vue 3 完全兼容 Options API，可渐进式迁移

Step 3：将 Mixin 改为 Composable
- 提取 data/methods 到 useXxx.js
- 用 provide/inject 替代全局 Mixin 注入

Step 4：使用 <script setup> 语法糖（最简洁）
```

---

## 六、`<script setup>` 语法糖特性

```vue
<script setup>
// 1. 导入的组件无需注册
import MyButton from './MyButton.vue'

// 2. defineProps / defineEmits 替代 props/emits 选项
const props = defineProps({
  title: String,
  count: { type: Number, default: 0 }
})

const emit = defineEmits(['update:count', 'submit'])

// 3. defineExpose 暴露给父组件调用的方法
defineExpose({ reset: () => { count.value = 0 } })

// 4. 顶层变量/函数自动在模板中可用
const message = ref('Hello')
</script>
```

---

## 总结

| 维度 | Options API | Composition API |
|------|-------------|----------------|
| **学习曲线** | 低（结构清晰）| 稍高（需理解响应式原理）|
| **逻辑复用** | Mixin（有缺陷）| Composable（推荐）|
| **TypeScript** | 支持但不友好 | 天然友好 |
| **代码组织** | 按选项（data/methods/computed）| 按功能聚合 |
| **适合场景** | 简单组件、团队迁移过渡 | 复杂组件、需要逻辑复用 |

新项目推荐全面使用 `<script setup>` + Composition API，已有 Vue 2 项目可渐进迁移。
