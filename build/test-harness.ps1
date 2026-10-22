# 托盘助手自动化测试台（仅用于开发验证，不进入 XPI）
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File build\test-harness.ps1 -Mode window|quit|disconnect

param(
    [Parameter(Mandatory = $true)][ValidateSet('window', 'quit', 'disconnect', 'hotkey')][string]$Mode,
    [string]$BinDir = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = if ($BinDir) { $BinDir } else { Join-Path $root 'src\addon\content\bin' }
$icon = Join-Path $src 'tray.ico'

$script:fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Extra = '')
    if ($Ok) { Write-Host ("PASS  {0} {1}" -f $Name, $Extra) -ForegroundColor Green }
    else { Write-Host ("FAIL  {0} {1}" -f $Name, $Extra) -ForegroundColor Red; $script:fail++ }
}

# ---------------------------------------------------------------- 假 Zotero 窗口
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$cs = @'
using System;
using System.Runtime.InteropServices;

public class FakeZoteroWindow
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASSEX
    {
        public uint cbSize; public uint style; public IntPtr lpfnWndProc;
        public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance;
        public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
        public IntPtr hIconSm;
    }

    public delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    static WndProcDelegate _proc = DefWindowProcW;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern ushort RegisterClassExW(ref WNDCLASSEX lpwcx);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowExW(uint exStyle, string cls, string name, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandleW(string name);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);

    // 合成 Ctrl+Alt+F9，用于验证全局热键链路
    public static void SendHotkey()
    {
        const byte VK_CONTROL = 0x11, VK_MENU = 0x12, VK_F9 = 0x78;
        keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        keybd_event(VK_F9, 0, 0, UIntPtr.Zero);
        keybd_event(VK_F9, 0, 2, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, 2, UIntPtr.Zero);
        keybd_event(VK_CONTROL, 0, 2, UIntPtr.Zero);
    }

    public static IntPtr Create()
    {
        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.style = 0x0002 | 0x0001;
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc);
        wc.hInstance = GetModuleHandleW(null);
        wc.lpszClassName = "MozillaWindowClass";
        wc.hbrBackground = (IntPtr)6;
        RegisterClassExW(ref wc);
        IntPtr h = CreateWindowExW(0, "MozillaWindowClass", "Zotero", 0x00CF0000 | 0x10000000,
            120, 120, 800, 600, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        ShowWindow(h, 5);
        return h;
    }
}
'@
Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'

# ---------------------------------------------------------------- 工作目录
$work = Join-Path $env:TEMP ('mz-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item (Join-Path $src 'tray-helper.ps1') $work
Copy-Item (Join-Path $src 'launcher.vbs') $work
Copy-Item $icon $work
Write-Host "work dir: $work"

# ---------------------------------------------------------------- 目标进程
$tcp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$tcp.Start()
$port = ([System.Net.IPEndPoint]$tcp.LocalEndpoint).Port

$hwnd = [IntPtr]::Zero
$targetPid = $PID
$dummy = $null

if ($Mode -eq 'window' -or $Mode -eq 'hotkey') {
    $hwnd = [FakeZoteroWindow]::Create()
    Check 'fake MozillaWindowClass window created' ($hwnd -ne [IntPtr]::Zero -and [FakeZoteroWindow]::IsWindowVisible($hwnd)) ("hwnd=" + $hwnd)
} else {
    $dummy = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
    $targetPid = $dummy.Id
    Write-Host "dummy zotero pid: $targetPid"
}

# ---------------------------------------------------------------- 配置
$token = 'TESTTOKEN123456'
$cfgObj = @{
    port = $port
    token = $token
    zoteroPid = $targetPid
    iconPath = (Join-Path $work 'tray.ico')
    tooltip = 'Zotero 测试'
    log = 1
    hotkey = @{ enabled = $true; mods = 'Ctrl+Alt'; key = 'F9' }
    labels = @{
        show = '显示 Zotero'
        hide = '隐藏到托盘'
        prefs = '打开首选项'
        quit = '退出 Zotero'
    }
}
if ($Mode -eq 'quit') {
    $cfgObj.test = @{ autoClickQuitMs = 1500 }
    $cfgObj.quitForceTimeoutMs = 2500
}
$cfgJson = $cfgObj | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $work 'tray-config.json'), $cfgJson, (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- 启动助手
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$sw = [Diagnostics.Stopwatch]::StartNew()
Start-Process -FilePath $wscript -ArgumentList ('"' + (Join-Path $work 'launcher.vbs') + '"') | Out-Null

function Get-HelperProcs {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like ('*' + $work + '*') }
}

