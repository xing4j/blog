Set-Location "d:\code\github\blog"
$postsDir  = "d:\code\github\blog\docs\posts"
$queueFile = "d:\code\github\blog\scripts\post-queue.json"

$queueJson = Get-Content $queueFile -Raw -Encoding UTF8 | ConvertFrom-Json

# ===== 使用与 _gen-dates.ps1 完全相同的算法 =====
$seed = 2024516
$rng = [System.Random]::new($seed)
$startDate = [datetime]"2024-05-17"
$endDate   = [datetime]"2026-05-15"
$totalDays = ($endDate - $startDate).Days
$count = $queueJson.Count

$rawDates = @()
for ($i = 0; $i -lt $count; $i++) {
    $progress  = if ($count -gt 1) { $i / ($count - 1) } else { 0 }
    $baseDays  = [int]($progress * $totalDays)
    $jitter    = $rng.Next(-6, 7)
    $dayOffset = [Math]::Max(0, [Math]::Min($totalDays, $baseDays + $jitter))
    $rawDates += $startDate.AddDays($dayOffset)
}

$finalDates = @()
foreach ($date in $rawDates) {
    if ($rng.Next(10) -lt 7) {
        $dow = [int]$date.DayOfWeek
        if ($dow -ne 0 -and $dow -ne 6) {
            if ($dow -le 3) {
                $date = if ($rng.Next(2) -eq 0) { $date.AddDays(-$dow) } else { $date.AddDays(6 - $dow) }
            } else {
                $date = $date.AddDays(6 - $dow)
            }
        }
    }
    $finalDates += $date
}

# ===== 执行重命名 + 内容更新 =====
$updatedQueue = @()
$renamed = 0
$contentUpdated = 0

for ($i = 0; $i -lt $count; $i++) {
    $item    = $queueJson[$i]
    $newDate = $finalDates[$i].ToString("yyyy-MM-dd")
    $oldName = $item.filename
    $oldPath = Join-Path $postsDir $oldName

    # 计算新文件名（替换日期前缀）
    $newName = $oldName -replace '^\d{4}-\d{2}-\d{2}', $newDate
    $newPath = Join-Path $postsDir $newName

    # 1. 更新文件内容（替换 post-meta 中的日期）
    if (Test-Path $oldPath) {
        $content = Get-Content $oldPath -Raw -Encoding UTF8
        $oldDateInContent = ($oldName -replace '^(\d{4}-\d{2}-\d{2}).*','$1')
        $newContent = $content -replace [regex]::Escape($oldDateInContent), $newDate
        if ($newContent -ne $content) {
            Set-Content $oldPath $newContent -Encoding UTF8 -NoNewline
            $contentUpdated++
        }

        # 2. 重命名文件
        if ($oldName -ne $newName) {
            Rename-Item -Path $oldPath -NewName $newName -Force
            $renamed++
        }
    } else {
        Write-Warning "File not found: $oldPath"
    }

    # 3. 更新 queue 条目
    $newCommit = $item.commitMessage -replace '\d{4}-\d{2}-\d{2}', $newDate
    $updatedQueue += [PSCustomObject]@{
        filename      = $newName
        title         = $item.title
        category      = $item.category
        commitMessage = $item.commitMessage
    }
}

# 4. 保存更新后的 post-queue.json
$updatedQueue | ConvertTo-Json -Depth 5 | Set-Content $queueFile -Encoding UTF8

Write-Host "Files renamed   : $renamed"
Write-Host "Content updated : $contentUpdated"
Write-Host "Queue saved."

# 5. git add 所有变动
git add docs/posts/ scripts/post-queue.json
$staged = (git diff --cached --name-only | Measure-Object -Line).Lines
Write-Host "Git staged      : $staged files"
