# ElasticSearch 倒排索引原理与分词实战

<div class="post-meta">📅 2025-07-12 &nbsp;·&nbsp; 🏷️ <span class="tag">ElasticSearch</span> <span class="tag">搜索</span></div>

## 一、正排索引 vs 倒排索引

### 1.1 正排索引（Forward Index）

```
文档ID → 文档内容（MySQL 就是典型的正排索引）

DocID | Title              | Content
------+--------------------+----------------------------------
  1   | MySQL 索引原理      | B+树是MySQL的核心索引结构...
  2   | Redis 入门指南      | Redis是内存数据库，支持5种数据结构...
  3   | ElasticSearch实战   | ES是基于Lucene的全文搜索引擎...

查询"MySQL"：
需要遍历所有文档内容 → O(n)，无法高效全文搜索
```

### 1.2 倒排索引（Inverted Index）

```
词项（Term） → 包含该词项的文档ID列表

Term        | Posting List（文档ID列表）
------------+---------------------------
MySQL       | [1, 3]
索引         | [1, 3]
Redis        | [2]
B+树         | [1]
内存         | [2, 3]
ElasticSearch| [3]

查询"MySQL"：直接定位到 [1, 3] → O(1)，高效！
```

### 1.3 对比总结

| 特性 | 正排索引 | 倒排索引 |
|------|---------|---------|
| 结构 | 文档ID → 内容 | 词项 → 文档ID列表 |
| 全文搜索 | 慢（全表扫描） | 快（O(1) 定位） |
| 精确查找 | 快（主键查询） | 不适合 |
| 更新成本 | 低 | 高（需重建索引） |
| 典型实现 | MySQL、Oracle | Lucene、ES |

## 二、倒排索引的完整结构

ElasticSearch 基于 Lucene，倒排索引包含三部分：

```
完整倒排索引结构：

Term Dictionary（词典）：
┌────────────────┬─────────────┐
│ Term           │ 指向 Posting │
├────────────────┼─────────────┤
│ MySQL          │ →           │
│ Redis          │ →           │
│ elasticsearch  │ →           │
└────────────────┴─────────────┘
（FST 有限状态机，节省内存）

Posting List（倒排列表）：
每个 Term 对应：
┌───────┬──────────┬──────────┬────────────────┐
│ DocID │ TF(词频) │ Position │ Offset(字符偏移)│
├───────┼──────────┼──────────┼────────────────┤
│  1    │  3       │ [2,8,15] │ [10-15,30-35]  │
│  3    │  1       │ [5]      │ [20-25]        │
└───────┴──────────┴──────────┴────────────────┘

Term Vectors（词向量）：支持高亮显示
```

### 存储优化技术

```
Posting List 压缩（Frame of Reference）：
原始 DocID：[1, 3, 5, 7, 100, 103, 106]
差值编码：  [1, 2, 2, 2, 93,  3,   3]
（相邻差值更小，压缩效果好）

Roaring Bitmap（稀疏/密集混合压缩）：
< 4096 个元素 → 用 short 数组
≥ 4096 个元素 → 用 bit 数组（bitmap）
```

## 三、ES 基本概念

| ES 概念 | 类比 MySQL | 说明 |
|---------|-----------|------|
| Index | Table | 同一类型文档的集合 |
| Document | Row | 一条数据，JSON 格式 |
| Field | Column | 文档中的字段 |
| Mapping | Schema | 字段类型定义 |
| Shard | 分区 | 数据水平分片 |
| Replica | 从库 | 数据副本，高可用 |

```bash
# ES 基本操作

# 创建索引
PUT /articles
{
  "mappings": {
    "properties": {
      "title":      { "type": "text", "analyzer": "ik_max_word" },
      "content":    { "type": "text", "analyzer": "ik_max_word" },
      "author":     { "type": "keyword" },
      "tags":       { "type": "keyword" },
      "view_count": { "type": "integer" },
      "created_at": { "type": "date", "format": "yyyy-MM-dd HH:mm:ss" }
    }
  },
  "settings": {
    "number_of_shards": 3,
    "number_of_replicas": 1
  }
}

# 插入文档
POST /articles/_doc/1
{
  "title":   "MySQL 索引原理",
  "content": "B+树是MySQL的核心索引结构...",
  "author":  "张三",
  "tags":    ["MySQL", "数据库"],
  "view_count": 100,
  "created_at": "2024-05-16 10:00:00"
}
```

