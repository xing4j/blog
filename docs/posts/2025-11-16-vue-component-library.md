# Vue 组件库二次封装最佳实践（Element Plus）

<div class="post-meta">📅 2025-11-16 &nbsp;·&nbsp; 🏷️ <span class="tag">Vue</span> <span class="tag">Element Plus</span> <span class="tag">组件</span></div>

## 一、为何需要二次封装

直接使用 Element Plus 往往面临以下问题：

| 问题 | 描述 | 解决方案 |
|------|------|----------|
| 重复配置 | 每个表格都写分页、loading、空态 | 封装 ProTable |
| 样式不统一 | 不同开发者的间距/颜色有偏差 | 统一 CSS 变量 |
| 升级风险 | Element Plus 大版本变化影响所有组件 | 统一封装层隔离 |
| 业务逻辑散落 | 权限校验、接口请求混在组件里 | 封装到业务组件 |
| 配置繁琐 | Form 校验规则、columns 配置重复 | SearchForm 组件 |

---

## 二、全局配置（ElConfigProvider）

`ElConfigProvider` 是 Element Plus 提供的全局配置组件，在应用顶层使用：

```vue
<!-- App.vue -->
<template>
  <el-config-provider
    :locale="zhCn"
    :size="globalSize"
    :z-index="3000"
    :button="{ autoInsertSpace: false }"
  >
    <router-view />
  </el-config-provider>
</template>

<script setup lang="ts">
import zhCn from 'element-plus/es/locale/lang/zh-cn'
import { ref } from 'vue'

const globalSize = ref<'default' | 'small' | 'large'>('default')
</script>
```

```typescript
// 通过 Pinia 动态控制全局配置
// stores/app.ts
export const useAppStore = defineStore('app', () => {
  const componentSize = ref<'default' | 'small' | 'large'>('default')
  const locale = ref(zhCn)

  function setSize(size: 'default' | 'small' | 'large') {
    componentSize.value = size
  }

  return { componentSize, locale, setSize }
})
```

---

## 三、基于 $attrs 透传封装组件

Vue 3 的 `$attrs` 自动透传是封装组件的关键能力，可以将未声明的 props/events 全部传递给子组件。

### 3.1 封装 ElInput

```vue
<!-- components/base/BaseInput.vue -->
<template>
  <el-input
    v-bind="$attrs"
    :model-value="modelValue"
    :clearable="clearable"
    :placeholder="placeholder"
    @update:model-value="$emit('update:modelValue', $event)"
    @input="handleInput"
  >
    <!-- 透传所有插槽 -->
    <template v-for="(_, name) in $slots" #[name]="slotProps">
      <slot :name="name" v-bind="slotProps || {}" />
    </template>
  </el-input>
</template>

<script setup lang="ts">
// 关键：禁止自动继承，自己控制传递位置
defineOptions({ inheritAttrs: false })

interface Props {
  modelValue?: string | number
  clearable?: boolean
  placeholder?: string
  trim?: boolean  // 自定义属性：自动 trim
}

const props = withDefaults(defineProps<Props>(), {
  clearable: true,
  placeholder: '请输入',
  trim: true
})

const emit = defineEmits<{
  'update:modelValue': [value: string | number]
  'input': [value: string]
}>()

function handleInput(value: string) {
  const finalValue = props.trim ? value.trim() : value
  emit('input', finalValue)
}
</script>
```

### 3.2 封装 ProTable（企业级表格）

