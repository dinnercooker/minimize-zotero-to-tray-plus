# Minimize to Tray Plus

把 Zotero 最小化到系统托盘，托盘图标带**完整右键菜单**（显示 / 隐藏 / 打开首选项 / **退出 Zotero**）。
A maintained fork of [B3000Kcn/minimize-zotero-to-tray](https://github.com/B3000Kcn/minimize-zotero-to-tray), rewritten for Zotero 8–10 and with a working tray context menu.

- 适用平台：Windows 10 / 11（x64）
- 适用版本：Zotero **7.0 – 10.0.x**（已在 Windows 11 + Zotero 10.0.6 实测通过）
- 运行依赖：系统自带 Windows PowerShell 5.1，无第三方二进制、无需额外运行时

## 为什么要另起一版

上游插件的托盘助手是用 AutoHotkey 写的，里面有一行 `Menu, Tray, NoStandard`，把 AHK 自带的“暂停/退出”等标准菜单项全部清空，之后只补了一个 `Show/Hide`。结果是：

1. 右键菜单里**没有退出项**；
2. 就算补一个 AHK 的 `Exit`，也只能结束托盘助手进程——此时 Zotero 主窗口已被 `SW_HIDE` 隐藏、托盘图标又已消失，用户会卡在“窗口看不见、进程也关不掉”的死局；
3. 上游最后提交停在 2025-07，`strict_max_version` 仍为 `7.*`，Zotero 8 起就装不上。

本仓库保留“关闭即最小化到托盘”的行为，重写托盘助手并补齐退出链路。

## 功能

| 行为 | 说明 |
| --- | --- |
| 关闭即最小化 | 点窗口 ×、Alt+F4、任务栏关闭，都只隐藏到托盘，不退出 Zotero |
| 右键菜单 | 显示 Zotero / 隐藏到托盘 / 打开首选项 / **退出 Zotero** |
| 退出 Zotero | 走 `MENU_QUIT` → `Zotero.Utilities.Internal.quit()` 正常保存退出；12 秒看门狗强制结束兜底 |
| 左键单击图标 | 显示 / 隐藏切换（可在设置里改为“仅显示”） |
| 全局热键 | 可选，默认关闭；支持 Ctrl/Alt/Shift/Win + 字母/数字/F1—F24 |
| 静默启动 | 可选，启动后只留托盘图标 |
| 无孤儿进程 | Zotero 退出或崩溃时助手自动结束；助手意外死亡会被插件自动拉起 |
| 资源管理器重启 | 监听 `TaskbarCreated`，托盘图标自动重挂 |

## 安装

1. 关闭 Zotero；
2. 到 [Releases](../../releases) 下载 `minimize-to-tray-plus-1.3.0.xpi`；
3. Zotero →「工具」→「插件」→ 右上齿轮 →「Install Add-on From File…」，选中该 xpi；
4. **重启 Zotero**（首次安装必须重启，托盘助手在启动时拉起）；
5. 通知区出现红色 “Z” 图标，右键即可看到“退出 Zotero”。

## 从源码构建

```bash
python build/gen_icon.py     # 生成 tray.ico / icon.png（纯 Python，无第三方依赖）
python build/pack.py         # 打包到 dist/minimize-to-tray-plus-<version>.xpi 并自检
```

开发调试可把 `addon/` 目录以代理文件方式挂到 Zotero 配置目录：

```
<profile>/extensions/minimize-to-tray-plus@local   # 内容为 addon/ 的绝对路径
```

代理文件生效后需删除 `<profile>/extensions.json` 并用 `-purgecaches` 启动。

## 项目结构

```
addon/
├── manifest.json            # 清单（strict_max_version = 10.0.*）
├── bootstrap.js             # 生命周期入口
├── prefs.js                 # 默认偏好
├── content/
│   ├── scripts/main.js      # 关窗拦截、退出检测、TCP 服务端、助手进程管理
│   ├── preferences.xhtml    # 设置面板
│   ├── icons/icon.png
│   └── bin/
│       ├── tray-helper.ps1  # 托盘助手：WinForms NotifyIcon + Win32 窗口控制
│       ├── launcher.vbs     # 静默启动器，避免控制台闪窗
│       └── tray.ico         # 多尺寸图标（16–256）
build/
├── gen_icon.py              # 手写 PNG/ICO 编码器
├── pack.py                  # 打包 + 自检
├── test-plugin.js           # Node 侧单元测试（mock Zotero/XPCOM，14 项断言）
├── test-harness.ps1         # 假 MozillaWindowClass 窗口 + mock 服务端，4 种场景
└── verify-real.js           # 真机端到端验证（临时 profile 装 XPI 并启动 Zotero）
```

运行机制、协议细节、故障排查见 [addon/README.md](addon/README.md)。

## 与上游的主要差异

| # | 上游 | 本版 |
| --- | --- | --- |
| 1 | 托盘菜单被 `NoStandard` 清空，只有 Show/Hide | 完整菜单，含“退出 Zotero” |
| 2 | 退出只能杀助手进程，Zotero 卡死 | 菜单退出 → `quit()` 正常退出 + 12 秒强杀兜底 |
| 3 | 依赖预编译 `tray_helper.exe`（易误报、不可审计） | 纯文本 PowerShell 5.1 + WinForms，零第三方二进制 |
| 4 | 插件侧 js-ctypes 调 `ShowWindow`（部分环境崩溃） | 窗口控制全部下沉到助手进程，插件侧零 ctypes |
| 5 | 端口固定 23120，冲突时“启动即隐藏且唤不出” | 系统自动分配端口 + 随机高位端口兜底 |
| 6 | 崩溃后留下孤儿进程 | 连接断开即自退，无残留 |
| 7 | 隐藏后助手被结束就无法恢复 | 助手自动重启（30 秒内最多 3 次）；插件被禁用时先 `SHOW` 再退出 |
| 8 | 资源管理器重启后图标消失 | 监听 `TaskbarCreated` 自动重挂 |
| 9 | 热键仅支持单字母，失败无提示 | 支持 F1—F24，失败记录 Win32 错误码 |

## Zotero 8–10 兼容性要点

Zotero 8 起底层升级到 Firefox 140（Zotero 10 沿用），1.2.0 在 Zotero 10 上会被直接判“不兼容”：

- `strict_max_version` → `10.0.*`；
- 补 `applications.zotero.update_url`：缺失时 Zotero 10 会把 XPI 当作无效插件直接丢弃；
- `resource://gre/modules/Services.jsm` 已移除 → 优先用注入的全局 `Services`，回退 `Services.sys.mjs`；
- `Zotero.PreferencePanes.register()` 变为 async，返回 `Promise<面板 ID>`；
- `Zotero.Prefs.registerObserver()` 返回 Symbol，注销需回传该 Symbol；
- `quitZotero()` 已弃用 → 改调 `quit()`（两者都做包裹以兼容旧版）；
- `nsIProcess.runw()` 签名是 `runw(blocking, args, count)`，少传 `blocking` 会抛错，导致托盘助手根本起不来。

## 测试

```bash
node build/test-plugin.js                                   # 插件侧逻辑单元测试
powershell -File build/test-harness.ps1 -Mode window         # 窗口隐藏/恢复
powershell -File build/test-harness.ps1 -Mode hotkey         # 全局热键
powershell -File build/test-harness.ps1 -Mode quit           # 菜单退出链路
powershell -File build/test-harness.ps1 -Mode disconnect     # 断连自退
node build/verify-real.js                                    # 真机：装 XPI 启动 Zotero 并检查助手
```

## 许可与致谢

MIT License，见 [LICENSE](LICENSE)。托盘最小化到托盘的原始思路与初始实现来自 [B3000Kcn/minimize-zotero-to-tray](https://github.com/B3000Kcn/minimize-zotero-to-tray)（MIT），本仓库在其基础上重写并适配 Zotero 8–10。