## 四、IK 分词器配置

### 4.1 安装

```bash
# 下载与 ES 版本匹配的 IK 分词器
# https://github.com/infinilabs/analysis-ik/releases

# 方式1：ES 插件安装
./bin/elasticsearch-plugin install \
  https://get.infini.cloud/elasticsearch/analysis-ik/8.13.0

# 方式2：解压到 plugins 目录
cd /elasticsearch/plugins
mkdir ik && cd ik
unzip elasticsearch-analysis-ik-8.13.0.zip
```

### 4.2 两种分析模式

```bash
# ik_max_word：最细粒度拆分（用于索引）
GET /_analyze
{
  "analyzer": "ik_max_word",
  "text": "我是程序员在北京工作"
}
# 结果：我、是、程序员、程序、员、在、北京、工作

# ik_smart：智能最少拆分（用于搜索）
GET /_analyze
{
  "analyzer": "ik_smart",
  "text": "我是程序员在北京工作"
}
# 结果：我是、程序员、在、北京、工作
```

**实践建议：**
- 索引时使用 `ik_max_word`（拆分更细，召回率高）
- 搜索时使用 `ik_smart`（减少噪音，精准度高）

### 4.3 自定义词典

```xml
<!-- IK 分词器配置文件：config/IKAnalyzer.cfg.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">
<properties>
    <comment>IK Analyzer 扩展配置</comment>
    <!-- 自定义扩展词典 -->
    <entry key="ext_dict">custom/my_dict.dic</entry>
    <!-- 自定义停用词词典 -->
    <entry key="ext_stopwords">custom/stop_words.dic</entry>
    <!-- 远程词典（支持热更新） -->
    <entry key="remote_ext_dict">http://your-server/api/hot-words</entry>
</properties>
```

```
# custom/my_dict.dic（每行一个词）
程序员
区块链
元宇宙
```

## 五、Query DSL 查询语法

### 5.1 term 精确查询

```bash
# term：不分词，精确匹配（适用 keyword 字段）
GET /articles/_search
{
  "query": {
    "term": {
      "author": "张三"
    }
  }
}

# terms：多值精确匹配（类似 SQL IN）
GET /articles/_search
{
  "query": {
    "terms": {
      "tags": ["MySQL", "Redis"]
    }
  }
}
```

### 5.2 match 全文查询

```bash
# match：分词后查询（适用 text 字段）
GET /articles/_search
{
  "query": {
    "match": {
      "title": {
        "query": "MySQL索引优化",
        "operator": "and"   # 所有分词都必须匹配
      }
    }
  }
}

# match_phrase：短语匹配（词序一致）
GET /articles/_search
{
  "query": {
    "match_phrase": {
      "content": "B+树索引"
    }
  }
}

# multi_match：多字段查询
GET /articles/_search
{
  "query": {
    "multi_match": {
      "query": "MySQL优化",
      "fields": ["title^3", "content"],  # title 权重 ×3
      "type": "best_fields"
    }
  }
}
```

### 5.3 bool 复合查询

```bash
GET /articles/_search
{
  "query": {
    "bool": {
      "must": [
        { "match": { "title": "MySQL" } }      # 必须匹配（影响评分）
      ],
      "should": [
        { "term": { "tags": "数据库" } },       # 可选匹配（提升评分）
        { "term": { "tags": "索引" } }
      ],
      "must_not": [
        { "term": { "author": "禁用作者" } }   # 必须不匹配
      ],
      "filter": [
        { "range": { "view_count": { "gte": 100 } } },  # 过滤（不影响评分）
        { "range": { "created_at": { 
            "gte": "2024-01-01 00:00:00",
            "lte": "2024-12-31 23:59:59"
        }}}
      ]
    }
  },
  "from": 0,
  "size": 10,
  "sort": [
    { "view_count": "desc" },
    { "_score": "desc" }
  ]
}
```

