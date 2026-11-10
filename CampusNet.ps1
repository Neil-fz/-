#requires -Version 5.1
<#
.SYNOPSIS
    河南工学院（HAIT）校园网自动登录 / 掉线重连 / 开机自启

.DESCRIPTION
    校园无线网（HAIT-Student*）采用 Portal 网页认证，认证入口为
        http://211.69.15.10:6060/portalReceiveAction.do
    本脚本直接调用门户背后的认证接口 /quickauth.do 完成登录，不需要打开浏览器，
    也不需要安装任何第三方软件（Windows 自带的 PowerShell 即可运行）。

    工作方式：
      1. 用 204 探针判断当前是否真的能上外网；
      2. 未联网时，先向门户取一次配置（/PortalJsonAction.do 拿到 timestamp、uuid 等），
         再按“学号+运营商后缀”提交认证；
      3. 认证成功后常驻后台，定时检测，掉线自动重连。

.PARAMETER Setup
    交互式配置向导：录入学号、密码、运营商，密码用当前 Windows 用户 DPAPI 加密保存。

.PARAMETER Status
    只打印当前网络与账号状态，不做任何登录动作。

.PARAMETER Probe
    诊断模式：把“认证时会用到的每一个参数”打印出来（1.1.1.1 捕获到的门户地址、
    wlanuserip、wlanacname、timestamp、uuid 等），但不会提交密码、不会发起认证。

.PARAMETER Once
    只检测并尝试登录一次，然后退出（返回码 0=已在线/登录成功，1=失败）。

.PARAMETER Force
    配合 -Once 使用：即使检测到已联网也强制发起一次认证，便于排查。

.PARAMETER ConfigPath
    指定配置文件路径，默认为脚本目录下的 config.json。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\CampusNet.ps1 -Setup

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\CampusNet.ps1 -Probe

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\CampusNet.ps1 -Status

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\CampusNet.ps1 -Once -Force
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Status,
    [switch]$Probe,
    [switch]$Once,
    [switch]$Force,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$script:Root    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ConfPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $script:Root 'config.json' }
$script:LogDir  = Join-Path $script:Root 'log'
$script:Config  = $null
$script:WasOnline = $false

# =====================================================================
# 日志
# =====================================================================
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $line = ('[{0}] [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    Write-Host $line
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        $file = Join-Path $script:LogDir ('campusnet-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    } catch {
        # 日志写不进去不影响主流程
    }
}

function Remove-OldLog {
    param([int]$Days = 14)
    if ($Days -le 0) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { return }
        $limit = (Get-Date).AddDays(-$Days)
        Get-ChildItem -LiteralPath $script:LogDir -Filter 'campusnet-*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

# =====================================================================
# 配置
# =====================================================================
function Get-DefaultConfig {
    return [ordered]@{
        userName               = ''
        password               = ''
        passwordEnc            = ''
        operator               = 'yd'                 # yd=移动 lt=联通 dx=电信 local=本地/未绑定
        operatorSuffix         = [ordered]@{
            local = '@gxylocal'
            yd    = '@gxyyd'
            lt    = '@gxylt'
            dx    = '@gxydx'
        }
        portalHost             = 'http://211.69.15.10:6060'
        wlanacname             = 'HAIT-SR8808'
        wlanuserip             = ''                   # 留空=自动取本机 IP
        enforceSsid            = $true
        ssidPattern            = 'HAIT-Student*'
        checkIntervalSeconds   = 60
        retryIntervalSeconds   = 10
        maxRetryIntervalSeconds = 180
        wrongPasswordBackoffSeconds = 300
        onlineCheckUrls        = @(
            'http://connect.rom.miui.com/generate_204',
            'http://www.msftconnecttest.com/connecttest.txt',
            'http://www.baidu.com'
        )
        logRetentionDays       = 14
    }
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $script:ConfPath)) {
        throw "找不到配置文件：$($script:ConfPath)"
    }
    $raw = Get-Content -LiteralPath $script:ConfPath -Raw -Encoding UTF8
    $cfg = $null
    try { $cfg = $raw | ConvertFrom-Json } catch { throw "config.json 格式有误：$($_.Exception.Message)" }
    if (-not $cfg) { throw 'config.json 内容为空' }

    $defaults = Get-DefaultConfig
    $names = @($cfg.PSObject.Properties.Name)
    foreach ($k in $defaults.Keys) {
        if (-not ($names -contains $k) -or $null -eq $cfg.$k) {
            $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force
        }
    }
    if ($cfg.onlineCheckUrls -is [string]) { $cfg.onlineCheckUrls = @([string]$cfg.onlineCheckUrls) }
    if (-not $cfg.operatorSuffix) { $cfg.operatorSuffix = $defaults.operatorSuffix }
    return $cfg
}

