# 前端性能优化：懒加载、虚拟列表、骨架屏

<div class="post-meta">📅 2025-12-27 &nbsp;·&nbsp; 🏷️ <span class="tag">前端</span> <span class="tag">性能</span></div>

前端性能直接影响用户体验。本文聚焦三大高频优化手段：懒加载、虚拟列表和骨架屏，结合 Vue 3 给出实用方案。

---

## 一、路由懒加载

```javascript
// router/index.js
const routes = [
  {
    path: '/dashboard',
    // 使用动态 import，打包时会独立分包
    component: () => import('@/views/Dashboard.vue')
  },
  {
    path: '/user',
    // 通过注释指定 chunk 名，多个路由共享一个包
    component: () => import(/* webpackChunkName: "user" */ '@/views/User.vue')
  }
]
```

---

## 二、图片懒加载

```vue
<script setup>
// 方式1：原生 loading="lazy"（现代浏览器支持）
</script>
<template>
  <img src="large-image.jpg" loading="lazy" alt="..." />
</template>
```

```javascript
// 方式2：Intersection Observer（自定义 v-lazy 指令）
const lazyDirective = {
  mounted(el, binding) {
    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) {
        el.src = binding.value
        observer.unobserve(el)
      }
    }, { rootMargin: '100px' })
    observer.observe(el)
  }
}
// app.directive('lazy', lazyDirective)
// <img v-lazy="imageUrl" />
```

---

## 三、虚拟列表

大量数据渲染时（如 10万条），只渲染可视区域内的元素：

```
可视区域高度: 500px
每项高度: 50px
可视条数: 10 条（+ 上下缓冲各5条）

总数据: 100000 条
实际渲染: ~20 条（DOM 节点固定）
```

```vue
<!-- 使用 vue-virtual-scroller（推荐库）-->
<template>
  <RecycleScroller
    class="scroller"
    :items="bigList"
    :item-size="50"
    key-field="id"
  >
    <template #default="{ item }">
      <div class="item">{{ item.name }}</div>
    </template>
  </RecycleScroller>
</template>

<script setup>
import { RecycleScroller } from 'vue-virtual-scroller'
import 'vue-virtual-scroller/dist/vue-virtual-scroller.css'
</script>
```

简单手写实现原理：

```vue
<script setup>
import { ref, computed } from 'vue'

const props = defineProps({ items: Array, itemHeight: { default: 50 } })
const containerHeight = 500
const scrollTop = ref(0)

const visibleCount = Math.ceil(containerHeight / props.itemHeight)
const startIndex = computed(() => Math.floor(scrollTop.value / props.itemHeight))
const endIndex = computed(() => Math.min(startIndex.value + visibleCount + 5, props.items.length))
const visibleItems = computed(() => props.items.slice(startIndex.value, endIndex.value))
const offsetY = computed(() => startIndex.value * props.itemHeight)
const totalHeight = computed(() => props.items.length * props.itemHeight)

const onScroll = (e) => { scrollTop.value = e.target.scrollTop }
</script>

<template>
  <div :style="{ height: containerHeight + 'px', overflow: 'auto' }" @scroll="onScroll">
    <div :style="{ height: totalHeight + 'px', position: 'relative' }">
      <div :style="{ transform: `translateY(${offsetY}px)` }">
        <div v-for="item in visibleItems" :key="item.id" :style="{ height: itemHeight + 'px' }">
          {{ item.name }}
        </div>
      </div>
    </div>
  </div>
</template>
```

---

## 四、骨架屏

```vue
<!-- SkeletonCard.vue -->
<template>
  <div class="skeleton-card">
    <div class="skeleton avatar shimmer"></div>
    <div class="skeleton line w-60 shimmer"></div>
    <div class="skeleton line w-80 shimmer"></div>
    <div class="skeleton line w-40 shimmer"></div>
  </div>
</template>

<style scoped>
.skeleton { background: #e2e8f0; border-radius: 4px; }
.avatar { width: 48px; height: 48px; border-radius: 50%; }
.line { height: 14px; margin: 8px 0; }
.w-60 { width: 60%; }
.w-80 { width: 80%; }

/* 闪光动画 */
@keyframes shimmer {
  from { background-position: -200% 0; }
  to   { background-position: 200% 0; }
}
.shimmer {
  background: linear-gradient(90deg, #e2e8f0 25%, #f8fafc 50%, #e2e8f0 75%);
  background-size: 200% 100%;
  animation: shimmer 1.5s infinite;
}
</style>
```

```vue
<!-- 使用：数据加载时显示骨架屏 -->
<template>
  <SkeletonCard v-if="loading" v-for="n in 5" :key="n" />
  <UserCard v-else v-for="user in users" :key="user.id" :user="user" />
</template>
```

---

## 五、Web Vitals 关键指标

| 指标 | 全称 | 含义 | 良好 | 需改进 |
|------|------|------|------|--------|
| LCP | Largest Contentful Paint | 最大内容渲染时间 | ≤2.5s | >4s |
| FID | First Input Delay | 首次输入延迟 | ≤100ms | >300ms |
| CLS | Cumulative Layout Shift | 累积布局偏移 | ≤0.1 | >0.25 |
| FCP | First Contentful Paint | 首次内容渲染 | ≤1.8s | >3s |
| TTFB | Time to First Byte | 首字节时间 | ≤800ms | >1.8s |

**提升 LCP**：预加载关键资源 `<link rel="preload">`，压缩首屏图片  
**提升 CLS**：给图片/视频预留固定宽高，避免字体抖动  
**提升 FID**：拆分长任务，使用 Web Worker 处理计算密集型逻辑

---

## 总结

| 优化手段 | 解决问题 | 场景 |
|---------|---------|------|
| 路由懒加载 | 首屏 JS 体积大 | 所有项目 |
| 图片懒加载 | 首屏图片资源过多 | 图文列表页 |
| 虚拟列表 | 大量数据渲染卡顿 | 长列表（>1000条）|
| 骨架屏 | 白屏体验差 | 数据加载等待期 |