$tcp.Server.ReceiveTimeout = 20000
$client = $null
while ($sw.Elapsed.TotalSeconds -lt 25) {
    if ($tcp.Pending()) { $client = $tcp.AcceptTcpClient(); break }
    Start-Sleep -Milliseconds 100
}
Check 'helper connected to plugin socket' ($null -ne $client) ("after " + [int]$sw.Elapsed.TotalMilliseconds + "ms")
if (-not $client) {
    Get-Content (Join-Path $work 'tray-helper.log') -ErrorAction SilentlyContinue | Write-Host
    exit 1
}

$ns = $client.GetStream()
$reader = New-Object System.IO.StreamReader($ns)
$writer = New-Object System.IO.StreamWriter($ns)
$writer.AutoFlush = $true
$writer.NewLine = "`n"

function Read-Line {
    param([int]$TimeoutMs = 5000)
    $w = [Diagnostics.Stopwatch]::StartNew()
    while ($w.Elapsed.TotalMilliseconds -lt $TimeoutMs) {
        if ($ns.DataAvailable) { return $reader.ReadLine() }
        Start-Sleep -Milliseconds 40
    }
    return $null
}

$hello = Read-Line 8000
Check 'handshake HELLO with token' ($hello -eq ("HELLO " + $token)) ("got: " + $hello)