function Save-Config {
    param($Config)
    $json = $Config | ConvertTo-Json -Depth 8
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($script:ConfPath, $json, $enc)
}

function Get-PasswordPlain {
    $cfg = $script:Config
    if (-not [string]::IsNullOrWhiteSpace([string]$cfg.passwordEnc)) {
        try {
            $sec = ConvertTo-SecureString ([string]$cfg.passwordEnc)
            $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        } catch {
            throw '已保存的密码无法解密（可能换了 Windows 用户或换了电脑），请重新运行 -Setup'
        }
    }
    return [string]$cfg.password
}

# =====================================================================
# HTTP（不依赖 IE 引擎，可控超时、不跟随跳转）
# =====================================================================
function Invoke-Http {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 8,
        [switch]$NoRedirect
    )
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
        $req.Accept = '*/*'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.AllowAutoRedirect = (-not $NoRedirect)
        $req.Proxy = $null
        $req.KeepAlive = $false

        try {
            $resp = $req.GetResponse()
        } catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            if (-not $resp) { return $null }
        }

        $status = [int]$resp.StatusCode
        $headers = @{}
        foreach ($k in $resp.Headers.AllKeys) { $headers[$k] = $resp.Headers[$k] }

        $content = ''
        try {
            $stream = $resp.GetResponseStream()
            if ($stream) {
                $ms = New-Object System.IO.MemoryStream
                $stream.CopyTo($ms)
                $content = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            }
        } catch { }

        return [pscustomobject]@{
            StatusCode = $status
            Headers    = $headers
            Content    = $content
        }
    } catch {
        return $null
    } finally {
        if ($resp) { try { $resp.Close() } catch { } }
    }
}

function New-QueryString {
    param($Table)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Table.Keys) {
        $parts.Add(('{0}={1}' -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Table[$k])))
    }
    return ($parts -join '&')
}

# =====================================================================
# 网络状态
# =====================================================================
function Test-Online {
    $urls = $script:Config.onlineCheckUrls
    if ($urls -is [string]) { $urls = @($urls) }
    foreach ($u in $urls) {
        if ([string]::IsNullOrWhiteSpace([string]$u)) { continue }
        $r = Invoke-Http -Url ([string]$u) -TimeoutSec 5
        if (-not $r) { continue }
        if ($r.StatusCode -eq 204) { return $true }
        if ([string]$u -match 'generate_204') { continue }
        if ([string]$u -match 'connecttest' -and $r.Content -match 'Microsoft Connect Test') { return $true }
        if ([string]$u -match 'baidu' -and $r.Content -match 'baidu\.com') { return $true }
        # 其它探针：200 且看起来不像被门户劫持的页面
        if ($r.StatusCode -eq 200 -and $r.Content -notmatch 'portalReceiveAction|PortalJsonAction|quickauth\.do') { return $true }
    }
    return $false
}

