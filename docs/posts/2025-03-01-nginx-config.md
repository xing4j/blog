# Nginx 配置详解：反向代理、负载均衡、限流

<div class="post-meta">📅 2025-03-01 &nbsp;·&nbsp; 🏷️ <span class="tag">Nginx</span> <span class="tag">运维</span></div>

Nginx 是生产环境中最常用的 Web 服务器和反向代理，本文系统梳理核心配置结构，并深入讲解反向代理、负载均衡策略和限流配置，附完整可用的配置示例。

---

## 一、Nginx 核心配置结构

```nginx
# nginx.conf 整体结构

# 全局块（main context）
worker_processes auto;           # 工作进程数，推荐 auto（等于 CPU 核数）
worker_rlimit_nofile 65535;      # 每个 worker 最大文件描述符
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

# Events 块：连接处理
events {
    worker_connections 10240;    # 每个 worker 最大连接数
    use epoll;                   # Linux 推荐使用 epoll
    multi_accept on;             # 一次接受多个连接
}

# HTTP 块
http {
    include mime.types;
    default_type application/octet-stream;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    
    # Server 块（虚拟主机）
    server {
        listen 80;
        server_name example.com;
        
        # Location 块（路由规则）
        location / {
            root /usr/share/nginx/html;
            index index.html;
        }
    }
}
```

### 1.1 配置块层级关系

```
main
+-- events
+-- http
    +-- upstream（负载均衡池）
    +-- server（虚拟主机）
        +-- listen
        +-- server_name
        +-- location（路由规则）
            +-- proxy_pass
            +-- root / alias
            +-- ...
```

---

## 二、反向代理配置

### 2.1 基础反向代理

```nginx
server {
    listen 80;
    server_name api.example.com;
    
    location / {
        # 转发到后端服务
        proxy_pass http://127.0.0.1:8080;
        
        # 传递真实客户端信息
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # 超时配置
        proxy_connect_timeout 30s;  # 连接后端超时
        proxy_send_timeout    60s;  # 发送请求超时
        proxy_read_timeout    60s;  # 读取响应超时
        
        # 缓冲配置（减少后端压力）
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
    }
}
```

### 2.2 HTTPS 反向代理（SSL 终止）

```nginx
server {
    listen 443 ssl http2;
    server_name api.example.com;
    
    # SSL 证书
    ssl_certificate     /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;
    
    # SSL 安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # HSTS（强制 HTTPS）
    add_header Strict-Transport-Security "max-age=31536000" always;
    
    location / {
        proxy_pass http://backend_pool;
        proxy_set_header X-Forwarded-Proto https;
    }
}

# HTTP 重定向到 HTTPS
server {
    listen 80;
    server_name api.example.com;
    return 301 https://$host$request_uri;
}
```

### 2.3 按路径路由（路径分发）

```nginx
server {
    listen 80;
    server_name gateway.example.com;
    
    # 用户服务
    location /api/user/ {
        proxy_pass http://user-service/;   # 注意末尾斜杠的区别
    }
    
    # 订单服务
    location /api/order/ {
        proxy_pass http://order-service/;
    }
    
    # 文件服务（静态资源）
    location /static/ {
        alias /data/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # 默认
    location / {
        proxy_pass http://web-frontend/;
    }
}
```

---

## 三、负载均衡：5种策略

### 3.1 轮询（Round Robin）—— 默认

```nginx
upstream backend_pool {
    server 192.168.1.10:8080;
    server 192.168.1.11:8080;
    server 192.168.1.12:8080;
    # 请求依次分配到三台服务器：1->2->3->1->2->3...
}
```

### 3.2 加权轮询（Weighted Round Robin）

```nginx
upstream backend_pool {
    server 192.168.1.10:8080 weight=5;  # 配置高，权重大
    server 192.168.1.11:8080 weight=3;
    server 192.168.1.12:8080 weight=2;
    # 10次请求中：10收5个，11收3个，12收2个
}
```

### 3.3 IP Hash（会话保持）

```nginx
upstream backend_pool {
    ip_hash;  # 同一客户端 IP 始终路由到同一服务器
    server 192.168.1.10:8080;
    server 192.168.1.11:8080;
    server 192.168.1.12:8080;
    # 适合有状态的服务（Session 未共享时）
}
```

