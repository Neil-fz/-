# 河南工学院校园网 · 开机自动连接

一个**不用安装任何软件**的校园网自动认证工具：登录 Windows 后在后台悄悄连上 `HAIT-Student*`，
掉线自动重连，全程无窗口、无弹窗。只用 Windows 自带的 PowerShell 5.1 就能跑。

适用：河南工学院（HAIT）校园无线网 Portal 认证
认证门户：`http://211.69.15.10:6060`

---

## 一、最快用法：双击 `0-一键开始.cmd`

双击后只做一件事——回答三个问题，剩下的它自己做完（配置 → 测试 → 装自启）：

```
Step 1/3 : account setup
请输入学号：2023010101              ← 输入你的学号，回车
请选择学号绑定的运营商：            ← 输入 1/2/3/4，回车（1移动 2联通 3电信 4本地）
  1) 中国移动  2) 中国联通  3) 中国电信  4) 本地账号
请输入校园网密码（输入时不显示）：   ← 输入密码（屏幕上不会有星号，正常现象），回车
```

看到 `已保存到 config.json` → 自动测试 → 看到 `✔ 已注册计划任务` 就全部完成，之后开机会自动连网。

> 第一次配置前，请先用浏览器打开 `1.1.1.1` 确认自己能正常登录（账号没欠费、运营商绑定没问题），
> 否则自动登录也一定失败。

## 二、一步一步来（想看清楚每一步时用）

| 步骤 | 操作 | 说明 |
| --- | --- | --- |
| ① | 双击 **`1-配置账号.cmd`** | 输学号、选运营商、输密码（密码用 Windows DPAPI 加密保存，不存明文） |
| ② | 双击 **`2-测试登录.cmd`** | 看到「认证成功 / 已联网」就说明账号密码没问题 |
| ③ | 双击 **`3-安装开机自启.cmd`** | 注册计划任务（失败会自动改用启动文件夹），不需要管理员权限 |
| ④ | 重启或重新登录一次 Windows | 之后就不用手动连网了 |

想立刻看效果：装完后直接双击 `2-测试登录.cmd`，或者注销再登录。
想取消：双击 **`4-卸载开机自启.cmd`**。
想看状态：双击 **`5-查看状态.cmd`**；想看认证参数：双击 **`6-诊断门户.cmd`**。

---

## 三、运营商怎么选

学校门户里的 `userid` 是「学号 + 运营商后缀」，选错了会提示账号或密码不正确：

| 选项 | 后缀 | 含义 |
| --- | --- | --- |
| `1` 中国移动 | `@gxyyd` | 手机号是中国移动 |
| `2` 中国联通 | `@gxylt` | 手机号是中国联通 |
| `3` 中国电信 | `@gxydx` | 手机号是中国电信 |
| `4` 本地账号 | `@gxylocal` | 没绑运营商 / 单宽用户 |

例：学号 `2023010101` + 移动 → 实际提交 `2023010101@gxyyd`。

---

## 四、目录里的文件

| 文件 | 作用 |
| --- | --- |
| `CampusNet.ps1` | 主程序：联网检测 + Portal 认证 + 后台巡检 |
| `config.json` | 配置（学号、密码密文、运营商、间隔等） |
| `0-一键开始.cmd` | **推荐**：配置 + 测试 + 装自启，一条龙 |
| `1-配置账号.cmd` | 配置向导（只改账号密码时用） |
| `2-测试登录.cmd` | 只跑一次，检查能不能登录 |
| `3-安装开机自启.cmd` | 注册自启 |
| `4-卸载开机自启.cmd` | 取消自启并结束进程 |
| `5-查看状态.cmd` | 看 WiFi、IP、是否联网、门户是否可达 |
| `6-诊断门户.cmd` | 打印认证时会用到的全部参数（含脚本拼出的登录页地址），不提交密码 |
| `Install-AutoStart.ps1` / `Uninstall-AutoStart.ps1` | 上面两个 cmd 实际调用的脚本 |
| `Start-Hidden.vbs` | 计划任务用的隐藏启动器（0 号窗口，不闪黑框） |
| `log\campusnet-YYYYMMDD.log` | 运行日志，默认保留 14 天 |

---

## 五、config.json 各项含义

```jsonc
{
  "userName": "学号",              // 必填
  "password": "",                  // 明文密码（用 -Setup 配置后会被清空）
  "passwordEnc": "...",            // DPAPI 密文，只有本机本用户能解开
  "operator": "yd",                // yd 移动 / lt 联通 / dx 电信 / local 本地
  "operatorSuffix": {              // 门户要求的后缀，一般不用改
    "local": "@gxylocal", "yd": "@gxyyd", "lt": "@gxylt", "dx": "@gxydx"
  },
  "portalHost": "http://211.69.15.10:6060",  // 认证门户地址
  "wlanacname": "HAIT-SR8808",     // 无线控制器名称（门户参数）
  "wlanuserip": "",                // 留空=自动取本机 IP；只有排查问题时才手填
  "enforceSsid": true,             // 只在校园 WiFi 上才认证
  "ssidPattern": "HAIT-Student*",  // 校园 WiFi 名称（宿舍区是 HAIT-Student-5G-xx）
  "checkIntervalSeconds": 60,      // 在线时多久巡检一次
  "retryIntervalSeconds": 10,      // 失败后首次重试间隔（会翻倍，最长 180 秒）
  "maxRetryIntervalSeconds": 180,
  "wrongPasswordBackoffSeconds": 300,  // 密码错误后等 5 分钟再试，避免账号被锁
  "onlineCheckUrls": [ "..." ],    // 联网检测探针（204 探测）
  "logRetentionDays": 14
}
```

