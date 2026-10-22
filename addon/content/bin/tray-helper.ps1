<#
  Zotero Minimize-to-Tray Plus — 托盘助手进程 (tray-helper.ps1)

  由 Zotero 插件在后台启动（wscript + launcher.vbs，无控制台窗口），职责：
    1. 创建系统托盘图标，并提供完整的右键菜单（显示 / 隐藏 / 首选项 / 退出 Zotero）
    2. 左键单击托盘图标切换 Zotero 主窗口显示状态
    3. 可选的全局热键切换
    4. 通过 ShowWindow 隐藏 / 恢复 Zotero 主窗口（无需 js-ctypes）
    5. 与插件之间保持一条 127.0.0.1 的 TCP 长连接（行协议，双向）

  设计要点：
    * 连接断开（Zotero 退出 / 崩溃 / 插件重载）时助手自动退出，不会残留孤儿进程
    * 监听 "TaskbarCreated" 消息，资源管理器重启后自动恢复托盘图标
    * 单实例互斥量，避免插件重载时出现多个托盘图标
#>

param(
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'tray-config.json'
}
$script:LogPath = Join-Path $PSScriptRoot 'tray-helper.log'
$script:LogEnabled = $false
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Log {
    param([string]$Message)
    if (-not $script:LogEnabled) { return }
    try {
        $line = '[' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $Message + "`r`n"
        [System.IO.File]::AppendAllText($script:LogPath, $line, $script:Utf8)
    } catch { }
}

# ------------------------------------------------------------------ 配置
try {
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json
} catch {
    exit 1
}

$script:LogEnabled = [bool]$cfg.log
if ($script:LogEnabled) {
    try { [System.IO.File]::WriteAllText($script:LogPath, '', $script:Utf8) } catch { }
}

$Port       = [int]$cfg.port
$Token      = [string]$cfg.token
$ZoteroPid  = [uint32]$cfg.zoteroPid
$IconPath   = [string]$cfg.iconPath
$Tooltip    = [string]$cfg.tooltip
if (-not $Tooltip) { $Tooltip = 'Zotero' }

$QuitForceTimeoutMs = 12000
if ($cfg.quitForceTimeoutMs) { $QuitForceTimeoutMs = [int]$cfg.quitForceTimeoutMs }

$AutoClickQuitMs = 0
if ($cfg.test -and $cfg.test.autoClickQuitMs) { $AutoClickQuitMs = [int]$cfg.test.autoClickQuitMs }

$LShow = 'Show Zotero'
$LHide = 'Hide to tray'
$LPrefs = 'Preferences'
$LQuit = 'Quit Zotero'
if ($cfg.labels) {
    if ($cfg.labels.show) { $LShow = [string]$cfg.labels.show }
    if ($cfg.labels.hide) { $LHide = [string]$cfg.labels.hide }
    if ($cfg.labels.prefs) { $LPrefs = [string]$cfg.labels.prefs }
    if ($cfg.labels.quit) { $LQuit = [string]$cfg.labels.quit }
}

$HotkeyEnabled = $false
$HotkeyMods = ''
$HotkeyKey = ''
if ($cfg.hotkey) {
    $HotkeyEnabled = [bool]$cfg.hotkey.enabled
    $HotkeyMods = [string]$cfg.hotkey.mods
    $HotkeyKey = [string]$cfg.hotkey.key
}

$LeftClick = 'toggle'
if ($cfg.leftClick) { $LeftClick = [string]$cfg.leftClick }

Write-Log ('start: pid={0} targetPid={1} port={2}' -f $PID, $ZoteroPid, $Port)