### 3.4 最少连接（Least Connections）

```nginx
upstream backend_pool {
    least_conn;  # 转发到当前活跃连接数最少的服务器
    server 192.168.1.10:8080;
    server 192.168.1.11:8080;
    server 192.168.1.12:8080;
    # 适合请求处理时间差异大的场景
}
```

### 3.5 随机（Random）- Nginx 1.15.1+

```nginx
upstream backend_pool {
    random two least_conn;  # 随机选2个，选连接数少的
    server 192.168.1.10:8080;
    server 192.168.1.11:8080;
    server 192.168.1.12:8080;
}
```

### 负载均衡策略对比

| 策略 | 特点 | 适用场景 |
|------|------|---------|
| 轮询 | 简单均匀 | 请求处理时间相近 |
| 加权轮询 | 按权重分配 | 服务器配置不均 |
| IP Hash | 会话保持 | 有状态服务（无 Session 共享）|
| 最少连接 | 动态均衡 | 请求处理时间差异大 |
| 随机 | 随机分配 | 简单场景 |

### 3.6 后端健康检查

```nginx
upstream backend_pool {
    server 192.168.1.10:8080 max_fails=3 fail_timeout=30s;
    server 192.168.1.11:8080 max_fails=3 fail_timeout=30s;
    server 192.168.1.12:8080 backup;  # 备用服务器（其他全挂时启用）
    
    # max_fails：30s 内失败 3 次则标记为不可用
    # fail_timeout：不可用持续时间，超过后重新尝试
    
    keepalive 32;  # 与后端保持的长连接数
}
```

---

## 四、限流配置

### 4.1 limit_req（请求频率限流）

```nginx
http {
    # 定义限流区域
    # zone=req_zone: 区域名称
    # $binary_remote_addr: 按客户端IP限流（binary格式节省空间）
    # 10m: 共享内存大小（10MB约存16万个IP）
    # rate=10r/s: 每秒最多10个请求
    limit_req_zone $binary_remote_addr zone=req_zone:10m rate=10r/s;
    
    # 也可按 API 路径限流
    limit_req_zone $binary_remote_addr zone=api_zone:10m rate=100r/m;
    
    server {
        location /api/ {
            # burst=20: 允许突发20个请求（令牌桶）
            # nodelay: 突发请求立即处理，不延迟（超出burst则503）
            limit_req zone=req_zone burst=20 nodelay;
            
            # 限流状态码（默认503）
            limit_req_status 429;
            
            proxy_pass http://backend_pool;
        }
        
        location /api/login {
            # 登录接口严格限流：1r/s，无突发
            limit_req zone=req_zone burst=5;
            proxy_pass http://backend_pool;
        }
    }
}
```

### 4.2 limit_conn（并发连接数限流）

```nginx
http {
    # 按IP限制并发连接数
    limit_conn_zone $binary_remote_addr zone=conn_zone:10m;
    
    server {
        location /download/ {
            limit_conn conn_zone 5;      # 每个IP最多5个并发连接
            limit_conn_status 429;
            limit_rate 1m;               # 每个连接限速1MB/s
            limit_rate_after 10m;        # 前10MB不限速，之后限速
            
            alias /data/files/;
        }
    }
}
```

### 4.3 令牌桶 vs 漏桶

```
limit_req 使用漏桶算法：
                   +-----------------+
请求进入 ---> 溢出丢弃 |  bucket(burst)  | -> 以固定速率(rate)处理
                   +-----------------+

nodelay 参数：突发请求立即处理（令牌桶效果），不排队等待
无nodelay：突发请求排队等待，保持 rate 速率输出（漏桶效果）
```

---

## 五、完整生产配置示例