function Get-LocalIpv4 {
    # 首选纯 .NET 枚举（不需要管理员权限，也不依赖 CIM/WMI）：
    # 在“已连接、有 IPv4、且配置了默认网关”的网卡里挑一个，无线网卡优先。
    try {
        $best = $null
        foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($n.OperationalStatus -ne 'Up') { continue }
            if ($n.NetworkInterfaceType -eq 'Loopback') { continue }
            $props = $n.GetIPProperties()

            $addr = $props.UnicastAddresses |
                Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.IPAddressToString -notlike '169.254.*' } |
                Select-Object -First 1
            if (-not $addr) { continue }

            $hasGateway = [bool]($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' })
            $score = 0
            if ($hasGateway) { $score += 10 }
            if ($n.NetworkInterfaceType -eq 'Wireless80211') { $score += 5 }

            if (-not $best -or $score -gt $best.Score) {
                $best = [pscustomobject]@{ Score = $score; Ip = $addr.Address.IPAddressToString }
            }
        }
        if ($best) { return $best.Ip }
    } catch { }

    # 兜底：按默认路由找网卡
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($route) {
            $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1
            if ($addr) { return $addr.IPAddress }
        }
    } catch { }

    try {
        $addr = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -First 1
        if ($addr) { return $addr.IPAddress }
    } catch { }

    return $null
}

function Get-WifiSsid {
    # 1) 网络连接配置文件（普通用户即可读取，Windows 11 上比 netsh 更可靠）
    try {
        $p = Get-NetConnectionProfile -ErrorAction Stop |
            Where-Object { $_.InterfaceAlias -match 'WLAN|Wi-?Fi|无线' } |
            Select-Object -First 1
        if ($p -and $p.Name) { return [string]$p.Name }
    } catch { }

    # 2) netsh（部分机器非管理员或关闭定位时会报 error 5，此时返回空字符串）
    try {
        $out = & netsh wlan show interfaces 2>$null
        foreach ($line in $out) {
            if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1] }
        }
    } catch { }
    return ''
}

# =====================================================================
# 认证
# =====================================================================
function Resolve-PortalTarget {
    param([string]$LocalIp)

    $cfg  = $script:Config
    $base = ([string]$cfg.portalHost).TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'http://211.69.15.10:6060' }
    $ip = $LocalIp
    $ac = [string]$cfg.wlanacname
    if ([string]::IsNullOrWhiteSpace($ac)) { $ac = 'HAIT-SR8808' }

    # 首选：访问 1.1.1.1，让 AC 把我们重定向到带真实 wlanuserip / wlanacname 的门户。
    # 注意：已认证或不在校园网时，1.1.1.1 会跳到真实的 Cloudflare，必须过滤掉，
    # 否则会把门户地址误判成 1.1.1.1。
    foreach ($probe in @('http://1.1.1.1/', 'http://1.1.1.1')) {
        $r = Invoke-Http -Url $probe -TimeoutSec 4 -NoRedirect
        if (-not $r) { continue }
        $candidate = $null
        if ($r.Headers['Location']) {
            $candidate = [string]$r.Headers['Location']
        } elseif ($r.Content -match '(https?://[A-Za-z0-9\.\-]+(:\d+)?/[^"''<>\s]*wlanuserip=[^"''<>\s]*)') {
            $candidate = $Matches[1]
        }
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($candidate -notmatch '^https?://') { continue }
        if ($candidate -notmatch 'wlanuserip=') { continue }        # 不是门户跳转
        if ($candidate -match '^https?://1\.1\.1\.1([:/]|$)') { continue }

        if ($candidate -match '[?&]wlanuserip=([^&]+)') {
            $v = [uri]::UnescapeDataString($Matches[1])
            if ($v -match '^\d{1,3}(\.\d{1,3}){3}$') { $ip = $v }
        }
        if ($candidate -match '[?&]wlanacname=([^&]+)') {
            $ac = [uri]::UnescapeDataString($Matches[1])
        }
        if ($candidate -match '^(https?://[^/]+)') {
            $base = $Matches[1].TrimEnd('/')
        }
        break
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$cfg.wlanuserip)) { $ip = [string]$cfg.wlanuserip }

    return [pscustomobject]@{ Base = $base; Ip = $ip; AcName = $ac }
}