改完 `config.json` 不需要重装自启，下次巡检就会生效。

---

## 六、工作原理（想自己改脚本可以看）

1. **判断是否真的联网**：请求 `http://connect.rom.miui.com/generate_204`，
   返回 `204` 说明外网通；如果被 AC 劫持成登录页（200/302），就认为掉线。
2. **确定认证参数**：访问 `http://1.1.1.1`，让无线控制器把浏览器重定向到
   `http://211.69.15.10:6060/portalReceiveAction.do?wlanuserip=本机IP&wlanacname=HAIT-SR8808`，
   从跳转地址里取出本次的 `wlanuserip` / `wlanacname`（IP 变了也能自适应）。
3. **取门户一次性配置**：`GET /PortalJsonAction.do?wlanuserip=..&wlanacname=..&viewStatus=2`
   拿到 `timestamp`、`uuid`、`portalpageid`、网关 IP `serverip`、门户版本号。
   本校这套 `authByRas` 为 `false`，账号密码**不加密**直接提交。
4. **提交认证**：

   ```
   GET http://211.69.15.10:6060/quickauth.do
       ?userid=学号@gxyyd&passwd=密码
       &wlanuserip=本机IP&wlanuseripv6=&wlanacname=HAIT-SR8808
       &wlanacIp=172.21.8.73&ssid=HAIT-Student-5G-3&vlan=&mac=
       &version=0&portalpageid=21&validateCode=
       &timestamp=...&uuid=...&portaltype=0&hostname=&bindCtrlId=
   ```

   返回 JSON：`code=0` 成功，`7` 账号或密码不正确，`236` 需绑定运营商账号，`201` 已在线，`1` 被 AC 拒绝。
5. **常驻巡检**：成功后续每 60 秒复检一次，掉线立即重连；休眠唤醒、换 WiFi、IP 变化都能处理。

---

## 七、常见问题

**Q：提示「认证失败 code=7 账号或密码不正确」**
A：先用浏览器登录一次确认；注意运营商要选对；确认后重新双击 `1-配置账号.cmd`。

**Q：提示「236 需要先绑定运营商账号」**
A：去学校自助平台把宽带账号/手机号跟学号绑定，再回来测试。

**Q：提示「201 已在线」**
A：账号已经在别的设备（或手机）上登录，学校限制多设备，先让原设备下线。

**Q：一直提示连不上门户（不可达）**
A：确认连的是 `HAIT-Student*` 而不是手机热点；学校如果调整了认证服务器地址，改
`config.json` 里的 `portalHost` / `wlanacname` 即可（用浏览器打开 `1.1.1.1` 看新地址）。

**Q：装自启时提示「拒绝访问」**
A：说明当前 PowerShell 权限被裁剪（沙箱 / 组策略）。用普通桌面会话右键
`3-安装开机自启.cmd` 以当前用户身份运行即可；脚本会自动改用「启动文件夹」方式，
那条路不依赖任务计划服务。

**Q：电脑睡眠唤醒后要等一会儿才通**
A：正常。脚本每 60 秒巡检一次，最多 1 分钟左右自动恢复。嫌慢可把
`checkIntervalSeconds` 改小（例如 20）。

**Q：双击 .cmd 没反应 / 窗口一闪就没了**
A：先确认双击的是 `.cmd` 而不是 `.ps1`（`.ps1` 双击是用记事本打开）。如果窗口一闪而过，
在文件夹空白处按住 Shift 右键 →「在此处打开 PowerShell 窗口」，然后依次运行：

```powershell
.\CampusNet.ps1 -Setup
.\CampusNet.ps1 -Once
.\Install-AutoStart.ps1
```

**Q：提示「无法加载文件，因为在此系统上禁止运行脚本」**
A：这是 PowerShell 执行策略限制。用文件夹里的 `.cmd` 启动就自动带了 `-ExecutionPolicy Bypass`；
如果手动敲命令，请写成：

```powershell
powershell -ExecutionPolicy Bypass -File .\CampusNet.ps1 -Setup
```

**Q：怎么看它到底在后台干活了没有？**
A：看 `log\campusnet-日期.log`，正常的记录长这样：

```
[2026-11-10 07:31:12] [INFO] 监控已启动：在线检测 60s / 重试 10s / 最大重试间隔 180s
[2026-11-10 07:31:43] [INFO] 认证成功：认证成功
[2026-11-10 07:31:46] [INFO] 网络已连通（HAIT-Student-5G-3 / 10.50.177.18）
```

**Q：会不会跟室友的账号互相顶下线？**
A：不会。脚本只用你自己配置的账号；但如果你的账号同时在手机登录，学校可能会把电脑顶下线，
脚本发现掉线会重连，表现为两边反复挤号。建议手机不用时断开。

**Q：换电脑 / 重装系统后报「密码无法解密」**
A：DPAPI 密文只在本机本用户有效。重新双击 `1-配置账号.cmd` 输一次密码即可。

---

## 八、安全与合规

- 密码默认用 Windows DPAPI 加密（`ConvertFrom-SecureString`），
  只有当前 Windows 用户在本机能解开；文件被拷走也读不出明文。
- 日志里**不会**记录密码，认证 URL 也不会写进日志。
- 本工具只是把你手动在网页上做的事自动化，仅限本人账号使用；请遵守学校网络管理规定。