# ------------------------------------------------------------------ Win32 / WinForms 封装
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$cs = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace MzTray
{
    public static class Native
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
        public static extern uint GetWindowThread(IntPtr hWnd, IntPtr lpDwProcessId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string lpString);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool QueryFullProcessImageNameW(IntPtr h, uint flags, StringBuilder sb, ref uint size);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        public const int SW_HIDE = 0;
        public const int SW_SHOWNORMAL = 1;
        public const int SW_SHOWMAXIMIZED = 3;
        public const int SW_SHOW = 5;
        public const int SW_RESTORE = 9;

        public static void TryDpiAware()
        {
            try { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
            catch { try { SetProcessDPIAware(); } catch { } }
        }

        public static void HideConsole()
        {
            try
            {
                IntPtr h = GetConsoleWindow();
                if (h != IntPtr.Zero) ShowWindow(h, SW_HIDE);
            }
            catch { }
        }

        // 目标进程的可执行文件名（跨 32/64 位安全）
        public static string GetImageName(uint pid)
        {
            IntPtr h = OpenProcess(0x1000 /*PROCESS_QUERY_LIMITED_INFORMATION*/, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                StringBuilder sb = new StringBuilder(1024);
                uint size = 1024;
                if (!QueryFullProcessImageNameW(h, 0, sb, ref size)) return null;
                return sb.ToString();
            }
            catch { return null; }
            finally { CloseHandle(h); }
        }

        // 按 PID（可缺省）+ 可执行文件名找出 Zotero 主窗口（MozillaWindowClass）
        public static IntPtr FindMainWindow(uint hintPid)
        {
            IntPtr best = IntPtr.Zero;
            int bestScore = -1;
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                uint wpid;
                GetWindowThreadProcessId(h, out wpid);

                StringBuilder sb = new StringBuilder(256);
                GetClassName(h, sb, 256);
                if (sb.ToString() != "MozillaWindowClass") return true;

                int score = 0;
                if (hintPid != 0 && wpid == hintPid) score += 100;
                string img = GetImageName(wpid);
                if (img != null && img.EndsWith("\\zotero.exe", StringComparison.OrdinalIgnoreCase)) score += 20;

                // 既不是指定进程、也不是 zotero.exe 的窗口一律排除（避免误动 Firefox）
                if (score < 20) return true;

                if (IsWindowVisible(h)) score += 2;
                if (!IsIconic(h)) score += 1;
                if (score > bestScore) { bestScore = score; best = h; }
                return true;
            }, IntPtr.Zero);
            return best;
        }

        // 跨进程把窗口提到前台（AttachThreadInput 绕过前台锁限制）
        public static void Activate(IntPtr h)
        {
            IntPtr fg = GetForegroundWindow();
            uint fgThread = GetWindowThread(fg, IntPtr.Zero);
            uint myThread = GetCurrentThreadId();
            bool attached = false;
            try
            {
                if (fgThread != 0 && fgThread != myThread) attached = AttachThreadInput(myThread, fgThread, true);
                BringWindowToTop(h);
                SetForegroundWindow(h);
                if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
            }
            catch { }
            finally
            {
                if (attached) { try { AttachThreadInput(myThread, fgThread, false); } catch { } }
            }
        }
    }

    // 隐藏消息窗口：接收 WM_HOTKEY 与 TaskbarCreated
    public class TraySink : NativeWindow
    {
        private uint _taskbarMsg;
        public int HotkeyId = 9001;
        public bool HotkeyRegistered = false;

        public volatile bool ToggleFired = false;
        public volatile bool TaskbarCreatedFlag = false;

        public TraySink()
        {
            CreateHandle(new CreateParams());
            _taskbarMsg = Native.RegisterWindowMessage("TaskbarCreated");
        }

        // 返回 0 表示成功，否则为 Win32 错误码（1409=已被其它程序占用）
        public int RegisterHotkey(uint mods, uint vk)
        {
            HotkeyRegistered = Native.RegisterHotKey(Handle, HotkeyId, mods | 0x4000u, vk);
            if (HotkeyRegistered) return 0;
            return Marshal.GetLastWin32Error();
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312 && (int)m.WParam == HotkeyId)
            {
                ToggleFired = true;
            }
            else if (_taskbarMsg != 0 && (uint)m.Msg == _taskbarMsg)
            {
                TaskbarCreatedFlag = true;
            }
            base.WndProc(ref m);
        }

        public void Unregister()
        {
            try
            {
                if (HotkeyRegistered) { Native.UnregisterHotKey(Handle, HotkeyId); HotkeyRegistered = false; }
            }
            catch { }
            try { ReleaseHandle(); } catch { }
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -ErrorAction Stop
} catch {
    Write-Log ('Add-Type failed: ' + $_.Exception.Message)
    exit 2
}

[MzTray.Native]::TryDpiAware()
[MzTray.Native]::HideConsole()

# ------------------------------------------------------------------ 单实例
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\ZoteroMinimizeToTrayPlus')
try {
    if (-not $script:Mutex.WaitOne(5000)) {
        Write-Log 'another helper instance is running, exit.'
        exit 0
    }
} catch { }

