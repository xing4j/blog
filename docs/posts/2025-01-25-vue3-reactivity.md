# Vue 3 响应式原理：Proxy 与依赖收集

<div class="post-meta">📅 2025-01-25 &nbsp;·&nbsp; 🏷️ <span class="tag">Vue 3</span> <span class="tag">前端</span></div>

## 一、Vue 2 的响应式缺陷

Vue 2 使用 `Object.defineProperty` 实现响应式，存在以下根本性缺陷：

| 问题 | 描述 | 影响 |
|------|------|------|
| 无法检测属性新增 | `obj.newKey = val` 不触发更新 | 需要 `Vue.set()` 绕过 |
| 无法检测属性删除 | `delete obj.key` 不触发更新 | 需要 `Vue.delete()` 绕过 |
| 数组变异方法限制 | 下标赋值 `arr[0] = val` 不触发 | 需重写 7 个数组方法 |
| 深层对象性能差 | 初始化时递归遍历所有属性 | 大型对象启动慢 |
| 无法代理 Map/Set | 原生数据结构不支持 | 需额外处理 |

```javascript
// Vue 2 的实现方式
function defineReactive(obj, key, val) {
  const dep = new Dep()
  Object.defineProperty(obj, key, {
    get() {
      dep.depend() // 收集依赖
      return val
    },
    set(newVal) {
      if (newVal === val) return
      val = newVal
      dep.notify() // 触发更新
    }
  })
}

// 缺陷示例
const vm = new Vue({ data: { user: { name: 'Alice' } } })
vm.user.age = 18        // ❌ 不响应
vm.user.name = 'Bob'    // ✅ 响应
```

---

## 二、Vue 3 Proxy 的优势

Vue 3 使用 ES6 `Proxy` 从根本上解决了上述问题：

```javascript
const handler = {
  get(target, key, receiver) {
    track(target, key)              // 依赖收集
    return Reflect.get(target, key, receiver)
  },
  set(target, key, value, receiver) {
    const result = Reflect.set(target, key, value, receiver)
    trigger(target, key)            // 触发更新
    return result
  },
  deleteProperty(target, key) {
    const result = Reflect.deleteProperty(target, key)
    trigger(target, key)
    return result
  },
  has(target, key) {
    track(target, key)
    return Reflect.has(target, key)
  }
}

function reactive(raw) {
  return new Proxy(raw, handler)
}
```

| 特性 | Object.defineProperty | Proxy |
|------|----------------------|-------|
| 新增属性 | ❌ 需 Vue.set | ✅ 自动响应 |
| 删除属性 | ❌ 需 Vue.delete | ✅ 自动响应 |
| 数组下标 | ❌ 不响应 | ✅ 自动响应 |
| Map/Set | ❌ 不支持 | ✅ 支持 |
| 初始化性能 | 慢（全量递归） | 快（懒代理） |
| 嵌套对象 | 初始化时递归 | 访问时递归（按需） |

---

## 三、reactive 实现原理

```javascript
// 缓存已代理的对象，避免重复代理
const reactiveMap = new WeakMap()

function reactive(target) {
  // 已经是响应式对象，直接返回
  if (isReadonly(target)) return target

  // 避免重复代理
  if (reactiveMap.has(target)) {
    return reactiveMap.get(target)
  }

  const proxy = new Proxy(target, mutableHandlers)
  reactiveMap.set(target, proxy)
  return proxy
}

// 深层响应式：访问嵌套对象时递归代理
function createGetter() {
  return function get(target, key, receiver) {
    const res = Reflect.get(target, key, receiver)
    // 依赖收集
    track(target, TrackOpTypes.GET, key)
    // 如果是对象，递归变为响应式（懒代理）
    if (isObject(res)) {
      return reactive(res)
    }
    return res
  }
}
```

---

## 四、ref 实现原理

`ref` 用于包装基本类型值，内部使用对象的 `.value` 属性触发响应式：

```javascript
class RefImpl {
  private _value: any
  private _rawValue: any
  public dep: Set<ReactiveEffect>
  public readonly __v_isRef = true

  constructor(value: any, public readonly __v_isShallow: boolean) {
    this._rawValue = value
    // 如果是对象则转为 reactive，否则直接存储
    this._value = __v_isShallow ? value : toReactive(value)
  }

  get value() {
    // 收集依赖
    trackRefValue(this)
    return this._value
  }

  set value(newVal) {
    // 新旧值不同才触发
    if (hasChanged(newVal, this._rawValue)) {
      this._rawValue = newVal
      this._value = this.__v_isShallow ? newVal : toReactive(newVal)
      // 触发更新
      triggerRefValue(this, newVal)
    }
  }
}

function ref(value) {
  return new RefImpl(value, false)
}
```

