# setup-task.ps1
# 注册 Windows 定时任务，每隔2天自动发布一篇博客
# 使用管理员权限运行此脚本

#Requires -RunAsAdministrator

param(
    [int]$IntervalDays = 2,     # 发布间隔（天），默认2天
    [string]$TaskName = "BlogAutoPublish",
    [switch]$Remove             # 加 -Remove 参数则删除任务
)

$SCRIPT_PATH = "d:\code\github\blog\scripts\auto-publish.ps1"
$LOG_PATH = "d:\code\github\blog\scripts\publish.log"

# ====== 删除任务 ======
if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "✅ 定时任务 '$TaskName' 已删除。"
    } else {
        Write-Host "任务 '$TaskName' 不存在。"
    }
    exit 0
}

# ====== 注册任务 ======
Write-Host "正在注册定时任务：$TaskName（每 $IntervalDays 天执行一次）..."

# 检查脚本是否存在
if (-not (Test-Path $SCRIPT_PATH)) {
    Write-Error "脚本不存在: $SCRIPT_PATH"
    exit 1
}

# 任务触发器：从明天上午10点开始，每 IntervalDays 天重复一次
$startTime = (Get-Date).Date.AddDays(1).AddHours(10)  # 明天 10:00
$trigger = New-ScheduledTaskTrigger `
    -Daily `
    -DaysInterval $IntervalDays `
    -At $startTime

# 任务动作：使用 PowerShell 运行脚本，输出重定向到日志
$action = New-ScheduledTaskAction `
    -Execute "PowerShell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SCRIPT_PATH`"" `
    -WorkingDirectory "d:\code\github\blog"

# 任务设置
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `  # 最长运行10分钟
    -StartWhenAvailable `            # 错过的任务尽快补跑
    -RunOnlyIfNetworkAvailable `     # 需要网络才运行
    -MultipleInstances IgnoreNew     # 前一次未完成时不重复启动

# 任务主体（使用当前登录用户）
$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType S4U `                 # 无需密码，使用已登录会话
    -RunLevel Highest

# 注册任务
$task = Register-ScheduledTask `
    -TaskName $TaskName `
    -TaskPath "\BlogTools\" `
    -Trigger $trigger `
    -Action $action `
    -Settings $settings `
    -Principal $principal `
    -Description "自动发布博客文章，每 $IntervalDays 天发布一篇。脚本路径：$SCRIPT_PATH" `
    -Force

if ($task) {
    Write-Host ""
    Write-Host "✅ 定时任务注册成功！" -ForegroundColor Green
    Write-Host ""
    Write-Host "  任务名称: $TaskName"
    Write-Host "  任务路径: \BlogTools\$TaskName"
    Write-Host "  发布间隔: 每 $IntervalDays 天"
    Write-Host "  首次运行: $($startTime.ToString('yyyy-MM-dd HH:mm'))"
    Write-Host "  日志文件: $LOG_PATH"
    Write-Host ""
    Write-Host "  立即测试（模拟，不提交）:"
    Write-Host "    pwsh -File `"$SCRIPT_PATH`" -DryRun"
    Write-Host ""
    Write-Host "  立即执行一次（实际发布）:"
    Write-Host "    Start-ScheduledTask -TaskName '$TaskName' -TaskPath '\BlogTools\'"
    Write-Host ""
    Write-Host "  查看任务状态:"
    Write-Host "    Get-ScheduledTask -TaskName '$TaskName'"
    Write-Host ""
    Write-Host "  删除任务:"
    Write-Host "    .\setup-task.ps1 -Remove"
} else {
    Write-Error "任务注册失败，请检查权限。"
    exit 1
}