# ------------------------------------------------------------------ 状态
$script:Client = $null
$script:Stream = $null
$script:Writer = $null
$script:Decoder = $null
$script:Connected = $false
$script:ConnectDeadline = (Get-Date).AddSeconds(25)
$script:Buffer = New-Object System.Text.StringBuilder
$script:Hwnd = [IntPtr]::Zero
$script:HiddenByUs = $false
$script:WasMaximized = $false
$script:QuitRequestedAt = $null
$script:Exiting = $false
$script:Icon = $null
$script:Tray = $null
$script:Sink = $null
$script:Ctx = $null
$script:Timer = $null
$script:LastToggle = [datetime]::MinValue

# ------------------------------------------------------------------ 协议
function Send-Cmd {
    param([string]$Text)
    if (-not $script:Connected -or -not $script:Writer) { return $false }
    try {
        $script:Writer.WriteLine($Text)
        $script:Writer.Flush()
        Write-Log ('-> ' + $Text)
        return $true
    } catch {
        Write-Log ('send failed: ' + $_.Exception.Message)
        return $false
    }
}

# ------------------------------------------------------------------ 窗口操作
function Get-TargetWindow {
    if ($script:Hwnd -ne [IntPtr]::Zero -and [MzTray.Native]::IsWindow($script:Hwnd)) {
        return $script:Hwnd
    }
    $script:Hwnd = [MzTray.Native]::FindMainWindow($ZoteroPid)
    if ($script:Hwnd -ne [IntPtr]::Zero) { Write-Log ('window found: ' + $script:Hwnd.ToString()) }
    return $script:Hwnd
}

function Invoke-Hide {
    try {
        $h = Get-TargetWindow
        if ($h -eq [IntPtr]::Zero) { Send-Cmd 'NOHWND'; return }
        if (-not [MzTray.Native]::IsWindowVisible($h)) {
            $script:HiddenByUs = $true
            Send-Cmd 'HIDDEN'
            return
        }
        $script:WasMaximized = [MzTray.Native]::IsZoomed($h)
        [void][MzTray.Native]::ShowWindow($h, [MzTray.Native]::SW_HIDE)
        $script:HiddenByUs = $true
        Write-Log ('hidden, wasMaximized=' + $script:WasMaximized)
        Send-Cmd 'HIDDEN'
    } catch {
        Write-Log ('hide failed: ' + $_.Exception.Message)
    }
}

function Invoke-Show {
    try {
        $h = Get-TargetWindow
        if ($h -eq [IntPtr]::Zero) { Send-Cmd 'NOHWND'; return }

        if ([MzTray.Native]::IsIconic($h)) {
            [void][MzTray.Native]::ShowWindow($h, [MzTray.Native]::SW_RESTORE)
        } elseif (-not [MzTray.Native]::IsWindowVisible($h)) {
            if ($script:WasMaximized) {
                [void][MzTray.Native]::ShowWindow($h, [MzTray.Native]::SW_SHOWMAXIMIZED)
            } else {
                [void][MzTray.Native]::ShowWindow($h, [MzTray.Native]::SW_SHOWNORMAL)
            }
        }
        [MzTray.Native]::Activate($h)
        $script:HiddenByUs = $false
        Write-Log 'shown'
        Send-Cmd 'SHOWN'
    } catch {
        Write-Log ('show failed: ' + $_.Exception.Message)
    }
}

function Invoke-Toggle {
    # 防止双击被当成两次切换
    $now = Get-Date
    if (($now - $script:LastToggle).TotalMilliseconds -lt 350) { return }
    $script:LastToggle = $now

    $h = Get-TargetWindow
    if ($h -eq [IntPtr]::Zero) { Invoke-Show; return }

    if ([MzTray.Native]::IsIconic($h) -or -not [MzTray.Native]::IsWindowVisible($h)) {
        Invoke-Show
    } else {
        Invoke-Hide
    }
}

function Invoke-QuitZotero {
    Write-Log 'quit requested from tray menu'
    $ok = Send-Cmd 'MENU_QUIT'
    if (-not $ok) {
        # 拿不到连接时直接结束目标进程，避免"退不出去"
        try {
            Stop-Process -Id $ZoteroPid -Force -ErrorAction SilentlyContinue
        } catch { }
        Stop-Helper
        return
    }
    $script:QuitRequestedAt = Get-Date
}