### 5.4 range 范围查询

```bash
GET /articles/_search
{
  "query": {
    "range": {
      "view_count": {
        "gte": 100,    # >=
        "lte": 1000    # <=
        # "gt": 100    # >
        # "lt": 1000   # <
      }
    }
  }
}
```

## 六、聚合查询

### 6.1 terms 聚合（类似 GROUP BY）

```bash
# 统计各标签文章数量
GET /articles/_search
{
  "size": 0,
  "aggs": {
    "tags_count": {
      "terms": {
        "field": "tags",
        "size": 10
      }
    }
  }
}

# 结果
{
  "aggregations": {
    "tags_count": {
      "buckets": [
        { "key": "MySQL", "doc_count": 25 },
        { "key": "Redis", "doc_count": 18 },
        { "key": "Java",  "doc_count": 15 }
      ]
    }
  }
}
```

### 6.2 date_histogram 时间聚合

```bash
# 按月统计文章发布数
GET /articles/_search
{
  "size": 0,
  "aggs": {
    "monthly_count": {
      "date_histogram": {
        "field": "created_at",
        "calendar_interval": "month",
        "format": "yyyy-MM",
        "min_doc_count": 0
      }
    }
  }
}
```

### 6.3 嵌套聚合（先过滤再聚合）

```bash
# 过滤 MySQL 文章，再统计各作者数量
GET /articles/_search
{
  "size": 0,
  "query": {
    "term": { "tags": "MySQL" }
  },
  "aggs": {
    "by_author": {
      "terms": { "field": "author" },
      "aggs": {
        "avg_views": {
          "avg": { "field": "view_count" }
        }
      }
    }
  }
}
```

## 七、Java 客户端示例

```java
// Spring Boot + ES Java Client
@Service
public class ArticleSearchService {

    @Autowired
    private ElasticsearchClient esClient;

    public SearchResult<Article> search(String keyword, int page, int size) 
            throws IOException {
        
        SearchResponse<Article> response = esClient.search(s -> s
            .index("articles")
            .query(q -> q
                .bool(b -> b
                    .must(m -> m
                        .multiMatch(mm -> mm
                            .query(keyword)
                            .fields("title^3", "content")
                        )
                    )
                    .filter(f -> f
                        .range(r -> r
                            .field("view_count")
                            .gte(JsonData.of(0))
                        )
                    )
                )
            )
            .highlight(h -> h
                .fields("title", hf -> hf
                    .preTags("<em>").postTags("</em>"))
                .fields("content", hf -> hf
                    .preTags("<em>").postTags("</em>"))
            )
            .from((page - 1) * size)
            .size(size),
            Article.class
        );

        return buildResult(response);
    }
}
```

## 八、ES vs MySQL 选型对比

| 场景 | 推荐 | 原因 |
|------|------|------|
| 全文搜索 | ES | 倒排索引，分词搜索 |
| 精确 CRUD | MySQL | 事务支持，强一致性 |
| 复杂关联查询 | MySQL | JOIN 支持 |
| 日志分析 | ES | 大数据量，聚合分析 |
| 数据统计报表 | MySQL / ClickHouse | 精确计算 |
| 自动补全 | ES | completion suggester |
| 地理位置搜索 | ES | geo_point 类型 |
| 多维度筛选 | ES | bool query + filter |

**典型架构：MySQL 主存储 + ES 搜索引擎**

```
写入流程：
  业务写操作 → MySQL（主数据）
             ↘ Canal 监听 binlog
               ↓
               同步到 ES（搜索数据）

读取流程：
  全文搜索/复杂过滤 → ES（返回 ID）→ MySQL（按 ID 查完整数据）
  精确查询/事务     → MySQL
```
