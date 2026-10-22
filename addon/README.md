# Minimize to Tray Plus — Zotero 7–10 托盘插件

把 Zotero 最小化到系统托盘，并提供一个**带完整右键菜单**的托盘图标（含“退出 Zotero”）。
本项目基于开源项目 [B3000Kcn/minimize-zotero-to-tray](https://github.com/B3000Kcn/minimize-zotero-to-tray) 的思路重写，保留原有“关闭即最小化到托盘”的行为，并修复其托盘图标没有右键菜单、无法从托盘退出的问题。

- 适用平台：Windows 10 / 11（x64）
- 适用版本：Zotero 7.0 – 10.0.x（已在 Windows 11 + Zotero 10.0.6 实测通过）
- 运行依赖：系统自带 Windows PowerShell 5.1（无需额外安装任何运行时）

## 功能

| 行为 | 说明 |
| --- | --- |
| 关闭即最小化 | 点窗口 ×、Alt+F4、任务栏关闭，都只隐藏到托盘，不退出 Zotero |
| 左键单击托盘图标 | 在显示 / 隐藏之间切换（可在设置里改为"仅显示"） |
| 右键单击托盘图标 | 弹出菜单：显示 Zotero、隐藏到托盘、打开首选项、退出 Zotero |
| 退出 Zotero | 右键菜单"退出 Zotero"→ 正常保存并退出；12 秒未退出则强制结束，绝不会"退不掉" |
| 全局热键 | 可选，默认关闭；支持 Ctrl/Alt/Shift/Win + 字母/数字/F1—F24 |
| 静默启动 | 可选，启动后直接只显示托盘图标 |
| 资源管理器重启 | 托盘图标自动重新出现，不需要重启 Zotero |
| 无孤儿进程 | Zotero 退出或崩溃时，托盘助手自动结束；插件被禁用时如窗口处于隐藏状态会先恢复显示 |

## 插件结构

```
minimize-to-tray-plus-1.3.0.xpi
├── manifest.json                 # 插件清单（strict_max_version = 10.0.*）
├── bootstrap.js                  # 生命周期入口：startup/shutdown/onMainWindowLoad
├── prefs.js                      # 默认偏好值
├── README.md
└── content/
    ├── scripts/main.js           # 插件主逻辑：关窗拦截、退出检测、TCP 服务端、助手进程管理
    ├── preferences.xhtml         # 设置面板（托盘行为 / 热键 / 端口 / 排查）
    ├── icons/icon.png            # 插件图标
    └── bin/
        ├── tray-helper.ps1       # 托盘助手（WinForms NotifyIcon + Win32 窗口控制）
        ├── launcher.vbs          # 静默启动器，避免 PowerShell 控制台窗口闪现
        └── tray.ico              # 多尺寸托盘图标（16–256）
```

运行机制：

1. Zotero 启动 → `bootstrap.js` 载入 `main.js`，在 `127.0.0.1` 上监听一个**系统自动分配**的空闲端口，生成一次性令牌。
2. 插件把 `bin/` 下的三个文件释放到 Zotero 配置目录 `…/minimize-to-tray-plus/`，写入 `tray-config.json`（端口、令牌、图标路径、标签文案），再用 `wscript.exe launcher.vbs` 静默启动助手。
3. 助手通过 PID / 可执行文件名定位 `zotero.exe` 的 `MozillaWindowClass` 主窗口，创建托盘图标，并回连插件完成令牌握手。
4. 插件 **→** 助手：`HIDE` / `SHOW` / `TOOLTIP` / `PING` / `EXIT`
   助手 **→** 插件：`HELLO <token>` / `HIDDEN` / `SHOWN` / `MENU_QUIT` / `MENU_PREFS`
5. 窗口的隐藏与恢复由助手用 `ShowWindow` 完成；插件只发指令，不需要 js-ctypes。

## 相对原项目的改动

| # | 原项目问题 | 本版处理 |
| --- | --- | --- |
| 1 | `tray_helper.ahk` 里用了 `Menu, Tray, NoStandard` 清空标准菜单，之后只添加了 `Show/Hide` 一项，**没有"退出"**，右键菜单形同虚设 | 重建完整右键菜单：显示 Zotero、隐藏到托盘、——、打开首选项、——、退出 Zotero |
| 2 | 即使补一个 AHK 的 `Exit`，也只会结束托盘助手进程，Zotero 仍处于“窗口隐藏 + 无托盘图标”的死局 | “退出 Zotero”走协议 `MENU_QUIT` → 插件调用 `Zotero.Utilities.Internal.quit()`（旧版回退 `quitZotero()`）正常退出；另有 12 秒看门狗强制结束兜底 |
| 3 | 依赖预编译二进制 `tray_helper.exe`（AutoHotkey 打包，易被杀软误报、无法审计） | 改为纯文本 PowerShell 脚本 + WinForms `NotifyIcon`，零第三方二进制 |
| 4 | Zotero 侧用 `js-ctypes` 调 `FindWindowW` / `ShowWindow`，官方文档提示在部分 Windows 11 环境会崩 | 窗口控制全部下沉到助手，插件侧不再使用 ctypes（仅保留一个"取 PID"的可选兜底，失败也不影响功能） |
| 5 | 端口固定 23120，冲突时会出现"Zotero 启动即隐藏且无法唤出" | 默认由系统分配空闲端口，并保留 4 个随机高位端口兜底；偏好里填 0 即自动 |
| 6 | Zotero 崩溃后 `tray_helper.exe` 变成孤儿进程，只能手动结束 | 助手检测到连接断开（Zotero 退出/崩溃/插件重载）立即自行退出，不留残留 |
| 7 | 助手被结束后窗口仍是隐藏状态，用户无法恢复 | 助手意外断开时插件自动重启助手（30 秒内最多 3 次）；插件被禁用/卸载时，若窗口处于隐藏状态会先发 `SHOW` 再退出 |
| 8 | 资源管理器重启后托盘图标消失，需要重启 Zotero | 助手监听 `TaskbarCreated` 消息，图标自动重挂 |
| 9 | 热键仅支持单字母/数字，注册失败无任何提示 | 支持 F1—F24；失败写入日志并带 Win32 错误码（如 1409 表示被其他程序占用） |
| 10 | 界面为英文，无排查指引 | 中文界面；设置面板含使用说明与故障排查步骤 |

## Zotero 8–10 兼容性改动（1.3.0）

Zotero 8 起底层升级到 Firefox 140，Zotero 10 沿用同一平台。1.2.0 在 Zotero 10 上会被直接判定“不兼容”而无法安装，本版逐项修复：

| 触发“无法安装”的原因 | 1.3.0 的处理 |
| --- | --- |
| `strict_max_version` 停留在 `8.*`，Zotero 10 直接拒绝安装 | 改为 `10.0.*`（官方文档对 Zotero 10 的要求） |
| 清单缺少 `applications.zotero.update_url`，Zotero 10 会把 XPI 当作无效插件丢弃 | 补充 `update_url` 字段（占位地址，不影响本地使用） |
| `resource://gre/modules/Services.jsm` 在 Firefox 140 已不存在 | 优先用注入的全局 `Services`，退回 `Services.sys.mjs`，最后才试旧 `.jsm` |
| `Zotero.PreferencePanes.register()` 变为 async，返回 Promise<面板 ID> | 按 Promise 取 ID，卸载时用该 ID 注销 |
| `Zotero.Prefs.registerObserver()` 返回 Symbol，注销需回传 Symbol | 保存 Symbol 并在 shutdown 时注销 |
| `Zotero.Utilities.Internal.quitZotero()` 已弃用，改由 `quit()` 承接 | 同时包裹 `quit` / `quitZotero`，托盘“退出”优先调用 `quit()` |
| `nsIProcess.runw()` 签名是 `runw(blocking, args, count)`，少传 `blocking` 会抛错，导致托盘助手根本没被拉起 | 统一改为 `runw(false, args, count)`，并保留同步 `run(false, …)` 兜底、持有进程对象防 GC |

## 安装

1. 关闭 Zotero。
2. 打开 Zotero →「工具」→「插件」→ 右上角齿轮 →「Install Add-on From File…」，选择 `minimize-to-tray-plus-1.3.0.xpi`。
3. 安装完成后**重启 Zotero**（首次安装必须重启，托盘助手在启动时拉起）。
4. 启动后任务栏通知区出现红色 “Z” 图标；点窗口右上角 × 会看到窗口消失、图标仍在。

卸载：插件管理器里「移除」，移除时会先恢复被隐藏的主窗口，并结束托盘助手。

## 设置

「编辑 → 设置 → 最小化到托盘」：

- 关闭按钮最小化到托盘（默认开）
- 启动时自动隐藏（默认关）
- 左键单击动作：切换 / 仅显示
- 全局热键：开关、修饰键、主键（改完自动重启助手，无需重启 Zotero）
- 本地通信端口：0 = 自动分配（推荐）

## 故障排查

1. 托盘图标不见了 / 窗口唤不出来：
   - 先看日志：`%APPDATA%\Zotero\Zotero\Profiles\<随机>.default\minimize-to-tray-plus\tray-helper.log`
   - 日志里 `Add-Type failed` 说明 PowerShell 被组策略限制；`hotkey register ... rc=1409` 说明热键被别的软件占用，换一个组合即可。
2. 被"静默启动 + 窗口隐藏"卡住：任务管理器结束 `zotero.exe`，然后在 Zotero 配置编辑器（设置 → 高级 → 配置编辑器）把 `extensions.minimize-to-tray-plus.startup.autohide` 改为 `false`，再启动。
3. 杀毒软件提示：`content/bin/tray-helper.ps1` 是明文脚本，可直接打开审阅；所有操作仅涉及本机 127.0.0.1 通信与窗口显示状态。