---

## 五、依赖收集（track）流程

```
┌─────────────────────────────────────────────────────┐
│                   依赖收集流程                         │
│                                                       │
│  effect(() => {                                       │
│    console.log(state.count)  ← 触发 Proxy get        │
│  })                                                   │
│          │                                            │
│          ▼                                            │
│   activeEffect = 当前 effect                         │
│          │                                            │
│          ▼                                            │
│   track(target, 'count')                              │
│          │                                            │
│          ▼                                            │
│   targetMap: WeakMap                                  │
│   ┌──────────────────────────────────┐               │
│   │  target → depsMap (Map)          │               │
│   │  depsMap → key → dep (Set)       │               │
│   │  dep.add(activeEffect)           │               │
│   └──────────────────────────────────┘               │
└─────────────────────────────────────────────────────┘
```

```javascript
// 全局依赖存储结构
// WeakMap<target, Map<key, Set<ReactiveEffect>>>
const targetMap = new WeakMap()

let activeEffect: ReactiveEffect | undefined

function track(target: object, type: TrackOpTypes, key: unknown) {
  if (!activeEffect) return  // 没有活跃 effect，不收集

  let depsMap = targetMap.get(target)
  if (!depsMap) {
    targetMap.set(target, (depsMap = new Map()))
  }

  let dep = depsMap.get(key)
  if (!dep) {
    depsMap.set(key, (dep = new Set()))
  }

  if (!dep.has(activeEffect)) {
    dep.add(activeEffect)
    activeEffect.deps.push(dep)  // 反向追踪，用于清理
  }
}
```

---

## 六、触发更新（trigger）流程

```
┌─────────────────────────────────────────────────────┐
│                   触发更新流程                         │
│                                                       │
│  state.count++   ← 触发 Proxy set                    │
│          │                                            │
│          ▼                                            │
│   trigger(target, 'count')                            │
│          │                                            │
│          ▼                                            │
│   从 targetMap 找到对应的 dep (Set<Effect>)           │
│          │                                            │
│          ▼                                            │
│   遍历 dep，将 effect 加入调度队列                     │
│          │                                            │
│          ▼                                            │
│   queueFlush() → 微任务批量执行                        │
│          │                                            │
│          ▼                                            │
│   effect.run() → 重新执行副作用函数                    │
└─────────────────────────────────────────────────────┘
```

```javascript
function trigger(target: object, type: TriggerOpTypes, key?: unknown) {
  const depsMap = targetMap.get(target)
  if (!depsMap) return

  const effects = new Set<ReactiveEffect>()

  const add = (effectsToAdd: Set<ReactiveEffect> | undefined) => {
    if (effectsToAdd) {
      effectsToAdd.forEach(effect => {
        if (effect !== activeEffect) {
          effects.add(effect)
        }
      })
    }
  }

  // 收集该 key 的所有 effect
  if (key !== void 0) {
    add(depsMap.get(key))
  }

  // 批量执行
  effects.forEach(effect => {
    if (effect.scheduler) {
      effect.scheduler()  // 有调度器时走调度器（如 computed、watch）
    } else {
      effect.run()        // 直接运行
    }
  })
}
```

---

## 七、effect 副作用函数

```javascript
class ReactiveEffect<T = any> {
  active = true
  deps: Set<ReactiveEffect>[] = []   // 反向依赖收集，用于清理
  parent: ReactiveEffect | undefined  // 支持嵌套 effect

  constructor(
    public fn: () => T,
    public scheduler: EffectScheduler | null = null,
    scope?: EffectScope
  ) {}

  run() {
    if (!this.active) return this.fn()

    // 设置当前活跃 effect
    const parent = activeEffect
    activeEffect = this
    try {
      return this.fn()  // 执行时触发 getter → track
    } finally {
      activeEffect = parent  // 恢复父级 effect（嵌套场景）
    }
  }

  stop() {
    if (this.active) {
      cleanupEffect(this)  // 清除所有依赖
      this.active = false
    }
  }
}

// 使用示例
const count = ref(0)
const effect = new ReactiveEffect(() => {
  console.log('count is:', count.value)
})
effect.run()   // 输出: count is: 0，同时收集依赖
count.value++  // 输出: count is: 1，自动触发
```