function Get-FailHint {
    param([string]$Code, [string]$Message)
    switch ($Code) {
        '7'   { return '账号或密码不正确，请先确认能在浏览器里登录，再运行 -Setup 重新录入' }
        '236' { return '该账号需要先在自助平台绑定运营商账号（手机号）后才能上网' }
        '201' { return '该账号已在其它设备上线，请先在原设备下线' }
        '1'   { return '认证被 AC 拒绝，常见原因是账号欠费、超出在线设备数或运营商绑定错误（原因 21 / Limit）' }
        '235' { return '密码格式不符合学校要求，需要大小写字母+数字+符号中的三种，请先改密码' }
        default {
            if ($Message) { return $Message }
            return "未知错误（code=$Code）"
        }
    }
}

function Invoke-Login {
    $cfg = $script:Config

    if ([string]::IsNullOrWhiteSpace([string]$cfg.userName)) {
        throw 'config.json 里的 userName（学号）还是空的，请先运行 .\CampusNet.ps1 -Setup'
    }
    $pwd = Get-PasswordPlain
    if ([string]::IsNullOrEmpty($pwd)) {
        throw '还没有填写密码，请先运行 .\CampusNet.ps1 -Setup'
    }

    $op = [string]$cfg.operator
    $suffix = ''
    if ($cfg.operatorSuffix -and $op) {
        $suffix = [string]$cfg.operatorSuffix.$op
    }
    if (-not $suffix) {
        throw "运营商配置无效（operator=$op），可选值：yd / lt / dx / local"
    }

    $localIp = Get-LocalIpv4
    if (-not $localIp) { throw '没有取到本机 IPv4 地址，请先连接校园网 WiFi' }

    $target = Resolve-PortalTarget -LocalIp $localIp
    Write-Log ('认证目标 {0}   wlanuserip={1}   wlanacname={2}' -f $target.Base, $target.Ip, $target.AcName) DEBUG

    # 1) 取门户配置（timestamp / uuid / 网关 IP / 版本号）
    $cfgUrl = $target.Base + '/PortalJsonAction.do?' + (New-QueryString ([ordered]@{
        wlanuserip = $target.Ip
        wlanacname = $target.AcName
        viewStatus = '2'
    }))
    $r1 = Invoke-Http -Url $cfgUrl -TimeoutSec 10
    if (-not $r1 -or $r1.StatusCode -ne 200 -or [string]::IsNullOrWhiteSpace($r1.Content)) {
        throw "无法获取门户配置（$cfgUrl），请确认已连接校园网"
    }
    try { $j = $r1.Content | ConvertFrom-Json } catch { throw '门户返回的配置无法解析' }

    $pc = $j.portalconfig
    $sf = $j.serverForm
    if (-not $pc) { throw '门户返回的配置缺少 portalconfig 字段' }

    # 2) 提交认证。注意：这个 URL 里带密码，任何时候都不要写进日志
    $body = [ordered]@{
        userid       = [string]$cfg.userName + $suffix
        passwd       = $pwd
        wlanuserip   = $target.Ip
        wlanuseripv6 = ''
        wlanacname   = $target.AcName
        wlanacIp     = [string]$sf.serverip
        ssid         = (Get-WifiSsid)
        vlan         = ''
        mac          = ''
        version      = [string]$sf.portalVer
        portalpageid = [string]$pc.id
        validateCode = ''
        timestamp    = [string]$pc.timestamp
        uuid         = [string]$pc.uuid
        portaltype   = '0'
        hostname     = ''
        bindCtrlId   = ''
    }
    $authUrl = $target.Base + '/quickauth.do?' + (New-QueryString $body)
    $r2 = Invoke-Http -Url $authUrl -TimeoutSec 15
    if (-not $r2 -or [string]::IsNullOrWhiteSpace($r2.Content)) {
        throw '认证接口没有响应（门户不可达或网络未就绪）'
    }

    $res = $null
    try { $res = $r2.Content | ConvertFrom-Json } catch { throw "认证接口返回异常：$($r2.Content)" }
    if (-not $res.PSObject.Properties.Name.Contains('code')) { throw "认证接口返回异常：$($r2.Content)" }

    $code = [string]$res.code
    return [pscustomobject]@{
        Ok      = ($code -eq '0')
        Code    = $code
        Message = [string]$res.message
    }
}