```nginx
# /etc/nginx/nginx.conf

worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 10240;
    use epoll;
    multi_accept on;
}

http {
    include mime.types;
    default_type application/octet-stream;
    
    # 日志格式
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'rt=$request_time uct=$upstream_connect_time '
                    'uht=$upstream_header_time urt=$upstream_response_time';
    
    access_log /var/log/nginx/access.log main;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 20m;   # 最大请求体（上传文件限制）
    
    # Gzip 压缩
    gzip on;
    gzip_min_length 1k;
    gzip_types text/plain text/css application/json application/javascript;
    
    # 限流区域定义
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=100r/s;
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;
    
    # 负载均衡池
    upstream app_servers {
        least_conn;
        server 192.168.1.10:8080 weight=3 max_fails=3 fail_timeout=30s;
        server 192.168.1.11:8080 weight=3 max_fails=3 fail_timeout=30s;
        server 192.168.1.12:8080 weight=2 max_fails=3 fail_timeout=30s;
        keepalive 32;
    }
    
    # HTTP -> HTTPS 重定向
    server {
        listen 80;
        server_name example.com www.example.com;
        return 301 https://$host$request_uri;
    }
    
    # 主 HTTPS 服务器
    server {
        listen 443 ssl http2;
        server_name example.com www.example.com;
        
        ssl_certificate     /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:SSL:10m;
        
        # 安全响应头
        add_header X-Frame-Options DENY;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        
        # 静态资源
        location /static/ {
            alias /data/static/;
            expires 30d;
            add_header Cache-Control "public, immutable";
        }
        
        # API 接口（带限流）
        location /api/ {
            limit_req zone=api_limit burst=200 nodelay;
            limit_conn conn_limit 20;
            limit_req_status 429;
            
            proxy_pass         http://app_servers;
            proxy_http_version 1.1;
            proxy_set_header   Connection "";        # 长连接
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
            
            proxy_connect_timeout 10s;
            proxy_read_timeout    60s;
            
            # 后端错误时的重试
            proxy_next_upstream error timeout invalid_header http_500 http_502;
            proxy_next_upstream_tries 2;
        }
        
        # 前端页面
        location / {
            root /usr/share/nginx/html;
            try_files $uri $uri/ /index.html;  # SPA 路由支持
        }
        
        # 健康检查端点
        location /health {
            access_log off;
            return 200 "OK";
            add_header Content-Type text/plain;
        }
    }
}
```

---

## 六、常用运维命令

```bash
# 检查配置语法
nginx -t

# 重新加载配置（不停服）
nginx -s reload

# 查看 Nginx 状态（需开启 stub_status 模块）
location /nginx_status {
    stub_status;
    allow 127.0.0.1;
    deny all;
}

# 查看实时连接数
netstat -an | grep :80 | grep ESTABLISHED | wc -l

# 查看限流日志
grep "limiting requests" /var/log/nginx/error.log

# 按 IP 统计访问量
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20
```

| 命令 | 说明 |
|------|------|
| `nginx -t` | 验证配置文件语法 |
| `nginx -s reload` | 平滑重载配置 |
| `nginx -s stop` | 快速停止 |
| `nginx -s quit` | 优雅停止（等待请求处理完） |
| `nginx -V` | 查看编译参数和模块 |

---

## 七、总结与延伸

**核心要点**：
- Nginx location 匹配优先级：精确匹配 `=` > 前缀 `^~` > 正则 `~` > 普通前缀，理解优先级是排查路由问题的关键
- 反向代理必须透传 `X-Real-IP` 和 `X-Forwarded-For`，否则后端服务获取不到真实客户端 IP
- 限流 `limit_req`（频率）和 `limit_conn`（并发）配合 `burst` 处理突发流量；`nodelay` 决定突发请求是立即处理还是排队等待
- 负载均衡默认轮询，有状态服务用 `ip_hash`，处理时长差异大用 `least_conn`
- 生产必备：Gzip 压缩、长连接 keepalive、合理的超时时间（connect/send/read 分别配置）、安全响应头

**延伸阅读方向**：
- OpenResty（Nginx + Lua）：在 Nginx 层实现复杂业务逻辑（动态鉴权、灰度发布、限流熔断）
- Nginx 动态 upstream：基于 `nginx-upstream-jdomain` 或 Consul 实现服务发现和动态路由
- APISIX vs Kong：基于 Nginx/OpenResty 的 API 网关，在 Nginx 之上提供插件化的网关能力
- Nginx 性能调优：`worker_processes`、`worker_connections`、epoll 事件模型对高并发的影响
