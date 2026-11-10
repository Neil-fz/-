#requires -Version 5.1
<#
.SYNOPSIS
    注册“登录 Windows 后自动连接校园网”。

.DESCRIPTION
    两种自启方式，脚本会自动选择：

      1) 计划任务（首选）：Login 触发器 + 隐藏运行 + 进程意外退出自动重启
      2) 启动文件夹（兜底）：往 shell:startup 放一个隐藏启动器，任何情况下都能用，
         不需要管理员权限，也不依赖任务计划服务

    CampusNet.ps1 自带单实例互斥锁，即使两种方式同时存在也只会有 1 个进程工作。
    全部只影响当前用户，不需要管理员权限。

.PARAMETER Mode
    Auto（默认）= 先试计划任务，失败退回启动文件夹；Task = 只用计划任务；Startup = 只用启动文件夹。

.PARAMETER TaskName
    计划任务名称，默认 HaitCampusNet_AutoLogin。

.PARAMETER DelaySeconds
    登录后延时多少秒启动，默认 20 秒（等无线网卡拿到 IP）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-AutoStart.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-AutoStart.ps1 -Mode Startup
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Task', 'Startup')][string]$Mode = 'Auto',
    [string]$TaskName = 'HaitCampusNet_AutoLogin',
    [int]$DelaySeconds = 20
)

$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ps1  = Join-Path $root 'CampusNet.ps1'
$vbs  = Join-Path $root 'Start-Hidden.vbs'
$cfg  = Join-Path $root 'config.json'

function Fail([string]$msg) {
    Write-Host ''
    Write-Host "[失败] $msg" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $ps1)) { Fail "找不到 $ps1" }
if (-not (Test-Path -LiteralPath $cfg)) { Fail "找不到 $cfg" }

# 先确认账号密码填过了，避免装上一个必定失败的自启项
$c = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace([string]$c.userName)) {
    Fail "config.json 里还没有学号，请先运行 1-配置账号.cmd（或 .\CampusNet.ps1 -Setup）"
}
if ([string]::IsNullOrWhiteSpace([string]$c.password) -and [string]::IsNullOrWhiteSpace([string]$c.passwordEnc)) {
    Fail "config.json 里还没有密码，请先运行 1-配置账号.cmd（或 .\CampusNet.ps1 -Setup）"
}

Write-Host ''
Write-Host '===== 注册开机自启 =====' -ForegroundColor Cyan
Write-Host "脚本目录 : $root"
Write-Host "学号     : $($c.userName)   运营商: $($c.operator)"
Write-Host "自启方式 : $Mode"
Write-Host ''

$taskOk = $false
$startupFile = $null

# ---------------- 方式一：计划任务 ----------------
function Install-Task {
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        Write-Host '本机没有 ScheduledTasks 模块，跳过计划任务方式' -ForegroundColor Yellow
        return $false
    }
    try {
        $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
        $action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs)
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        try { $trigger.Delay = ('PT{0}S' -f [Math]::Max(0, $DelaySeconds)) } catch { }
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 999 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $desc = '河南工学院校园网自动登录：登录后在后台隐藏运行 CampusNet.ps1，掉线自动重连。'

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Description $desc -Force | Out-Null

        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { return $true }
        return $false
    } catch {
        Write-Host ("计划任务方式失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

# ---------------- 方式二：启动文件夹 ----------------
function Install-StartupEntry {
    try {
        $startup = [Environment]::GetFolderPath('Startup')
        if ([string]::IsNullOrWhiteSpace($startup)) { throw '系统没有返回启动文件夹路径' }
        $target = Join-Path $startup 'CampusNet_AutoLogin.vbs'

        $body = @"
' 河南工学院校园网自动登录 - 启动文件夹版
' 由 Install-AutoStart.ps1 生成，请勿手改（改路径请重新运行安装脚本）
Option Explicit
Dim shell
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$ps1""", 0, False
"@
        # 内容含中文，必须写成 UTF-16 LE + BOM，wscript 才能正确读取
        [System.IO.File]::WriteAllText($target, $body, (New-Object System.Text.UnicodeEncoding($false, $true)))
        if (-not (Test-Path -LiteralPath $target)) { throw '启动项文件写入失败' }
        return $target
    } catch {
        Write-Host ("启动文件夹方式失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return $null
    }
}

switch ($Mode) {
    'Task'    { $taskOk = Install-Task }
    'Startup' { $startupFile = Install-StartupEntry }
    default {
        $taskOk = Install-Task
        if (-not $taskOk) {
            Write-Host '改用启动文件夹方式…' -ForegroundColor Yellow
            $startupFile = Install-StartupEntry
        }
    }
}

if (-not $taskOk -and -not $startupFile) {
    Fail @'
两种自启方式都失败了。
常见原因：当前 PowerShell 运行在受限环境（沙箱 / 组策略 / 权限被裁剪）。
解决办法：在正常的桌面会话里，右键“3-安装开机自启.cmd”以当前用户身份运行；
         或者手动把 Start-Hidden.vbs 的快捷方式放进  shell:startup  文件夹。
'@
}

Write-Host ''
if ($taskOk) {
    Write-Host "✔ 已注册计划任务：$TaskName" -ForegroundColor Green
    Write-Host  '   （可在“任务计划程序”里查看；进程异常退出会自动重启）'
}
if ($startupFile) {
    Write-Host "✔ 已添加启动项：$startupFile" -ForegroundColor Green
    Write-Host  '   （下次登录 Windows 时自动在后台运行）'
}

Write-Host ''
Write-Host '运行规则：' -ForegroundColor Cyan
Write-Host "  · 登录 Windows 后约 $DelaySeconds 秒自动在后台启动，无窗口、无弹窗"
Write-Host  '  · 连上 HAIT-Student* 后若还没认证，会自动提交认证'
Write-Host  '  · 掉线 / 休眠唤醒 / 换 WiFi 后自动重连（默认每 60 秒巡检）'
Write-Host  '  · 日志目录：' + (Join-Path $root 'log')
Write-Host ''
Write-Host '想马上验证（不用重启）：' -ForegroundColor Yellow
Write-Host '  双击 2-测试登录.cmd' -ForegroundColor Yellow
Write-Host '取消自启：双击 4-卸载开机自启.cmd' -ForegroundColor Yellow
exit 0
