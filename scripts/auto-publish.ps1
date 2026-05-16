# auto-publish.ps1
# 自动发布博客文章脚本
# 用途：从 post-queue.json 取第一篇文章，更新索引文件，提交并推送到 GitHub

param(
    [switch]$DryRun  # 加 -DryRun 参数则只模拟，不实际提交推送
)

# ====== 配置 ======
$REPO_ROOT = "d:\code\github\blog"
$POSTS_DIR = "$REPO_ROOT\docs\posts"
$QUEUE_FILE = "$REPO_ROOT\scripts\post-queue.json"
$LOG_FILE = "$REPO_ROOT\scripts\publish.log"
$SIDEBAR_FILE = "$REPO_ROOT\docs\_sidebar.md"
$ARCHIVE_FILE = "$REPO_ROOT\docs\posts\README.md"
$HOME_FILE = "$REPO_ROOT\docs\README.md"
$MAX_SIDEBAR_RECENT = 5  # 侧边栏显示最近文章数

# ====== 工具函数 ======
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
    Write-Host $line
}

function Exit-WithError {
    param([string]$Message)
    Write-Log $Message "ERROR"
    exit 1
}

# ====== 主流程 ======
Write-Log "====== 开始自动发布 ======"

# 1. 读取队列
if (-not (Test-Path $QUEUE_FILE)) {
    Exit-WithError "队列文件不存在: $QUEUE_FILE"
}

$queue = Get-Content $QUEUE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
if ($queue.Count -eq 0) {
    Write-Log "队列为空，无文章待发布。" "WARN"
    exit 0
}

$post = $queue[0]
$postFile = Join-Path $POSTS_DIR $post.filename
$date = $post.filename -replace '^(\d{4}-\d{2}-\d{2}).*', '$1'

Write-Log "待发布: $($post.title) [$($post.filename)]"

# 2. 检查文章文件是否存在
if (-not (Test-Path $postFile)) {
    Exit-WithError "文章文件不存在: $postFile"
}

# 3. 更新 _sidebar.md（近期文章，最多显示 MAX_SIDEBAR_RECENT 篇）
Write-Log "更新侧边栏 _sidebar.md ..."
$sidebarContent = Get-Content $SIDEBAR_FILE -Raw -Encoding UTF8

$newLink = "  - [$($post.title)](posts/$($post.filename))"

# 提取近期文章列表（找到 **近期文章** 区块下的条目）
if ($sidebarContent -match '(?s)(\*\*近期文章\*\*\s*\n)(.*?)(\n\s*-\s*\*\*)') {
    $existingLinks = $Matches[2] -split "`n" | Where-Object { $_ -match '^\s+-\s+\[' }
    $updatedLinks = @($newLink) + $existingLinks | Select-Object -First $MAX_SIDEBAR_RECENT
    $newBlock = "**近期文章**`n" + ($updatedLinks -join "`n") + "`n"
    $sidebarContent = $sidebarContent -replace '(?s)\*\*近期文章\*\*\s*\n.*?(\n\s*-\s*\*\*)', "$newBlock`$1"
} else {
    Write-Log "未找到近期文章区块，在文件开头添加" "WARN"
    $sidebarContent = "- **近期文章**`n$newLink`n`n" + $sidebarContent
}

if (-not $DryRun) {
    Set-Content $SIDEBAR_FILE $sidebarContent -Encoding UTF8 -NoNewline
}

# 4. 更新归档页 docs/posts/README.md
Write-Log "更新归档页 README.md ..."
$archiveContent = Get-Content $ARCHIVE_FILE -Raw -Encoding UTF8
$archiveLink = "- [$($post.title)](posts/$($post.filename)) - $date"

# 根据分类插入到对应区块
$categorySection = "## $($post.category)"

if ($archiveContent -match [regex]::Escape($categorySection)) {
    # 在分类标题下方第一行插入
    $archiveContent = $archiveContent -replace "($([regex]::Escape($categorySection))\s*\n)", "`$1$archiveLink`n"
} else {
    # 分类不存在，在文件末尾追加
    $archiveContent = $archiveContent.TrimEnd() + "`n`n$categorySection`n`n$archiveLink`n"
}

if (-not $DryRun) {
    Set-Content $ARCHIVE_FILE $archiveContent -Encoding UTF8 -NoNewline
}

# 5. 更新首页 docs/README.md（最新文章表格，最多显示5篇）
Write-Log "更新首页 README.md ..."
$homeContent = Get-Content $HOME_FILE -Raw -Encoding UTF8
$newRow = "| [$($post.title)](posts/$($post.filename)) | $($post.category) | $date |"

if ($homeContent -match '(?s)(\|\s*文章标题.*?\|\s*\n\|[-|]+\|\s*\n)(.*?)(\n\n)') {
    $tableHeader = $Matches[1]
    $tableRows = $Matches[2] -split "`n" | Where-Object { $_ -match '^\|' }
    $updatedRows = @($newRow) + $tableRows | Select-Object -First 5
    $newTable = $tableHeader + ($updatedRows -join "`n") + "`n"
    $homeContent = $homeContent -replace '(?s)(\|\s*文章标题.*?\|\s*\n\|[-|]+\|\s*\n).*?(\n\n)', "$newTable`$2"
}

if (-not $DryRun) {
    Set-Content $HOME_FILE $homeContent -Encoding UTF8 -NoNewline
}

# 6. Git 操作
Write-Log "执行 git add ..."
if (-not $DryRun) {
    Set-Location $REPO_ROOT
    git add "$postFile" "$SIDEBAR_FILE" "$ARCHIVE_FILE" "$HOME_FILE"
    
    $gitStatus = git status --short
    Write-Log "git status: $gitStatus"
    
    Write-Log "执行 git commit ..."
    git commit -m "$($post.commitMessage)"
    
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "git commit 失败"
    }
    
    Write-Log "执行 git push ..."
    git push origin main
    
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "git push 失败，请检查网络或权限"
    }
    
    Write-Log "git push 成功！"
} else {
    Write-Log "[DryRun] 跳过 git add/commit/push"
}

# 7. 更新队列（移除已发布的第一篇）
Write-Log "更新队列，移除已发布条目 ..."
$remainingQueue = $queue | Select-Object -Skip 1
$remainingJson = $remainingQueue | ConvertTo-Json -Depth 5 -Ensure:0

if ($remainingQueue.Count -eq 0) {
    $remainingJson = "[]"
}

if (-not $DryRun) {
    Set-Content $QUEUE_FILE $remainingJson -Encoding UTF8
}

# 8. 完成
$remaining = $queue.Count - 1
Write-Log "✅ 发布成功: $($post.title)"
Write-Log "队列剩余: $remaining 篇"
Write-Log "====== 发布完成 ======"