# ------------------------------------------------------------------ 退出
function Stop-Helper {
    if ($script:Exiting) { return }
    $script:Exiting = $true
    Write-Log 'stopping helper'
    try { if ($script:Timer) { $script:Timer.Stop() } } catch { }
    try {
        if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    } catch { }
    try { if ($script:Sink) { $script:Sink.Unregister() } } catch { }
    try { if ($script:Client) { $script:Client.Close() } } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
    try { $script:Ctx.ExitThread() } catch { }
}

# ------------------------------------------------------------------ 托盘
try {
    if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
        try {
            $script:Icon = New-Object System.Drawing.Icon($IconPath, 32, 32)
        } catch {
            $script:Icon = New-Object System.Drawing.Icon($IconPath)
        }
        Write-Log ('icon loaded: ' + $IconPath)
    } else {
        $script:Icon = [System.Drawing.SystemIcons]::Application
        Write-Log 'icon missing, fallback to SystemIcons.Application'
    }
} catch {
    $script:Icon = [System.Drawing.SystemIcons]::Application
    Write-Log ('icon load failed: ' + $_.Exception.Message)
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $script:Icon
$script:Tray.Text = $Tooltip
$script:Tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $false

$miShow = New-Object System.Windows.Forms.ToolStripMenuItem($LShow)
$miShow.Font = New-Object System.Drawing.Font($miShow.Font, [System.Drawing.FontStyle]::Bold)
$miShow.add_Click({ Invoke-Show })

$miHide = New-Object System.Windows.Forms.ToolStripMenuItem($LHide)
$miHide.add_Click({ Invoke-Hide })

$miPrefs = New-Object System.Windows.Forms.ToolStripMenuItem($LPrefs)
$miPrefs.add_Click({ [void](Send-Cmd 'MENU_PREFS') })

$miQuit = New-Object System.Windows.Forms.ToolStripMenuItem($LQuit)
$miQuit.add_Click({ Invoke-QuitZotero })

[void]$menu.Items.Add($miShow)
[void]$menu.Items.Add($miHide)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($miPrefs)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($miQuit)

$script:Tray.ContextMenuStrip = $menu
$script:Tray.add_MouseClick({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($LeftClick -eq 'show') { Invoke-Show } else { Invoke-Toggle }
})
$script:Tray.add_DoubleClick({ Invoke-Show })

Write-Log ('tray created, menu items = ' + $menu.Items.Count + ' :: ' + (($menu.Items | ForEach-Object { if ($_ -is [System.Windows.Forms.ToolStripSeparator]) { '---' } else { $_.Text } }) -join ' | '))

# ------------------------------------------------------------------ 全局热键
if ($HotkeyEnabled -and $HotkeyKey) {
    try {
        $script:Sink = New-Object MzTray.TraySink
        $mods = 0
        foreach ($m in ($HotkeyMods -split '[^A-Za-z]+')) {
            switch ($m.ToLower()) {
                'ctrl' { $mods = $mods -bor 0x0002 }
                'control' { $mods = $mods -bor 0x0002 }
                'alt' { $mods = $mods -bor 0x0001 }
                'shift' { $mods = $mods -bor 0x0004 }
                'win' { $mods = $mods -bor 0x0008 }
            }
        }
        $vk = 0
        $k = $HotkeyKey.Trim().ToUpper()
        if ($k.Length -eq 1 -and $k -match '^[A-Z0-9]$') {
            $vk = [int][char]$k
        } elseif ($k -match '^F([1-9]|1[0-9]|2[0-4])$') {
            $vk = 0x70 + [int]$k.Substring(1) - 1
        }
        if ($vk -gt 0 -and $mods -gt 0) {
            $rc = $script:Sink.RegisterHotkey([uint32]$mods, [uint32]$vk)
            Write-Log ('hotkey register ' + $HotkeyMods + '+' + $k + ' -> rc=' + $rc + ' handle=' + $script:Sink.Handle.ToString())
        } else {
            Write-Log 'hotkey skipped: invalid mods or key'
        }
    } catch {
        Write-Log ('hotkey setup failed: ' + $_.Exception.Message)
    }
}

# ------------------------------------------------------------------ 主循环
function Connect-Zotero {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.NoDelay = $true
        $c.Connect('127.0.0.1', $Port)
        $script:Client = $c
        $ns = $c.GetStream()
        $script:Stream = $ns
        $script:Writer = New-Object System.IO.StreamWriter($ns)
        $script:Writer.AutoFlush = $true
        $script:Writer.NewLine = "`n"
        $script:Decoder = [System.Text.Encoding]::UTF8.GetDecoder()
        $script:Connected = $true
        Write-Log 'connected to plugin'
        Send-Cmd ('HELLO ' + $Token)
    } catch {
        try { if ($script:Client) { $script:Client.Close() } } catch { }
        $script:Client = $null
        $script:Connected = $false
    }
}

