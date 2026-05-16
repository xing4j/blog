# Linux 生产环境日志查询命令技巧

<div class="post-meta">📅 2026-05-16 &nbsp;·&nbsp; 🏷️ <span class="tag">Linux</span> <span class="tag">运维</span></div>

生产环境出现问题时，快速定位日志往往决定了故障恢复的速度。本文整理日常排查中高频使用的日志查询命令及组合技巧，覆盖实时跟踪、关键字过滤、上下文提取、时间范围查询等场景。

---

## 一、基础查看命令

### tail — 查看文件末尾（最常用）

```bash
# 查看最后 100 行
tail -n 100 app.log

# 实时滚动跟踪（生产排查必备）
tail -f app.log

# 跟踪多个文件，自动显示文件名
tail -f /var/log/nginx/access.log /var/log/nginx/error.log

# 从第 500 行开始显示到末尾
tail -n +500 app.log
```

### head — 查看文件开头

```bash
# 查看前 50 行
head -n 50 app.log
```

### cat / tac — 全量输出

```bash
# 正序输出（小文件用）
cat app.log

# 逆序输出（最新日志在最前）
tac app.log | head -n 100
```

### less — 交互式翻页（大文件首选）

```bash
less app.log
```

`less` 常用快捷键：

| 按键 | 动作 |
|------|------|
| `G` | 跳到文件末尾 |
| `g` | 跳到文件开头 |
| `/keyword` | 向下搜索 |
| `?keyword` | 向上搜索 |
| `n` / `N` | 下一个 / 上一个匹配 |
| `q` | 退出 |
| `F` | 类似 `tail -f` 实时跟踪 |

---

## 二、grep — 关键字过滤（核心命令）

```bash
# 基本过滤
grep "ERROR" app.log

# 忽略大小写
grep -i "error" app.log

# 显示行号
grep -n "NullPointerException" app.log

# 统计匹配行数
grep -c "ERROR" app.log

# 反向过滤（排除包含 DEBUG 的行）
grep -v "DEBUG" app.log

# 过滤多个关键字（OR 关系）
grep -E "ERROR|WARN|Exception" app.log

# 递归搜索目录下所有日志文件
grep -r "OutOfMemoryError" /var/log/
```

### 上下文输出（排查关联日志极为重要）

```bash
# 匹配行 + 后 5 行（After）
grep -A 5 "ERROR" app.log

# 匹配行 + 前 3 行（Before）
grep -B 3 "Exception" app.log

# 匹配行 + 前后各 5 行（Context）
grep -C 5 "connection refused" app.log
```

### 组合过滤

```bash
# 过滤 ERROR 且不包含 health check
grep "ERROR" app.log | grep -v "health"

# 过滤 ERROR 后统计每种错误出现次数
grep "ERROR" app.log | awk '{print $NF}' | sort | uniq -c | sort -rn

# 过滤特定线程的日志（Spring Boot 日志常见场景）
grep "\[http-nio-8080-exec-3\]" app.log
```

---

## 三、时间范围查询

生产日志通常带有时间戳（如 `2026-05-16 14:23:01`），可以结合 `grep` 快速截取时段日志。

```bash
# 查询某一分钟的日志
grep "2026-05-16 14:23" app.log

# 查询某一小时的日志
grep "2026-05-16 14:" app.log

# 查询多个时间段（14:20 ~ 14:25）
grep -E "2026-05-16 14:2[0-5]" app.log

# 结合 sed 截取时间段（从 14:00 到 14:30）
sed -n '/2026-05-16 14:00/,/2026-05-16 14:30/p' app.log
```

> **技巧**：生产日志量大时，先用 `grep` 缩小时间范围再做二次过滤，避免全文扫描。

---

## 四、awk — 结构化日志字段提取

`awk` 适合处理有固定格式的日志（如 Nginx access log、Spring Boot 日志）。

### 提取特定字段

```bash
# Nginx access.log 格式：IP - - [时间] "METHOD URL" 状态码 大小
# 提取所有请求的 IP 和状态码
awk '{print $1, $9}' /var/log/nginx/access.log

# 只看 500 错误的请求 URL
awk '$9 == "500" {print $7}' /var/log/nginx/access.log

# 统计各状态码出现次数
awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn
```

### 统计慢请求 / 高频 IP

```bash
# 统计访问最多的前 10 个 IP
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10

# 找出响应时间超过 3 秒的请求（access.log 含 $request_time 字段时）
awk '$NF > 3 {print $0}' /var/log/nginx/access.log
```

---

## 五、sed — 流式编辑与范围提取

```bash
# 提取第 100~200 行
sed -n '100,200p' app.log

# 提取从某关键字到另一关键字之间的行
sed -n '/Transaction started/,/Transaction committed/p' app.log

# 删除空行后查看
sed '/^$/d' app.log | less

# 替换敏感信息后输出（不修改原文件）
sed 's/password=[^ ]*/password=***/g' app.log
```