```vue
<!-- components/pro/ProTable.vue -->
<template>
  <div class="pro-table">
    <!-- 工具栏 -->
    <div class="pro-table__toolbar" v-if="showToolbar">
      <slot name="toolbar" />
      <el-button :icon="Refresh" @click="refresh">刷新</el-button>
    </div>

    <!-- 表格主体 -->
    <el-table
      v-bind="$attrs"
      v-loading="loading"
      :data="tableData"
      :border="border"
      @selection-change="handleSelectionChange"
    >
      <el-table-column v-if="selection" type="selection" width="55" />
      <template v-for="col in columns" :key="col.prop">
        <el-table-column v-bind="col">
          <template v-if="col.slot" #default="scope">
            <slot :name="col.slot" v-bind="scope" />
          </template>
          <template v-if="col.render" #default="scope">
            <component :is="col.render(scope.row)" />
          </template>
        </el-table-column>
      </template>
      <slot />  <!-- 支持追加自定义列 -->
    </el-table>

    <!-- 分页 -->
    <el-pagination
      v-if="pagination"
      class="pro-table__pagination"
      v-model:current-page="page.current"
      v-model:page-size="page.size"
      :total="page.total"
      :page-sizes="[10, 20, 50, 100]"
      layout="total, sizes, prev, pager, next, jumper"
      @current-change="fetchData"
      @size-change="fetchData"
    />
  </div>
</template>

<script setup lang="ts">
import { ref, reactive, onMounted } from 'vue'
import { Refresh } from '@element-plus/icons-vue'

interface ColumnConfig {
  prop: string
  label: string
  width?: number | string
  minWidth?: number | string
  fixed?: 'left' | 'right'
  sortable?: boolean
  slot?: string               // 自定义插槽名
  render?: (row: any) => any  // 渲染函数
  [key: string]: any
}

interface Props {
  columns: ColumnConfig[]
  requestApi: (params: any) => Promise<{ list: any[], total: number }>
  requestParams?: Record<string, any>
  selection?: boolean
  border?: boolean
  pagination?: boolean
  showToolbar?: boolean
  immediate?: boolean  // 是否立即请求
}

defineOptions({ inheritAttrs: false })

const props = withDefaults(defineProps<Props>(), {
  border: true,
  pagination: true,
  showToolbar: true,
  immediate: true
})

const emit = defineEmits<{
  'selection-change': [rows: any[]]
}>()

const loading = ref(false)
const tableData = ref<any[]>([])
const page = reactive({ current: 1, size: 20, total: 0 })

async function fetchData() {
  loading.value = true
  try {
    const { list, total } = await props.requestApi({
      ...props.requestParams,
      page: page.current,
      size: page.size
    })
    tableData.value = list
    page.total = total
  } finally {
    loading.value = false
  }
}

function refresh() {
  page.current = 1
  fetchData()
}

function handleSelectionChange(rows: any[]) {
  emit('selection-change', rows)
}

// 暴露给父组件使用
defineExpose({ refresh, fetchData })

onMounted(() => {
  if (props.immediate) fetchData()
})
</script>
```

**使用示例：**

```vue
<template>
  <ProTable
    :columns="columns"
    :request-api="getUserList"
    :request-params="{ status: 1 }"
    selection
    @selection-change="handleSelect"
  >
    <template #action="{ row }">
      <el-button size="small" @click="editUser(row)">编辑</el-button>
    </template>
  </ProTable>
</template>

<script setup>
const columns = [
  { prop: 'name', label: '姓名', width: 120 },
  { prop: 'email', label: '邮箱', minWidth: 200 },
  { prop: 'status', label: '状态', slot: 'status' },
  { prop: 'action', label: '操作', slot: 'action', fixed: 'right', width: 150 }
]
</script>
```

---

## 四、自定义主题（CSS 变量）

Element Plus 2.x 使用 CSS 变量实现主题定制：

```scss
// styles/element-plus/index.scss
// 覆盖 Element Plus CSS 变量

:root {
  // 主色调
  --el-color-primary: #1890ff;
  --el-color-primary-light-3: #46a6ff;
  --el-color-primary-light-5: #80c4ff;
  --el-color-primary-light-7: #b3d9ff;
  --el-color-primary-light-8: #cce6ff;
  --el-color-primary-light-9: #e6f3ff;
  --el-color-primary-dark-2: #1272cc;

  // 字体大小
  --el-font-size-base: 14px;

  // 圆角
  --el-border-radius-base: 4px;
  --el-border-radius-small: 2px;

  // 表格
  --el-table-header-bg-color: #f5f7fa;
  --el-table-row-hover-bg-color: #f0f7ff;

  // 间距
  --el-component-size: 32px;
  --el-component-size-small: 24px;
  --el-component-size-large: 40px;
}

// 暗色模式
html.dark {
  --el-color-primary: #409eff;
  --el-bg-color: #141414;
  --el-text-color-primary: #e5eaf3;
}
```

```javascript
// vite.config.js - 全局注入 SCSS 变量
css: {
  preprocessorOptions: {
    scss: {
      additionalData: `
        @use "@/styles/element-plus/index.scss" as *;
        @use "@/styles/variables.scss" as *;
      `
    }
  }
}
```

---

## 五、按需引入配置

```javascript
// vite.config.js
import AutoImport from 'unplugin-auto-import/vite'
import Components from 'unplugin-vue-components/vite'
import { ElementPlusResolver } from 'unplugin-vue-components/resolvers'

export default defineConfig({
  plugins: [
    AutoImport({
      resolvers: [ElementPlusResolver()],
    }),
    Components({
      resolvers: [
        ElementPlusResolver({
          // 自动引入样式（推荐用 sass 版本以支持主题覆盖）
          importStyle: 'sass',
        })
      ],
    }),
  ],
})
```

