#requires -Version 5.1
<#
.SYNOPSIS
    取消开机自动连接校园网，并结束正在后台运行的监控进程。

.DESCRIPTION
    会依次清理：
      1) 计划任务 HaitCampusNet_AutoLogin
      2) 启动文件夹里的 CampusNet_AutoLogin.vbs
      3) 正在运行的 CampusNet.ps1 进程
    配置文件、日志不会删除。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoStart.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'HaitCampusNet_AutoLogin'
)

$ErrorActionPreference = 'Continue'

Write-Host ''
Write-Host '===== 取消开机自启 =====' -ForegroundColor Cyan

# ---- 1) 计划任务 ----
$removedTask = $false
if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            $removedTask = $true
        } catch {
            Write-Host ("删除计划任务失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}
if ($removedTask) {
    Write-Host "✔ 已删除计划任务：$TaskName" -ForegroundColor Green
} else {
    Write-Host "· 没有找到计划任务 $TaskName（可能未安装，或已被删除）"
}

# ---- 2) 启动文件夹 ----
$removedStartup = $false
try {
    $startup = [Environment]::GetFolderPath('Startup')
    if ($startup) {
        $f = Join-Path $startup 'CampusNet_AutoLogin.vbs'
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f -Force -ErrorAction Stop
            $removedStartup = $true
        }
    }
} catch {
    Write-Host ("删除启动项失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
}
if ($removedStartup) {
    Write-Host '✔ 已删除启动文件夹里的自启项' -ForegroundColor Green
} else {
    Write-Host '· 启动文件夹里没有自启项'
}

# ---- 3) 结束正在运行的监控进程 ----
$killed = 0
try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*CampusNet.ps1*' } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch { }
        }
} catch { }

if ($killed -gt 0) {
    Write-Host ("✔ 已结束 {0} 个正在运行的监控进程" -f $killed) -ForegroundColor Green
} else {
    Write-Host '· 没有正在运行的监控进程'
}

Write-Host ''
Write-Host '已取消开机自启。配置文件和日志都还在，重新安装请双击 3-安装开机自启.cmd' -ForegroundColor Cyan
exit 0
