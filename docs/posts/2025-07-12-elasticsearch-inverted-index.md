# Elasticsearch 倒排索引：全文搜索的基石

<div class="post-meta">📅 2025-07-12 &nbsp;·&nbsp; 🏷️ <span class="tag">数据库</span></div>

MySQL 的 LIKE '%关键词%' 慢到无法接受，加了 Elasticsearch 后，千万级文档的全文搜索控制在毫秒级。这背后的核心是**倒排索引**——一种专为搜索设计的数据结构。理解它，才能写出高效的查询，做好分词配置，避开性能陷阱。

---

## 一、背景：正排索引 vs 倒排索引

**正排索引**（传统数据库）：以文档 ID 为键，查文档内容：

```
doc_1 → "Java 是一门面向对象的编程语言"
doc_2 → "Python 简洁而强大"
doc_3 → "Java 和 Python 都很流行"
```
要搜索包含"Java"的文档，必须扫描所有文档——全表扫描。

**倒排索引**：以词项（Term）为键，查包含该词的文档列表：

```
"Java"   → [doc_1, doc_3]
"Python" → [doc_2, doc_3]
"面向对象" → [doc_1]
"编程语言" → [doc_1]
```
搜索"Java"时，直接在倒排表中查找，时间复杂度 O(1)。

---

## 二、Elasticsearch 的核心概念

| ES 概念 | 类比 MySQL | 说明 |
|---------|-----------|------|
| Index（索引）| Database（数据库）| ES 7.x 起废弃 Type，Index = 表 |
| Document（文档）| Row（行）| JSON 格式的数据单元 |
| Field（字段）| Column（列）| |
| Shard（分片）| 无直接对应 | 数据水平拆分，提高并发 |
| Replica（副本）| 无直接对应 | 主分片的复制，高可用 |
| Mapping（映射）| Schema | 字段类型定义 |

---

## 三、倒排索引的完整结构

一个完整的倒排索引不只是 Term → 文档列表，还包含：

```
词项字典（Term Dictionary）：
所有 Term 的有序列表，支持快速查找（B树或哈希）

倒排列表（Posting List）：
每个 Term 对应的文档信息：
┌──────────┬───────────────────────────────────────────┐
│  Term    │  Posting List                              │
├──────────┼───────────────────────────────────────────┤
│ "Java"   │ [{doc_id:1, freq:2, pos:[0,5]},            │
│          │  {doc_id:3, freq:1, pos:[0]}]               │
│ "Python" │ [{doc_id:2, freq:1, pos:[0]},              │
│          │  {doc_id:3, freq:1, pos:[2]}]               │
└──────────┴───────────────────────────────────────────┘
  doc_id: 文档 ID
  freq: 词项在该文档中出现的频率（用于相关性评分）
  pos: 词项出现的位置列表（用于短语查询）
```
---

## 四、分析器：文本处理流水线

文档写入 ES 前，要经过**分析器（Analyzer）**处理，将文本转换为 Term：

```
原始文本："Java 是一门面向对象的编程语言"
    ↓ 字符过滤器（Character Filter）：去除 HTML 标签等
"Java 是一门面向对象的编程语言"
    ↓ 分词器（Tokenizer）：按规则切词
["Java", "是", "一门", "面向对象", "的", "编程", "语言"]
    ↓ 词项过滤器（Token Filter）：小写化、去停用词、词干提取
["java", "一门", "面向对象", "编程", "语言"]
    ↓
写入倒排索引
```
### 内置分析器

```json
// standard 分析器（默认，英文友好）
"analyzer": "standard"  // 按空格/标点切词，小写化

// ik_max_word（中文，最细粒度切词）
"analyzer": "ik_max_word"  // "编程语言" → ["编程语言", "编程", "语言"]

// ik_smart（中文，智能切词）
"analyzer": "ik_smart"   // "编程语言" → ["编程语言"]（更粗，减少索引大小）
```
### 自定义分析器

```json
PUT /articles
{
  "settings": {
    "analysis": {
      "analyzer": {
        "my_analyzer": {
          "type": "custom",
          "tokenizer": "ik_max_word",
          "filter": ["lowercase", "stop_words_filter"]
        }
      },
      "filter": {
        "stop_words_filter": {
          "type": "stop",
          "stopwords": ["的", "了", "是", "在", "有"]
        }
      }
    }
  },
  "mappings": {
    "properties": {
      "title": {
        "type": "text",
        "analyzer": "my_analyzer",
        "search_analyzer": "ik_smart"  // 搜索时用更粗的分词，提高召回率
      }
    }
  }
}
```
---

## 五、常用查询语法

```json
// match 全文搜索（分析后查询）
GET /articles/_search
{
  "query": {
    "match": {
      "title": "Java 编程"   // 会被分词：["Java", "编程"]，OR 关系
    }
  }
}

// match_phrase 短语查询（词序一致）
{
  "query": {
    "match_phrase": {
      "title": "Java 编程语言"   // 必须出现且相邻
    }
  }
}

// multi_match 多字段搜索
{
  "query": {
    "multi_match": {
      "query": "Java",
      "fields": ["title^2", "content"]  // title 权重 × 2
    }
  }
}

// bool 组合查询
{
  "query": {
    "bool": {
      "must": [{"match": {"title": "Java"}}],       // 必须包含
      "should": [{"match": {"tags": "backend"}}],   // 最好包含（影响评分）
      "must_not": [{"match": {"status": "draft"}}], // 必须不包含
      "filter": [{"term": {"category": "tech"}}]    // 精确过滤（不影响评分）
    }
  }
}
```
---

## 六、常见坑点与最佳实践

### 坑 1：text 和 keyword 类型混淆

```json
// text：全文搜索，会被分词（用于 match 查询）
// keyword：精确匹配，不分词（用于 term 查询、聚合、排序）

// ❌ 用 term 查询 text 字段（分词后 term 与原文不同）
{"term": {"title": "Java 编程语言"}}  // 查不到，因为索引中是 ["java", "编程语言"]

// ✅ 全文搜索用 match
{"match": {"title": "Java 编程语言"}}

// ✅ 精确匹配用 keyword 子字段
{"term": {"category.keyword": "技术文章"}}
```
### 坑 2：_all 字段已废弃（ES 6.x+）

```json
// ❌ ES 6.x 废弃了 _all 字段
{"match": {"_all": "keyword"}}

// ✅ 使用 copy_to 或 multi_match
```
### 坑 3：深度分页性能问题

```json
// ❌ ES 深分页（from + size）需要获取并丢弃前 N 条，性能极差
{"from": 10000, "size": 10}  // 从 10000 条中取 10 条，每个分片都要返回 10010 条

// ✅ 使用 search_after 游标分页
{"size": 10, "sort": [{"create_time": "desc"}, {"id": "desc"}],
 "search_after": [1704067200000, 12345]}

// ✅ 或使用 scroll API（批量导出场景）
```
---

## 七、总结与延伸

**核心要点**：
- 倒排索引：Term → 文档列表，O(1) 查找包含某词的所有文档
- 分析器三阶段：字符过滤 → 分词 → 词项过滤，中文推荐 ik 分词器
- eext 用于全文搜索（match），keyword 用于精确匹配（term）和聚合
- 深分页用 search_after 游标，而非 from + size

**延伸阅读方向**：
- ES 相关性评分：BM25 算法原理（TF-IDF 的改进版）
- ES 集群架构：主节点/数据节点/协调节点的角色分工
- ES 写入流程：translog + 内存缓冲区 + Segment 合并（类似 LSM-Tree）
- Canal + ES 数据同步：MySQL binlog 实时同步到 ES，保持数据一致