if ($Mode -eq 'window') {
    # 等托盘与 Add-Type 初始化完成
    Start-Sleep -Milliseconds 2500
    Check 'window initially visible' ([FakeZoteroWindow]::IsWindowVisible($hwnd))

    $writer.WriteLine('HIDE'); Start-Sleep -Milliseconds 500
    Check 'HIDE -> window hidden' (-not [FakeZoteroWindow]::IsWindowVisible($hwnd))
    Check 'HIDE -> reply HIDDEN' ((Read-Line 2000) -eq 'HIDDEN')

    $writer.WriteLine('SHOW'); Start-Sleep -Milliseconds 500
    Check 'SHOW -> window visible' ([FakeZoteroWindow]::IsWindowVisible($hwnd))
    Check 'SHOW -> reply SHOWN' ((Read-Line 2000) -eq 'SHOWN')

    $writer.WriteLine('PING')
    Check 'PING -> PONG' ((Read-Line 2000) -eq 'PONG')

    # 菜单内容（从日志中读取助手实际构建的菜单项）
    $logPath = Join-Path $work 'tray-helper.log'
    $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
    Check 'menu contains 4 items' ($log -match 'menu items = 6 :: 显示 Zotero \| 隐藏到托盘 \| --- \| 打开首选项 \| --- \| 退出 Zotero')
    Check 'menu labels not mojibake' ($log -match '显示 Zotero' -and $log -notmatch '锟')
    Check 'icon loaded from ico' ($log -match 'icon loaded')
    Check 'global hotkey registered' ($log -match 'hotkey register Ctrl\+Alt\+F9 -> rc=0')

    $writer.WriteLine('EXIT')
    Start-Sleep -Milliseconds 1200
    $left = @(Get-HelperProcs)
    Check 'EXIT -> helper process gone' ($left.Count -eq 0) ("remaining=" + $left.Count)
}
elseif ($Mode -eq 'hotkey') {
    Start-Sleep -Milliseconds 2500
    Check 'window visible before hotkey' ([FakeZoteroWindow]::IsWindowVisible($hwnd))

    # 1) 直接投递 WM_HOTKEY，验证"消息 -> WndProc -> 切换窗口"这条链路
    $log = Get-Content -LiteralPath (Join-Path $work 'tray-helper.log') -Raw -Encoding UTF8
    $m = [regex]::Match($log, 'hotkey register .* handle=(\d+)')
    $sink = [IntPtr][int64]($m.Groups[1].Value)
    Check 'sink window handle parsed from log' ($sink -ne [IntPtr]::Zero) ("handle=" + $sink)
    [void][FakeZoteroWindow]::PostMessageW($sink, 0x0312, [IntPtr]9001, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    Check 'WM_HOTKEY -> window hidden' (-not [FakeZoteroWindow]::IsWindowVisible($hwnd))
    [void][FakeZoteroWindow]::PostMessageW($sink, 0x0312, [IntPtr]9001, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    Check 'WM_HOTKEY again -> window restored' ([FakeZoteroWindow]::IsWindowVisible($hwnd))

    # 2) 真实按键（依赖当前会话能否注入输入，仅作参考信息）
    $before = ([regex]::Matches((Get-Content -LiteralPath (Join-Path $work 'tray-helper.log') -Raw -Encoding UTF8), 'hotkey fired')).Count
    [FakeZoteroWindow]::SendHotkey()
    Start-Sleep -Milliseconds 900
    $after = ([regex]::Matches((Get-Content -LiteralPath (Join-Path $work 'tray-helper.log') -Raw -Encoding UTF8), 'hotkey fired')).Count
    Write-Host ("INFO  synthetic Ctrl+Alt+F9 触发次数: {0}（0 表示当前会话不允许注入输入，非插件缺陷）" -f ($after - $before))

    $writer.WriteLine('EXIT')
    Start-Sleep -Milliseconds 1200
}
elseif ($Mode -eq 'disconnect') {
    Start-Sleep -Milliseconds 2000
    Write-Host 'closing socket abruptly (simulating Zotero crash)'
    $client.Close()
    Start-Sleep -Milliseconds 2000
    $left = @(Get-HelperProcs)
    Check 'socket closed -> helper exits (no orphan)' ($left.Count -eq 0) ("remaining=" + $left.Count)
}
elseif ($Mode -eq 'quit') {
    Start-Sleep -Milliseconds 1000
    $got = $null
    $w = [Diagnostics.Stopwatch]::StartNew()
    while ($w.Elapsed.TotalMilliseconds -lt 8000) {
        $line = Read-Line 500
        if ($line) { Write-Host "helper said: $line"; if ($line -eq 'MENU_QUIT') { $got = $line; break } }
    }
    Check 'tray "退出 Zotero" click sends MENU_QUIT' ($got -eq 'MENU_QUIT')

    # 故意不退出 Zotero，验证看门狗强制结束目标进程
    Start-Sleep -Milliseconds 4000
    $alive = $false
    try { $alive = -not $dummy.HasExited } catch { }
    Check 'quit watchdog killed hung target process' (-not $alive)
    $left = @(Get-HelperProcs)
    Check 'helper exited after force quit' ($left.Count -eq 0) ("remaining=" + $left.Count)
}

if ($Mode -ne 'window') { Write-Host '--- helper log ---'; Get-Content (Join-Path $work 'tray-helper.log') -Encoding UTF8 }

# 清理
try { if ($client) { $client.Close() } } catch { }
try { $tcp.Stop() } catch { }
try { if ($dummy -and -not $dummy.HasExited) { $dummy.Kill() } } catch { }
foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like ('*' + $work + '*') })) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail -gt 0) { Write-Host ("RESULT: {0} check(s) failed" -f $script:fail) -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: all checks passed' -ForegroundColor Green