---

## 六、实时监控与多文件跟踪

### multitail — 多窗口实时跟踪

```bash
# 安装
yum install -y multitail   # CentOS
apt install -y multitail   # Ubuntu

# 同时跟踪两个文件，分屏显示
multitail app.log error.log

# 高亮关键字
multitail -e "ERROR" app.log
```

### tail -f + grep — 实时过滤

```bash
# 实时只看 ERROR 行
tail -f app.log | grep --line-buffered "ERROR"

# 实时过滤并高亮（需要 grep 支持颜色）
tail -f app.log | grep --color=always -E "ERROR|WARN|$"

# 实时查看某个请求 ID 的全链路日志
tail -f app.log | grep --line-buffered "traceId=abc123"
```

---

## 七、日志文件操作技巧

### 处理压缩日志

```bash
# 直接查看 .gz 压缩日志（无需解压）
zcat app.log.2026-05-15.gz | grep "ERROR"
zless app.log.2026-05-15.gz
zgrep "Exception" app.log.2026-05-15.gz

# 多个压缩文件联合查询
zcat app.log.*.gz | grep "2026-05-15 10:" | grep "ERROR"
```

### 统计日志量与增速

```bash
# 查看文件大小
ls -lh app.log

# 实时监控文件大小变化
watch -n 2 'ls -lh app.log'

# 统计每分钟日志行数（判断流量是否异常）
grep "2026-05-16 14" app.log | awk '{print $1,$2}' | cut -c1-16 | uniq -c
```

### 快速定位大日志中的时间点

```bash
# 查看日志文件总行数
wc -l app.log

# 二分法快速定位：查看中间位置的时间戳
awk 'NR==50000' app.log
```

---

## 八、journalctl — systemd 服务日志

对于用 systemd 管理的服务（如 Nginx、Java 应用），优先使用 `journalctl`：

```bash
# 查看某服务的最新日志
journalctl -u myapp.service -n 100

# 实时跟踪
journalctl -u myapp.service -f

# 查看某时间段的日志
journalctl -u myapp.service --since "2026-05-16 14:00" --until "2026-05-16 15:00"

# 只看错误级别
journalctl -u myapp.service -p err

# 查看本次启动以来的日志
journalctl -u myapp.service -b

# 输出为 JSON 格式（便于进一步处理）
journalctl -u myapp.service -o json | jq '.MESSAGE'
```

---

## 九、常用排查场景速查

### 场景一：服务刚出现 500 错误，快速定位

```bash
# 1. 确认 500 错误时间点
grep " 500 " /var/log/nginx/access.log | tail -20

# 2. 根据时间点查应用日志
grep "2026-05-16 14:23" /opt/app/logs/app.log | grep -E "ERROR|Exception"

# 3. 查看异常完整堆栈（上下文 20 行）
grep -A 20 "NullPointerException" /opt/app/logs/app.log | tail -40
```

### 场景二：定位某个接口的慢请求

```bash
# Nginx 日志中找响应时间最长的请求（含 $request_time）
awk '{print $NF, $7}' /var/log/nginx/access.log | sort -rn | head -20
```

### 场景三：内存溢出（OOM）排查

```bash
# 系统日志中找 OOM Killer 记录
grep -i "out of memory\|oom killer" /var/log/messages
dmesg | grep -i "killed process"
```

### 场景四：统计指定时段的错误频率

```bash
# 按分钟统计 ERROR 数量（快速看是否有错误突刺）
grep "ERROR" app.log | grep "2026-05-16 14:" \
  | awk '{print $1,$2}' | cut -c1-16 \
  | uniq -c | sort -k2
```

---

## 十、实用别名配置

将常用命令组合保存到 `~/.bashrc`，提升效率：

```bash
# 实时监控应用日志并过滤 ERROR
alias logerr='tail -f /opt/app/logs/app.log | grep --line-buffered -E "ERROR|Exception"'

# 查看最近 1 小时的错误
alias log1h='grep "$(date +"%Y-%m-%d %H:")" /opt/app/logs/app.log | grep "ERROR"'

# 快速查看 Nginx 500 错误
alias ng500='grep " 500 " /var/log/nginx/access.log | tail -50'

# 生效
source ~/.bashrc
```

---

## 总结

| 场景 | 首选命令 |
|------|---------|
| 实时跟踪 | `tail -f` + `grep --line-buffered` |
| 关键字过滤 + 上下文 | `grep -C N` |
| 时间段截取 | `grep "时间前缀"` 或 `sed -n '/时间1/,/时间2/p'` |
| 结构化字段统计 | `awk` + `sort` + `uniq -c` |
| 压缩历史日志 | `zcat` / `zgrep` |
| systemd 服务日志 | `journalctl -u 服务名 -f` |
| 大文件翻页 | `less`（`F` 键实时跟踪，`/` 搜索）|

掌握这些命令组合，生产排查时就能在分钟内从海量日志中锁定问题根因。