```typescript
// 图标按需引入
// main.ts
import * as ElementPlusIconsVue from '@element-plus/icons-vue'

const app = createApp(App)
// 全量注册图标（开发阶段）
for (const [key, component] of Object.entries(ElementPlusIconsVue)) {
  app.component(key, component)
}

// 生产环境推荐：unplugin-icons 按需引入
// vite.config.js
import Icons from 'unplugin-icons/vite'
import IconsResolver from 'unplugin-icons/resolver'
plugins: [
  Components({
    resolvers: [
      IconsResolver({ prefix: 'Icon', enabledCollections: ['ep'] })
    ]
  }),
  Icons({ autoInstall: true })
]
// 使用: <icon-ep-search />
```

---

## 六、封装业务组件示例

### 6.1 SearchForm 组件

```vue
<!-- components/pro/SearchForm.vue -->
<template>
  <el-form
    ref="formRef"
    :model="modelValue"
    :inline="true"
    class="search-form"
    @keyup.enter="handleSearch"
  >
    <template v-for="item in columns" :key="item.prop">
      <el-form-item :label="item.label" :prop="item.prop">
        <!-- 输入框 -->
        <el-input
          v-if="!item.type || item.type === 'input'"
          v-model="modelValue[item.prop]"
          :placeholder="`请输入${item.label}`"
          clearable
          style="width: 200px"
        />
        <!-- 下拉框 -->
        <el-select
          v-else-if="item.type === 'select'"
          v-model="modelValue[item.prop]"
          :placeholder="`请选择${item.label}`"
          clearable
          style="width: 200px"
        >
          <el-option
            v-for="opt in item.options"
            :key="opt.value"
            :label="opt.label"
            :value="opt.value"
          />
        </el-select>
        <!-- 日期范围 -->
        <el-date-picker
          v-else-if="item.type === 'daterange'"
          v-model="modelValue[item.prop]"
          type="daterange"
          value-format="YYYY-MM-DD"
          start-placeholder="开始日期"
          end-placeholder="结束日期"
        />
      </el-form-item>
    </template>

    <el-form-item>
      <el-button type="primary" @click="handleSearch">查询</el-button>
      <el-button @click="handleReset">重置</el-button>
    </el-form-item>
  </el-form>
</template>

<script setup lang="ts">
interface SearchColumn {
  prop: string
  label: string
  type?: 'input' | 'select' | 'daterange'
  options?: { label: string; value: any }[]
}

const props = defineProps<{
  columns: SearchColumn[]
  modelValue: Record<string, any>
}>()

const emit = defineEmits<{
  'update:modelValue': [value: Record<string, any>]
  'search': [params: Record<string, any>]
  'reset': []
}>()

function handleSearch() {
  emit('search', props.modelValue)
}

function handleReset() {
  const resetValue = Object.keys(props.modelValue).reduce((acc, key) => {
    acc[key] = undefined
    return acc
  }, {} as Record<string, any>)
  emit('update:modelValue', resetValue)
  emit('reset')
}
</script>
```

---

## 七、版本锁定策略

```json
// package.json
{
  "dependencies": {
    // 锁定精确版本，避免小版本更新引入 breaking change
    "element-plus": "2.7.0",
    "@element-plus/icons-vue": "2.3.1"
  }
}
```

```bash
# 使用 package-lock.json / pnpm-lock.yaml 锁定所有依赖
# CI/CD 中使用 ci 命令（不更新 lock 文件）
npm ci        # npm
pnpm install --frozen-lockfile  # pnpm
yarn install --frozen-lockfile  # yarn

# 升级策略：按季度评估，先在 feature 分支验证
npm outdated                    # 查看可更新的依赖
npx npm-check-updates -i        # 交互式选择升级
```

| 版本策略 | 格式示例 | 适用场景 |
|----------|----------|----------|
| 精确锁定 | `"2.7.0"` | 生产项目（推荐） |
| 补丁更新 | `"~2.7.0"` | 允许 bug fix 更新 |
| 次版本更新 | `"^2.7.0"` | 库项目（peer deps） |
| 任意版本 | `"*"` | 禁止使用 |

**最佳实践**：生产项目锁定精确版本 + CI 使用 frozen-lockfile，每季度由专人负责升级评估，升级前先跑完整的 E2E 测试。
