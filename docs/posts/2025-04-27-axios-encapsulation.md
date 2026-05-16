# axios 二次封装：统一拦截、错误处理、取消重复请求

<div class="post-meta">📅 2025-04-27 &nbsp;·&nbsp; 🏷️ <span class="tag">Vue</span> <span class="tag">前端</span></div>

生产项目中直接使用 axios 会导致重复代码、错误处理分散。合理封装后能统一鉴权、错误处理、Loading 控制和重复请求取消。

---

## 一、完整封装结构

```
src/
  utils/
    request.js        # axios 实例 + 拦截器
    requestCancel.js  # 重复请求取消管理
  api/
    user.js           # 业务 API 模块
    order.js
```

---

## 二、核心封装（request.js）

```javascript
import axios from 'axios'
import { ElMessage, ElMessageBox } from 'element-plus'
import { useUserStore } from '@/stores/user'
import { pendingMap, removePending, addPending } from './requestCancel'

// 创建 axios 实例
const service = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL,
  timeout: 10000,
  headers: { 'Content-Type': 'application/json' }
})

// ─── 请求拦截器 ────────────────────────────────
service.interceptors.request.use(
  config => {
    // 1. 取消重复请求
    removePending(config)
    addPending(config)

    // 2. 注入 token
    const userStore = useUserStore()
    if (userStore.token) {
      config.headers['Authorization'] = `Bearer ${userStore.token}`
    }

    // 3. 自定义 loading（通过 config 控制）
    if (config.loading !== false) {
      // 可接入全局 loading 管理
    }

    return config
  },
  error => Promise.reject(error)
)

// ─── 响应拦截器 ────────────────────────────────
service.interceptors.response.use(
  response => {
    removePending(response.config) // 请求完成，移除记录

    const { code, data, message } = response.data

    // 业务成功
    if (code === 200 || code === 0) {
      return data
    }

    // 业务失败（后端返回业务错误码）
    if (code === 401) {
      handleUnauthorized()
      return Promise.reject(new Error(message || '未授权'))
    }

    ElMessage.error(message || '请求失败')
    return Promise.reject(new Error(message))
  },
  error => {
    removePending(error.config || {})

    if (axios.isCancel(error)) {
      console.log('重复请求已取消:', error.message)
      return Promise.reject(error)
    }

    // HTTP 错误状态处理
    handleHttpError(error)
    return Promise.reject(error)
  }
)

// 处理 HTTP 错误码
function handleHttpError(error) {
  const status = error.response?.status
  const msgMap = {
    400: '请求参数错误',
    401: '登录已过期，请重新登录',
    403: '没有权限访问该资源',
    404: '请求的资源不存在',
    500: '服务器内部错误',
    502: '网关错误',
    503: '服务不可用'
  }
  ElMessage.error(msgMap[status] || `请求失败：${status || '网络错误'}`)
  if (status === 401) handleUnauthorized()
}

// 处理 401 未授权（防重复弹窗）
let isShowLogin = false
function handleUnauthorized() {
  if (!isShowLogin) {
    isShowLogin = true
    ElMessageBox.confirm('登录已过期，请重新登录', '提示', {
      confirmButtonText: '重新登录',
      type: 'warning'
    }).then(() => {
      const userStore = useUserStore()
      userStore.logout()
    }).finally(() => { isShowLogin = false })
  }
}

export default service
```

---

## 三、重复请求取消（requestCancel.js）

```javascript
import axios from 'axios'

// 记录进行中的请求
const pendingMap = new Map()

// 生成请求唯一 key
const getPendingKey = (config) => {
  const { url, method, params, data } = config
  return [url, method, JSON.stringify(params), JSON.stringify(data)].join('&')
}

// 添加请求到 pending
export const addPending = (config) => {
  const key = getPendingKey(config)
  if (!pendingMap.has(key)) {
    config.cancelToken = new axios.CancelToken(cancel => {
      pendingMap.set(key, cancel)
    })
  }
}

// 取消并移除重复请求
export const removePending = (config) => {
  const key = getPendingKey(config)
  if (pendingMap.has(key)) {
    const cancel = pendingMap.get(key)
    cancel(`重复请求已取消: ${key}`)
    pendingMap.delete(key)
  }
}

// 取消所有进行中的请求（路由跳转时使用）
export const clearPending = () => {
  pendingMap.forEach(cancel => cancel('页面切换，取消所有请求'))
  pendingMap.clear()
}
```

路由切换时清除所有请求：

```javascript
// router/permission.js
import { clearPending } from '@/utils/requestCancel'

router.beforeEach(() => {
  clearPending()
})
```

---

## 四、业务 API 模块（api/user.js）

```javascript
import request from '@/utils/request'

// 统一在模块中定义 API，组件中只调用函数
export const userApi = {
  // 登录
  login: (data) => request.post('/auth/login', data),

  // 获取用户信息
  getUserInfo: () => request.get('/user/info'),

  // 用户列表（支持自定义配置）
  getUserList: (params) => request.get('/user/list', { params }),

  // 上传文件（取消 loading，自定义 Content-Type）
  uploadAvatar: (file) => {
    const form = new FormData()
    form.append('file', file)
    return request.post('/user/avatar', form, {
      headers: { 'Content-Type': 'multipart/form-data' },
      loading: false,  // 禁用全局 loading
      timeout: 30000   // 单独设置超时
    })
  }
}
```

---

## 五、组件中使用

```vue
<script setup>
import { ref, onMounted } from 'vue'
import { userApi } from '@/api/user'

const userList = ref([])
const loading = ref(false)

const fetchUsers = async () => {
  loading.value = true
  try {
    userList.value = await userApi.getUserList({ page: 1, size: 10 })
  } finally {
    loading.value = false
  }
}

onMounted(fetchUsers)
</script>
```

---

## 六、token 刷新（无感续期）

```javascript
// 请求队列，token 刷新期间暂存
let isRefreshing = false
let requestQueue = []

service.interceptors.response.use(null, async error => {
  const { config, response } = error
  if (response?.status === 401 && !config._retry) {
    if (isRefreshing) {
      // 等待 token 刷新后重试
      return new Promise(resolve => {
        requestQueue.push(token => {
          config.headers['Authorization'] = `Bearer ${token}`
          resolve(service(config))
        })
      })
    }

    config._retry = true
    isRefreshing = true

    try {
      const userStore = useUserStore()
      const newToken = await userStore.refreshToken()
      requestQueue.forEach(cb => cb(newToken))
      requestQueue = []
      config.headers['Authorization'] = `Bearer ${newToken}`
      return service(config)
    } catch {
      userStore.logout()
    } finally {
      isRefreshing = false
    }
  }
  return Promise.reject(error)
})
```

---

## 总结

| 功能 | 实现方式 |
|------|---------|
| 统一鉴权 | 请求拦截器注入 token |
| 错误处理 | 响应拦截器统一处理 HTTP 错误 + 业务错误码 |
| 取消重复请求 | CancelToken + Map 记录进行中请求 |
| 路由切换取消请求 | `router.beforeEach` + `clearPending` |
| token 无感刷新 | 响应拦截器 + 请求队列 |