function Test-Disconnected {
    if (-not $script:Connected -or -not $script:Client) { return $true }
    try {
        $sock = $script:Client.Client
        if (-not $sock.Connected) { return $true }
        if ($sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $sock.Available -eq 0) { return $true }
        return $false
    } catch {
        return $true
    }
}

function Receive-Commands {
    if (-not $script:Stream) { return }
    $avail = 0
    try { $avail = $script:Client.Available } catch { return }
    if ($avail -le 0) { return }

    $buf = New-Object 'byte[]' $avail
    $read = $script:Stream.Read($buf, 0, $avail)
    if ($read -le 0) { return }

    $chars = New-Object 'char[]' $read
    $count = $script:Decoder.GetChars($buf, 0, $read, $chars, 0)
    if ($count -le 0) { return }
    $chunk = New-Object System.String($chars, 0, $count)

    [void]$script:Buffer.Append($chunk)
    $all = $script:Buffer.ToString()
    $parts = $all -split "`n"
    # 最后一段可能不完整，留在缓冲里
    $script:Buffer.Length = 0
    [void]$script:Buffer.Append($parts[$parts.Length - 1])
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        $line = $parts[$i].Trim()
        if (-not $line) { continue }
        Write-Log ('<- ' + $line)
        switch -regex ($line) {
            '^SHOW$' { Invoke-Show }
            '^HIDE$' { Invoke-Hide }
            '^REFRESH$' { $script:Hwnd = [IntPtr]::Zero; [void](Get-TargetWindow) }
            '^TOOLTIP\s+(.*)$' {
                $t = $Matches[1]
                if ($t.Length -gt 63) { $t = $t.Substring(0, 63) }
                $script:Tray.Text = $t
            }
            '^PING$' { [void](Send-Cmd 'PONG') }
            '^EXIT$' { Stop-Helper; return }
        }
    }
}

$script:Ctx = New-Object System.Windows.Forms.ApplicationContext
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 150
$script:Timer.add_Tick({
    if ($script:Exiting) { return }
    try {
        # 热键 / 资源管理器重启
        if ($script:Sink) {
            if ($script:Sink.ToggleFired) { $script:Sink.ToggleFired = $false; Write-Log 'hotkey fired'; Invoke-Toggle }
            if ($script:Sink.TaskbarCreatedFlag) {
                $script:Sink.TaskbarCreatedFlag = $false
                Write-Log 'TaskbarCreated: re-add tray icon'
                $script:Tray.Visible = $false
                $script:Tray.Visible = $true
            }
        }

        # 连接维护
        if (-not $script:Connected) {
            if ((Get-Date) -gt $script:ConnectDeadline) {
                Write-Log 'connect timeout, exit'
                Stop-Helper
                return
            }
            Connect-Zotero
        } else {
            # 先读完缓冲数据，再判断连接是否已断开（避免 StreamReader 预读导致误判）
            Receive-Commands
            if (Test-Disconnected) {
                Write-Log 'plugin connection closed, exit'
                Stop-Helper
                return
            }
        }

        # 退出看门狗：发过 MENU_QUIT 但 Zotero 没退出则强杀
        if ($script:QuitRequestedAt) {
            $elapsed = ((Get-Date) - $script:QuitRequestedAt).TotalMilliseconds
            if ($elapsed -gt $QuitForceTimeoutMs) {
                Write-Log 'quit timeout, force kill zotero'
                try { Stop-Process -Id $ZoteroPid -Force -ErrorAction SilentlyContinue } catch { }
                Stop-Helper
            }
        }
    } catch {
        Write-Log ('tick error: ' + $_.Exception.Message)
    }
})

# 诊断用：自动模拟点击"退出 Zotero"菜单项
if ($AutoClickQuitMs -gt 0) {
    $auto = New-Object System.Windows.Forms.Timer
    $auto.Interval = $AutoClickQuitMs
    $auto.add_Tick({
        $auto.Stop()
        Write-Log 'test: auto click quit menu item'
        $miQuit.PerformClick()
    })
    $auto.Start()
    $script:AutoTimer = $auto
}

Write-Log 'entering message loop'
$script:Timer.Start()
[System.Windows.Forms.Application]::Run($script:Ctx)
Write-Log 'message loop ended'