# =====================================================================
# 各种运行模式
# =====================================================================
function Invoke-Setup {
    Write-Host ''
    Write-Host '===== 河南工学院校园网 · 配置向导 =====' -ForegroundColor Cyan
    $cfg = $script:Config

    $tip = if ($cfg.userName) { "（当前：$($cfg.userName)，直接回车保持不变）" } else { '' }
    $u = Read-Host "请输入学号 $tip"
    if (-not [string]::IsNullOrWhiteSpace($u)) { $cfg.userName = $u.Trim() }

    Write-Host '请选择学号绑定的运营商：'
    Write-Host '  1) 中国移动'
    Write-Host '  2) 中国联通'
    Write-Host '  3) 中国电信'
    Write-Host '  4) 本地账号 / 未绑定运营商'
    $tip = if ($cfg.operator) { "（当前：$($cfg.operator)，直接回车保持不变）" } else { '' }
    $sel = Read-Host "请输入序号 $tip"
    switch ($sel.Trim()) {
        '1' { $cfg.operator = 'yd' }
        '2' { $cfg.operator = 'lt' }
        '3' { $cfg.operator = 'dx' }
        '4' { $cfg.operator = 'local' }
    }

    $sec = Read-Host '请输入校园网密码（输入时不显示，直接回车保持不变）' -AsSecureString
    $plain = ''
    if ($sec.Length -gt 0) {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    if (-not [string]::IsNullOrEmpty($plain)) {
        $cfg.passwordEnc = ConvertFrom-SecureString $sec   # 用当前 Windows 用户身份加密
        $cfg.password = ''
    }

    Save-Config -Config $cfg
    $script:Config = $cfg

    Write-Host ''
    Write-Host '已保存到 config.json：' -ForegroundColor Green
    Write-Host ("  学号   : {0}" -f $cfg.userName)
    Write-Host ("  运营商 : {0}  （认证账号 {1}）" -f $cfg.operator, ($cfg.userName + [string]$cfg.operatorSuffix.([string]$cfg.operator)))
    Write-Host ("  密码   : {0}" -f $(if ($cfg.passwordEnc) { '已用 Windows DPAPI 加密保存' } else { '明文保存（建议重新运行 -Setup 加密）' }))
    Write-Host ''
    Write-Host '下一步：运行  .\CampusNet.ps1 -Once  测试能否登录成功' -ForegroundColor Yellow
    Write-Host '成功后再运行  .\Install-AutoStart.ps1  注册开机自启' -ForegroundColor Yellow
}

function Invoke-PrintStatus {
    $cfg = $script:Config
    $ssid = Get-WifiSsid
    $ip = Get-LocalIpv4
    $online = Test-Online

    $base = ([string]$cfg.portalHost).TrimEnd('/')
    $portalOk = $false
    if ($base) {
        $r = Invoke-Http -Url ($base + '/PortalJsonAction.do?wlanuserip=' + [uri]::EscapeDataString([string]$ip) + '&wlanacname=' + [uri]::EscapeDataString([string]$cfg.wlanacname) + '&viewStatus=2') -TimeoutSec 8
        $portalOk = ($null -ne $r -and $r.StatusCode -eq 200)
    }

    $acct = if ($cfg.userName) { $cfg.userName + [string]$cfg.operatorSuffix.([string]$cfg.operator) } else { '（未配置）' }

    Write-Host ''
    Write-Host '===== 校园网状态 =====' -ForegroundColor Cyan
    Write-Host ('  无线信号   : {0}' -f $(if ($ssid) { $ssid } else { '（取不到 SSID：可能是非管理员运行或系统未开启定位，不影响登录）' }))
    Write-Host ('  本机 IPv4  : {0}' -f $(if ($ip) { $ip } else { '（无）' }))
    Write-Host ('  外网连通   : {0}' -f $(if ($online) { '已联网' } else { '未联网（需要认证）' }))
    Write-Host ('  认证门户   : {0}' -f $(if ($portalOk) { "$base 可达" } else { "$base 不可达" }))
    Write-Host ('  配置文件   : {0}' -f $script:ConfPath)
    Write-Host ('  登录账号   : {0}' -f $acct)
    Write-Host ('  登录密码   : {0}' -f $(if ($cfg.passwordEnc) { '已加密保存' } elseif ($cfg.password) { '明文保存' } else { '（未配置）' }))
    Write-Host ''
}

function Invoke-Probe {
    $cfg = $script:Config
    Write-Host ''
    Write-Host '===== 认证参数诊断（只读，不会提交密码） =====' -ForegroundColor Cyan

    $ip   = Get-LocalIpv4
    $ssid = Get-WifiSsid
    Write-Host ('  本机 IPv4  : {0}' -f $(if ($ip) { $ip } else { '（取不到）' }))
    Write-Host ('  无线信号   : {0}' -f $(if ($ssid) { $ssid } else { '（取不到 SSID，不影响认证）' }))
    Write-Host ('  外网连通   : {0}' -f $(if (Test-Online) { '已联网' } else { '未联网' }))

    Write-Host ''
    Write-Host '  [1] 访问 1.1.1.1，看 AC 把我们重定向到哪个认证页' -ForegroundColor Cyan
    foreach ($probe in @('http://1.1.1.1/', 'http://1.1.1.1')) {
        $r = Invoke-Http -Url $probe -TimeoutSec 5 -NoRedirect
        if (-not $r) { Write-Host ("      {0} -> 无响应" -f $probe); continue }
        Write-Host ("      {0} -> HTTP {1}" -f $probe, $r.StatusCode)
        $loc = [string]$r.Headers['Location']
        if ($loc) { Write-Host ("      Location: {0}" -f $loc) }

        $cand = $loc
        if ([string]::IsNullOrWhiteSpace($cand) -and $r.Content -match '(https?://[A-Za-z0-9\.\-]+(:\d+)?/[^"''<>\s]*wlanuserip=[^"''<>\s]*)') {
            $cand = $Matches[1]
        }
        if ([string]::IsNullOrWhiteSpace($cand)) { continue }
        if ($cand -match '^https?://' -and $cand -match 'wlanuserip=' -and $cand -notmatch '^https?://1\.1\.1\.1([:/]|$)') {
            Write-Host '      -> 捕获到门户地址（与浏览器弹出的那条一致）' -ForegroundColor Green
        } else {
            Write-Host '      -> 不是校园门户跳转（1.1.1.1 指向了公网），已忽略，改用配置文件里的地址' -ForegroundColor Yellow
        }
    }

    $target = Resolve-PortalTarget -LocalIp $ip
    Write-Host ''
    Write-Host '  [2] 本次认证实际使用的目标' -ForegroundColor Cyan
    Write-Host ("      门户地址   : {0}" -f $target.Base)
    Write-Host ("      wlanuserip : {0}" -f $target.Ip)
    Write-Host ("      wlanacname : {0}" -f $target.AcName)
    Write-Host ("      登录页     : {0}/portalReceiveAction.do?wlanuserip={1}&wlanacname={2}" -f $target.Base, $target.Ip, [uri]::EscapeDataString($target.AcName))

    Write-Host ''
    Write-Host '  [3] 门户返回的一次性配置（/PortalJsonAction.do）' -ForegroundColor Cyan
    $u = $target.Base + '/PortalJsonAction.do?' + (New-QueryString ([ordered]@{
        wlanuserip = $target.Ip; wlanacname = $target.AcName; viewStatus = '2'
    }))
    $r = Invoke-Http -Url $u -TimeoutSec 10
    if (-not $r -or $r.StatusCode -ne 200) {
        Write-Host '      取不到门户配置：门户不可达（请确认连的是 HAIT-Student*）' -ForegroundColor Red
        return
    }
    try { $j = $r.Content | ConvertFrom-Json } catch {
        Write-Host '      门户返回的内容无法解析' -ForegroundColor Red
        return
    }
    $pc = $j.portalconfig
    $sf = $j.serverForm
    Write-Host ("      portalpageid : {0}" -f $pc.id)
    Write-Host ("      timestamp    : {0}" -f $pc.timestamp)
    Write-Host ("      uuid         : {0}" -f $pc.uuid)
    Write-Host ("      wlanacIp     : {0}" -f $sf.serverip)
    Write-Host ("      portalVer    : {0}" -f $sf.portalVer)
    Write-Host ("      authByRas    : {0} （False = 密码明文提交，和浏览器一致）" -f $j.authByRas)
    Write-Host ("      需要验证码   : {0}" -f $(if ([string]$pc.listpasscode -ne '0') { '是' } else { '否' }))

    Write-Host ''
    Write-Host '  [4] 将要提交的登录参数（密码不显示）' -ForegroundColor Cyan
    $suffix = ''
    if ($cfg.operatorSuffix -and $cfg.operator) { $suffix = [string]$cfg.operatorSuffix.([string]$cfg.operator) }
    if ([string]::IsNullOrWhiteSpace([string]$cfg.userName)) {
        Write-Host '      userName 还没配置，请先运行 1-配置账号.cmd' -ForegroundColor Yellow
    } else {
        Write-Host ("      userid : {0}{1}" -f $cfg.userName, $suffix)
        $pwLen = 0
        try { $pwLen = (Get-PasswordPlain).Length } catch { $pwLen = -1 }
        if ($pwLen -lt 0) {
            Write-Host '      passwd : 密码无法解密，请重新运行 1-配置账号.cmd' -ForegroundColor Yellow
        } else {
            Write-Host ("      passwd : ***（{0} 位，{1}）" -f $pwLen, $(if ($cfg.passwordEnc) { 'DPAPI 密文' } else { '明文配置' }))
        }
    }
    Write-Host ("      实际请求      : {0}/quickauth.do?userid=<账号>&passwd=***&wlanuserip={1}&wlanacname={2}&wlanacIp={3}&timestamp=...&uuid=..." -f $target.Base, $target.Ip, $target.AcName, $sf.serverip)
    Write-Host ''
    Write-Host '  这些参数和浏览器登录时提交的完全一致；接着双击 2-测试登录.cmd 就会真正认证。' -ForegroundColor Green
    Write-Host ''
}

function Invoke-OnceMode {
    if (-not $Force) {
        if (Test-Online) {
            Write-Log '当前已经联网，校园网认证仍然有效，无需重新登录'
            Write-Log '想验证账号密码是否正确：先在浏览器打开 1.1.1.1 点“断开连接”，再运行本测试'
            return $true
        }
        Write-Log '当前未联网，开始认证…'
    } else {
        Write-Log '强制认证模式（-Force）'
    }

    try {
        $r = Invoke-Login
        if ($r.Ok) {
            Write-Log ('认证成功：{0}' -f $r.Message)
            Start-Sleep -Seconds 2
            if (Test-Online) { Write-Log '联网检测通过，校园网已可用'; return $true }
            Write-Log '认证接口返回成功，但联网检测仍未通过（可能刚生效，或账号已被其它设备顶下线）' WARN
            return $false
        }
        Write-Log ('认证失败 code={0}：{1}' -f $r.Code, (Get-FailHint -Code $r.Code -Message $r.Message)) WARN
        return $false
    } catch {
        Write-Log ('认证异常：{0}' -f $_.Exception.Message) ERROR
        return $false
    }
}

function Invoke-WatchLoop {
    $cfg = $script:Config
    $retry = [int]$cfg.retryIntervalSeconds
    if ($retry -lt 5) { $retry = 5 }
    $maxRetry = [int]$cfg.maxRetryIntervalSeconds
    if ($maxRetry -lt $retry) { $maxRetry = $retry }

    Write-Log ('监控已启动：在线检测 {0}s / 重试 {1}s / 最大重试间隔 {2}s' -f $cfg.checkIntervalSeconds, $retry, $maxRetry)

    while ($true) {
        $ip = Get-LocalIpv4
        if (-not $ip) {
            Write-Log '没有可用的 IPv4 地址（可能还没连上网络），10 秒后再试' DEBUG
            Start-Sleep -Seconds 10
            continue
        }

        $ssid = Get-WifiSsid
        if ($cfg.enforceSsid -and $ssid -and $cfg.ssidPattern -and ($ssid -notlike [string]$cfg.ssidPattern)) {
            Write-Log ('当前 WiFi 是 "{0}"，不属于校园网 "{1}"，暂不认证' -f $ssid, $cfg.ssidPattern) DEBUG
            Start-Sleep -Seconds 30
            continue
        }

        if (Test-Online) {
            if (-not $script:WasOnline) {
                Write-Log ('网络已连通（{0} / {1}）' -f $(if ($ssid) { $ssid } else { '有线' }), $ip)
            }
            $script:WasOnline = $true
            $retry = [int]$cfg.retryIntervalSeconds
            Start-Sleep -Seconds ([int]$cfg.checkIntervalSeconds)
            continue
        }

        if ($script:WasOnline) { Write-Log '检测到断网，准备重新认证' WARN }
        $script:WasOnline = $false

        try {
            $r = Invoke-Login
            if ($r.Ok) {
                Write-Log ('认证成功：{0}' -f $r.Message)
                Start-Sleep -Seconds 3
                if (Test-Online) { $script:WasOnline = $true }
                $retry = [int]$cfg.retryIntervalSeconds
                Start-Sleep -Seconds 5
            } else {
                Write-Log ('认证失败 code={0}：{1}' -f $r.Code, (Get-FailHint -Code $r.Code -Message $r.Message)) WARN
                if ($r.Code -eq '7') {
                    Start-Sleep -Seconds ([int]$cfg.wrongPasswordBackoffSeconds)
                } else {
                    Start-Sleep -Seconds $retry
                    $retry = [Math]::Min($retry * 2, $maxRetry)
                }
            }
        } catch {
            Write-Log ('认证异常：{0}' -f $_.Exception.Message) ERROR
            Start-Sleep -Seconds $retry
            $retry = [Math]::Min([Math]::Max($retry * 2, 10), $maxRetry)
        }
    }
}

# =====================================================================
# 入口
# =====================================================================
try {
    $script:Config = Get-Config
    Remove-OldLog -Days ([int]$script:Config.logRetentionDays)

    if ($Setup)  { Invoke-Setup; exit 0 }
    if ($Status) { Invoke-PrintStatus; exit 0 }
    if ($Probe)  { Invoke-Probe; exit 0 }
    if ($Once) {
        $ok = Invoke-OnceMode
        if ($ok) { exit 0 } else { exit 1 }
    }

    # 常驻模式：单实例保护
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\HaitCampusNetAutoLogin', [ref]$createdNew)
    if (-not $createdNew) {
        Write-Log '已经有一个校园网监控进程在运行，本实例退出'
        exit 0
    }
    try {
        Invoke-WatchLoop
    } finally {
        try { $mutex.ReleaseMutex() } catch { }
        try { $mutex.Dispose() } catch { }
    }
} catch {
    Write-Log ('发生异常：{0}' -f $_.Exception.Message) ERROR
    exit 1
}