---

## 八、computed 实现原理

`computed` 是一个懒执行的 effect，带有缓存机制：

```javascript
class ComputedRefImpl<T> {
  private _value!: T
  public readonly effect: ReactiveEffect<T>
  public _dirty = true   // 脏标记，控制是否重新计算

  constructor(getter: ComputedGetter<T>) {
    this.effect = new ReactiveEffect(getter, () => {
      // scheduler：依赖变化时，不立即执行，只标记为脏
      if (!this._dirty) {
        this._dirty = true
        triggerRefValue(this)  // 通知依赖 computed 的 effect
      }
    })
  }

  get value() {
    trackRefValue(this)  // 收集依赖
    if (this._dirty) {
      this._dirty = false
      this._value = this.effect.run()  // 懒计算
    }
    return this._value
  }
}

// 使用
const count = ref(1)
const double = computed(() => count.value * 2)
console.log(double.value) // 2，首次计算并缓存
console.log(double.value) // 2，直接返回缓存
count.value = 3
console.log(double.value) // 6，脏了重新计算
```

---

## 九、watch 实现原理

```javascript
function watch(source, cb, options = {}) {
  let getter: () => any

  // 标准化 source
  if (isRef(source)) {
    getter = () => source.value
  } else if (isReactive(source)) {
    getter = () => source
    options.deep = true  // reactive 默认深度监听
  } else if (isFunction(source)) {
    getter = source
  }

  let oldValue: any
  let cleanup: () => void

  const job = () => {
    const newValue = effect.run()
    if (hasChanged(newValue, oldValue) || options.deep) {
      // 执行清理函数（onInvalidate）
      if (cleanup) cleanup()
      cb(newValue, oldValue, onInvalidate)
      oldValue = newValue
    }
  }

  const effect = new ReactiveEffect(getter, () => {
    // scheduler：依赖变化时进入调度队列，而非立即执行
    if (options.flush === 'sync') {
      job()
    } else {
      queueFlush(job)  // 异步批量执行
    }
  })

  // immediate 立即执行
  if (options.immediate) {
    job()
  } else {
    oldValue = effect.run()  // 首次运行收集依赖
  }

  return () => effect.stop()  // 返回停止函数
}
```

---

## 十、响应式系统完整流程图

```
┌───────────────────────────────────────────────────────────────┐
│                    Vue 3 响应式完整流程                          │
│                                                               │
│  初始化阶段                                                    │
│  ──────────                                                   │
│  reactive(obj) → Proxy(obj, handlers)                         │
│  ref(val)      → RefImpl { get value(), set value() }        │
│                                                               │
│  运行阶段（读取）                                               │
│  ──────────────                                               │
│  effect.run()                                                 │
│      │                                                        │
│      ├─ activeEffect = this                                   │
│      ├─ fn() 执行                                             │
│      │    └─ 访问 proxy.key → Proxy get 拦截                  │
│      │         └─ track(target, key)                          │
│      │              └─ dep.add(activeEffect)                  │
│      └─ activeEffect = parent                                 │
│                                                               │
│  运行阶段（写入）                                               │
│  ──────────────                                               │
│  proxy.key = newVal → Proxy set 拦截                          │
│      │                                                        │
│      ├─ Reflect.set(target, key, newVal)                      │
│      └─ trigger(target, key)                                  │
│           └─ dep.forEach(effect => effect.scheduler || run)   │
│                └─ queueFlush → 微任务批量执行                   │
│                     └─ 重新执行 fn() → 更新 DOM               │
└───────────────────────────────────────────────────────────────┘
```

---

## 十一、总结

| 概念 | 作用 | 关键 API |
|------|------|----------|
| Proxy | 拦截对象读写操作 | `new Proxy(target, handlers)` |
| track | 收集依赖，建立 effect 与数据的关联 | `targetMap.get(target).get(key)` |
| trigger | 触发依赖更新，通知所有 effect 重新运行 | `dep.forEach(e => e.run())` |
| effect | 副作用函数，响应式系统的核心执行单元 | `new ReactiveEffect(fn)` |
| computed | 带缓存的懒执行 effect，通过脏标记优化 | `_dirty` 标记 |
| watch | 监听源变化，通过调度器异步执行回调 | `scheduler + queueFlush` |

Vue 3 响应式系统的核心思想是 **"读时收集，写时触发"**，Proxy 让这一机制更加完善，不再有 Vue 2 时代的诸多限制。
