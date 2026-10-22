/* global Zotero, Components, ChromeUtils */

(function () {
	"use strict";

	// XPCOM 全局对象在不同 Zotero 版本中的注入形式略有差异，这里做兼容获取。
	// Zotero 8 起底层是 Firefox 140：所有 .jsm 改为 ESM，旧的
	// resource://gre/modules/Services.jsm 已不存在，必须优先用 importESModule。
	const G = globalThis;
	const Comp = (typeof Components !== "undefined") ? Components : null;
	const Cc = Comp ? Comp.classes : (G.Cc || null);
	const Ci = Comp ? Comp.interfaces : (G.Ci || null);
	const Cr = Comp ? Comp.results : (G.Cr || null);

	function getServices() {
		if (typeof Services !== "undefined" && Services) {
			return Services;
		}
		if (G.Services) {
			return G.Services;
		}
		const CU = (typeof ChromeUtils !== "undefined") ? ChromeUtils : G.ChromeUtils;
		if (!CU) {
			return null;
		}
		try {
			return CU.importESModule("resource://gre/modules/Services.sys.mjs").Services;
		}
		catch (e) {}
		try {
			return CU.import("resource://gre/modules/Services.jsm").Services;
		}
		catch (e) {}
		return null;
	}

	const Svcs = getServices();

	const HELPER_FILES = ["tray-helper.ps1", "launcher.vbs", "tray.ico"];

	Zotero.MinimizeToTrayPlus = {
		// ------------------------------------------------------------ 状态
		id: null,
		version: null,
		rootURI: null,
		PREFIX: "extensions.minimize-to-tray-plus.",

		_server: null,
		_port: 0,
		_token: "",
		_conns: null,
		_procs: null,
		_helperDir: null,
		_windows: null,
		_pane: null,
		_paneID: null,
		_prefObserver: null,
		_prefObserverSymbol: null,
		_obs: null,
		_origQuit: null,

		_quitting: false,
		_isHidden: false,
		_autoHideDone: false,
		_hideTimer: null,
		_restartCount: 0,
		_restartWindowStart: 0,
		_suppressRestart: false,

		// ------------------------------------------------------------ 生命周期
		init({ id, version, rootURI }) {
			this.id = id;
			this.version = version;
			this.rootURI = rootURI;

			this._conns = new Set();
			this._procs = new Set();
			this._windows = new Map();
			this._quitting = false;
			this._isHidden = false;
			this._autoHideDone = false;
			this._token = this._randomToken();

			this._log("init v" + version);

			if (typeof Zotero.isWin === "boolean" && !Zotero.isWin) {
				this._log("not Windows, plugin is inert");
				return;
			}
			if (!Svcs) {
				this._log("Services unavailable, plugin is inert");
				return;
			}

			this._registerPrefPane();
			this._installQuitHooks();

			for (const win of Zotero.getMainWindows()) {
				this.onMainWindowLoad(win);
			}

			if (!this._startServer()) {
				return;
			}

			this._registerPrefObserver();
			this._prepareAndLaunch();

			if (Zotero.Prefs.get(this.PREFIX + "startup.autohide", true)) {
				this._waitAndHide(0);
			}
		},

		shutdown() {
			this._quitting = true;
			this._log("shutdown");

			// 如果窗口当时是隐藏的，先恢复再结束助手，避免留下"看不见也关不掉"的 Zotero
			if (this._isHidden) {
				this._send("SHOW");
			}
			this._send("EXIT");

			if (this._hideTimer) {
				clearTimeout(this._hideTimer);
				this._hideTimer = null;
			}

			for (const conn of [...(this._conns || [])]) {
				try {
					conn.transport.close(Cr.NS_BINDING_ABORTED);
				}
				catch (e) {}
			}
			if (this._conns) {
				this._conns.clear();
			}
			if (this._procs) {
				this._procs.clear();
			}

			if (this._server) {
				try {
					this._server.close();
				}
				catch (e) {}
				this._server = null;
			}

			if (this._paneID) {
				try {
					Zotero.PreferencePanes.unregister(this._paneID);
				}
				catch (e) {}
			}
			this._pane = null;
			this._paneID = null;

			if (this._prefObserverSymbol) {
				try {
					Zotero.Prefs.unregisterObserver(this._prefObserverSymbol);
				}
				catch (e) {}
				this._prefObserverSymbol = null;
			}
			this._prefObserver = null;

			if (this._obs) {
				for (const topic of Object.keys(this._obs.topics)) {
					try {
						Svcs.obs.removeObserver(this._obs.observer, topic);
					}
					catch (e) {}
				}
				this._obs = null;
			}

			// 还原被包裹的退出方法（插件被单独禁用/卸载时需要）
			try {
				const ui = Zotero.Utilities.Internal;
				if (ui && this._origQuit) {
					for (const name of Object.keys(this._origQuit)) {
						ui[name] = this._origQuit[name];
					}
					this._origQuit = null;
				}
			}
			catch (e) {}

			for (const win of [...this._windows.keys()]) {
				this.onMainWindowUnload(win);
			}
		},

		onMainWindowLoad(win) {
			if (!win || this._windows.has(win)) {
				return;
			}
			const self = this;

			const onClose = function (event) {
				if (self._quitting) {
					return;
				}
				if (!Zotero.Prefs.get(self.PREFIX + "closeToTray", true)) {
					return;
				}
				self._log("close intercepted -> hide to tray");
				event.preventDefault();
				event.stopPropagation();
				self.hideToTray();
			};

			const origClose = win.close;
			win.close = function () {
				if (self._quitting || !Zotero.Prefs.get(self.PREFIX + "closeToTray", true)) {
					return origClose.apply(this, arguments);
				}
				self.hideToTray();
			};

			try {
				win.addEventListener("close", onClose, true);
			}
			catch (e) {
				this._log("addEventListener failed: " + e);
			}

			this._windows.set(win, { onClose, origClose });
			this._log("main window attached");
		},

		onMainWindowUnload(win) {
			const rec = this._windows && this._windows.get(win);
			if (!rec) {
				return;
			}
			try {
				win.removeEventListener("close", rec.onClose, true);
			}
			catch (e) {}
			try {
				win.close = rec.origClose;
			}
			catch (e) {}
			this._windows.delete(win);
			this._log("main window detached");
		},

		// ------------------------------------------------------------ 退出检测
		_installQuitHooks() {
			const self = this;
			const observe = function (subject, topic) {
				// 只要出现"正在退出"的任何信号，就不再拦截窗口关闭
				self._quitting = true;
				self._log("quit signal: " + topic);
			};
			const topics = {
				"quit-application-requested": true,
				"quit-application": true,
				"quit-application-granted": true,
				"profile-change-teardown": true,
			};
			for (const topic of Object.keys(topics)) {
				try {
					Svcs.obs.addObserver(observe, topic);
				}
				catch (e) {}
			}
			this._obs = { observer: observe, topics };

			// File > Quit / Ctrl+Q：Zotero 7 走 quitZotero()，Zotero 8+ 走 quit()
			try {
				const ui = Zotero.Utilities.Internal;
				if (ui) {
					this._origQuit = {};
					for (const name of ["quit", "quitZotero"]) {
						const orig = ui[name];
						if (typeof orig !== "function" || orig.__mtpWrapped) {
							continue;
						}
						const wrapped = function () {
							self._quitting = true;
							return orig.apply(this, arguments);
						};
						wrapped.__mtpWrapped = true;
						ui[name] = wrapped;
						this._origQuit[name] = orig;
					}
				}
			}
			catch (e) {
				this._log("wrap quit failed: " + e);
			}
		},

		// ------------------------------------------------------------ 偏好设置
		// Zotero 8+ 的 register() 返回 Promise<面板ID>，旧版本返回带 paneID 的对象
		_registerPrefPane() {
			try {
				const ret = Zotero.PreferencePanes.register({
					pluginID: this.id,
					id: "minimize-to-tray-plus-prefs",
					src: this.rootURI + "content/preferences.xhtml",
					label: "最小化到托盘",
					image: this.rootURI + "content/icons/icon.png",
				});
				this._pane = ret;
				if (ret && typeof ret.then === "function") {
					ret.then((id) => {
						this._paneID = id;
					}).catch((e) => this._log("pref pane register failed: " + e));
				}
				else if (typeof ret === "string") {
					this._paneID = ret;
				}
				else if (ret && ret.paneID) {
					this._paneID = ret.paneID;
				}
			}
			catch (e) {
				this._log("pref pane register failed: " + e);
			}
		},

		_registerPrefObserver() {
			const self = this;
			const sensitive = [
				this.PREFIX + "hotkey.enabled",
				this.PREFIX + "hotkey.mods",
				this.PREFIX + "hotkey.key",
				this.PREFIX + "network.port",
				this.PREFIX + "leftClick",
			];
			this._prefObserver = function (branch, name) {
				if (sensitive.includes(name)) {
					self._log("pref changed: " + name + " -> restart helper");
					self.restartHelper();
				}
			};
			try {
				// 返回值是 Symbol，注销时必须原样传回
				this._prefObserverSymbol = Zotero.Prefs.registerObserver(
					this.PREFIX.slice(0, -1), this._prefObserver
				);
			}
			catch (e) {
				this._log("pref observer failed: " + e);
			}
		},

		// ------------------------------------------------------------ TCP 服务端
		_startServer() {
			if (!Svcs || !Cc) {
				this._log("XPCOM globals unavailable, abort");
				return false;
			}

			let requested = parseInt(Zotero.Prefs.get(this.PREFIX + "network.port", true), 10);
			if (!requested || isNaN(requested) || requested < 0) {
				requested = 0; // 0 = 由系统分配空闲端口，彻底避免端口冲突
			}

			// 候选端口：偏好值 / 自动分配 / 随机高位端口（极端情况下兜底）
			const candidates = [];
			if (requested > 0) {
				candidates.push(requested, 0);
			}
			else {
				candidates.push(0);
				for (let i = 0; i < 4; i++) {
					candidates.push(41000 + Math.floor(Math.random() * 19000));
				}
			}

			const self = this;
			for (const port of candidates) {
				let server = null;
				try {
					server = Cc["@mozilla.org/network/server-socket;1"]
						.createInstance(Ci.nsIServerSocket);
					server.init(port, true, 4);
					if (!server.port) {
						throw new Error("no port assigned");
					}
					server.asyncListen({
						onSocketAccepted(socket, transport) {
							self._onAccept(socket, transport);
						},
						onStopListening() {},
					});
					this._server = server;
					this._port = server.port;
					this._log("listening on 127.0.0.1:" + this._port);
					return true;
				}
				catch (e) {
					this._log("listen on port " + port + " failed: " + e);
					try {
						if (server) {
							server.close();
						}
					}
					catch (e2) {}
				}
			}
			return false;
		},

		_onAccept(socket, transport) {
			const self = this;
			let input, output;
			try {
				input = transport.openInputStream(0, 0, 0);
				output = transport.openOutputStream(0, 0, 0);
			}
			catch (e) {
				this._log("open stream failed: " + e);
				return;
			}

			const conn = { transport, output, buffer: "", authed: false, closed: false };
			this._conns.add(conn);

			const pump = Cc["@mozilla.org/network/input-stream-pump;1"]
				.createInstance(Ci.nsIInputStreamPump);
			pump.init(input, -1, -1, true);

			const listener = {
				onStartRequest() {},
				onDataAvailable(request, stream, offset, count) {
					try {
						const sis = Cc["@mozilla.org/scriptableinputstream;1"]
							.createInstance(Ci.nsIScriptableInputStream);
						sis.init(stream);
						self._onData(conn, sis.read(count));
					}
					catch (e) {
						self._log("read failed: " + e);
					}
				},
				onStopRequest() {
					conn.closed = true;
					self._conns.delete(conn);
					self._log("helper disconnected");
					if (!self._quitting) {
						self._scheduleHelperRestart();
					}
				},
			};

			try {
				pump.asyncRead(listener, null);
			}
			catch (e) {
				this._log("pump failed: " + e);
				this._conns.delete(conn);
			}
		},

		_onData(conn, data) {
			conn.buffer += data;
			const lines = conn.buffer.split("\n");
			conn.buffer = lines.pop();
			for (const raw of lines) {
				const line = raw.trim();
				if (!line) {
					continue;
				}
				this._log("<- " + line);
				this._handleCommand(conn, line);
			}
		},

		_handleCommand(conn, line) {
			if (!conn.authed) {
				const m = /^HELLO\s+(\S+)$/.exec(line);
				if (m && m[1] === this._token) {
					conn.authed = true;
					this._log("helper authenticated");
					this._send("TOOLTIP Zotero");
					return;
				}
				this._log("handshake failed, dropping connection");
				try {
					conn.transport.close(Cr.NS_BINDING_ABORTED);
				}
				catch (e) {}
				this._conns.delete(conn);
				return;
			}

			switch (line) {
				case "MENU_QUIT":
					this._quitFromTray();
					break;

				case "MENU_PREFS":
					this._openPreferences();
					break;

				case "HIDDEN":
					this._isHidden = true;
					break;

				case "SHOWN":
					this._isHidden = false;
					break;

				case "NOHWND":
					this._log("helper could not find main window");
					break;

				default:
					break;
			}
		},

		_send(cmd) {
			let sent = 0;
			for (const conn of this._conns) {
				if (!conn.authed) {
					continue;
				}
				try {
					const payload = cmd + "\n";
					conn.output.write(payload, payload.length);
					conn.output.flush();
					sent++;
				}
				catch (e) {
					this._log("send failed: " + e);
				}
			}
			if (sent) {
				this._log("-> " + cmd);
			}
			return sent > 0;
		},

		// ------------------------------------------------------------ 动作
		hideToTray() {
			if (!this._send("HIDE")) {
				this._log("helper not available, fallback to minimize");
				const win = Zotero.getMainWindow();
				if (win) {
					try {
						win.minimize();
					}
					catch (e) {}
				}
			}
			else {
				this._isHidden = true;
			}
		},

		showFromTray() {
			this._send("SHOW");
			this._isHidden = false;
		},

		_quitFromTray() {
			this._log("quit requested from tray menu");
			this._quitting = true;
			// 让出当前事件循环，先把状态改完再真正退出
			setTimeout(() => {
				try {
					const ui = Zotero.Utilities.Internal;
					if (ui && typeof ui.quit === "function") {
						// Zotero 8+ 的标准退出方式
						ui.quit();
					}
					else if (ui && typeof ui.quitZotero === "function") {
						ui.quitZotero();
					}
					else {
						Svcs.startup.quit(Ci.nsIAppStartup.eAttemptQuit);
					}
				}
				catch (e) {
					Zotero.logError(e);
					try {
						Svcs.startup.quit(Ci.nsIAppStartup.eForceQuit);
					}
					catch (e2) {}
				}
			}, 60);
		},

		_openPreferences() {
			try {
				const ui = Zotero.Utilities.Internal;
				if (ui && typeof ui.openPreferences === "function") {
					ui.openPreferences();
					return;
				}
				const win = Zotero.getMainWindow();
				if (win && win.ZoteroPane && win.ZoteroPane.openPreferences) {
					win.ZoteroPane.openPreferences();
				}
			}
			catch (e) {
				this._log("open preferences failed: " + e);
			}
		},

		_waitAndHide(attempt) {
			if (this._quitting || this._autoHideDone) {
				return;
			}
			if (this._conns.size > 0) {
				this._autoHideDone = true;
				this._log("auto-hide on startup");
				this.hideToTray();
				return;
			}
			if (attempt > 60) {
				this._log("auto-hide skipped: helper never connected");
				return;
			}
			this._hideTimer = setTimeout(() => this._waitAndHide(attempt + 1), 250);
		},

		// ------------------------------------------------------------ 助手进程
		_getHelperDir() {
			if (this._helperDir) {
				return this._helperDir;
			}
			const dir = Svcs.dirsvc.get("ProfD", Ci.nsIFile);
			dir.append("minimize-to-tray-plus");
			if (!dir.exists()) {
				dir.create(Ci.nsIFile.DIRECTORY_TYPE, 0o755);
			}
			this._helperDir = dir;
			return dir;
		},

		async _prepareAndLaunch() {
			try {
				const dir = this._getHelperDir();
				for (const name of HELPER_FILES) {
					await this._extractFile(name, dir);
				}
				await this._writeConfig(dir);
				this._launch(dir);
			}
			catch (e) {
				this._log("prepare failed: " + e);
				Zotero.logError(e);
			}
		},

		_extractFile(name, dir) {
			const self = this;
			const target = dir.clone();
			target.append(name);

			let sourceStream = null;
			let zipReader = null;

			if (this.rootURI.startsWith("jar:")) {
				const jarPath = this.rootURI.substring(4, this.rootURI.indexOf("!"));
				const fh = Cc["@mozilla.org/network/protocol;1?name=file"]
					.getService(Ci.nsIFileProtocolHandler);
				const xpi = fh.getFileFromURLSpec(jarPath);
				zipReader = Cc["@mozilla.org/libjar/zip-reader;1"]
					.createInstance(Ci.nsIZipReader);
				zipReader.open(xpi);
				const entry = "content/bin/" + name;
				if (!zipReader.hasEntry(entry)) {
					zipReader.close();
					throw new Error("missing entry in XPI: " + entry);
				}
				sourceStream = zipReader.getInputStream(entry);
			}
			else {
				const uri = Svcs.io.newURI(self.rootURI + "content/bin/" + name);
				const file = uri.QueryInterface(Ci.nsIFileURL).file;
				sourceStream = Cc["@mozilla.org/network/file-input-stream;1"]
					.createInstance(Ci.nsIFileInputStream);
				sourceStream.init(file, -1, 0, 0);
			}

			try {
				const out = Cc["@mozilla.org/network/file-output-stream;1"]
					.createInstance(Ci.nsIFileOutputStream);
				out.init(target, 0x02 | 0x08 | 0x20, 0o666, 0);

				const bis = Cc["@mozilla.org/binaryinputstream;1"]
					.createInstance(Ci.nsIBinaryInputStream);
				bis.setInputStream(sourceStream);
				const bytes = bis.readBytes(bis.available());
				out.write(bytes, bytes.length);
				out.close();
			}
			finally {
				try {
					sourceStream.close();
				}
				catch (e) {}
				if (zipReader) {
					try {
						zipReader.close();
					}
					catch (e) {}
				}
			}

			return Promise.resolve(target.path);
		},

		async _writeConfig(dir) {
			const pref = (k, d) => {
				const v = Zotero.Prefs.get(this.PREFIX + k, true);
				return (v === undefined || v === null) ? d : v;
			};

			let key = String(pref("hotkey.key", "") || "").toUpperCase();
			if (!/^([A-Z0-9]|F([1-9]|1[0-9]|2[0-4]))$/.test(key)) {
				key = "";
			}

			const cfg = {
				port: this._port,
				token: this._token,
				zoteroPid: this._getPid(),
				iconPath: dir.path.replace(/\\$/, "") + "\\tray.ico",
				tooltip: "Zotero",
				log: 1,
				quitForceTimeoutMs: 12000,
				leftClick: pref("leftClick", "toggle"),
				hotkey: {
					enabled: !!pref("hotkey.enabled", false),
					mods: String(pref("hotkey.mods", "Ctrl+Alt")),
					key,
				},
				labels: {
					show: "显示 Zotero",
					hide: "隐藏到托盘",
					prefs: "打开首选项",
					quit: "退出 Zotero",
				},
			};

			const file = dir.clone();
			file.append("tray-config.json");
			await Zotero.File.putContentsAsync(file.path, JSON.stringify(cfg, null, 2));
			this._log("config written: pid=" + cfg.zoteroPid + " port=" + cfg.port);
			return file.path;
		},

		_getPid() {
			// 助手优先按 PID 定位主窗口；拿不到时它会退化为按 zotero.exe 反查
			try {
				const appinfo = Svcs.appinfo;
				if (appinfo && appinfo.processID) {
					return appinfo.processID;
				}
			}
			catch (e) {}
			try {
				const CU = (typeof ChromeUtils !== "undefined") ? ChromeUtils : G.ChromeUtils;
				let ctypes = null;
				try {
					ctypes = CU.importESModule("resource://gre/modules/ctypes.sys.mjs").ctypes;
				}
				catch (e) {
					ctypes = CU.import("resource://gre/modules/ctypes.jsm").ctypes;
				}
				const k32 = ctypes.open("kernel32.dll");
				try {
					const getPid = k32.declare(
						"GetCurrentProcessId", ctypes.winapi_abi, ctypes.uint32_t
					);
					return getPid();
				}
				finally {
					k32.close();
				}
			}
			catch (e) {
				this._log("pid lookup failed: " + e);
			}
			return 0;
		},

		_launch(dir) {
			const vbs = dir.clone();
			vbs.append("launcher.vbs");
			const ps1 = dir.clone();
			ps1.append("tray-helper.ps1");

			// 首选 wscript（不产生控制台窗口）
			try {
				const wscript = Svcs.dirsvc.get("SysD", Ci.nsIFile);
				wscript.append("wscript.exe");
				if (wscript.exists()) {
					this._runAsync(wscript.path, [vbs.path]);
					this._log("helper launched via wscript");
					return;
				}
			}
			catch (e) {
				this._log("wscript launch failed: " + e);
			}

			// 兜底：直接起 PowerShell（脚本第一行会自行隐藏控制台）
			try {
				const shell = Svcs.dirsvc.get("SysD", Ci.nsIFile);
				shell.append("WindowsPowerShell");
				shell.append("v1.0");
				shell.append("powershell.exe");
				const exe = shell.exists() ? shell : null;
				if (!exe) {
					throw new Error("powershell.exe not found");
				}
				const proc = Cc["@mozilla.org/process/util;1"].createInstance(Ci.nsIProcess);
				proc.init(exe);
				const args = [
					"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
					"-WindowStyle", "Hidden", "-File", ps1.path,
				];
				this._runAsync(exe.path, args);
				this._log("helper launched via powershell.exe");
			}
			catch (e2) {
				this._log("fallback launch failed: " + e2);
				Zotero.logError(e2);
			}
		},

		// nsIProcess.runw 的签名是 runw(blocking, args, count)，
		// 少了第一个 blocking 参数会直接抛错（Zotero 7–10 均如此）。
		_runAsync(exePath, args) {
			const file = Cc["@mozilla.org/file/local;1"].createInstance(Ci.nsIFile);
			file.initWithPath(exePath);
			const proc = Cc["@mozilla.org/process/util;1"].createInstance(Ci.nsIProcess);
			proc.init(file);
			// 保留引用，避免进程对象被 GC 回收
			this._procs.add(proc);
			try {
				proc.runw(false, args, args.length);
			}
			catch (e) {
				// 极老版本没有 runw(blocking, ...) 形式时退回同步 run
				proc.run(false, args, args.length);
			}
			return proc;
		},

		restartHelper() {
			this._log("restart helper requested");
			this._suppressRestart = true;
			this._send("EXIT");
			setTimeout(() => {
				for (const conn of [...this._conns]) {
					try {
						conn.transport.close(Cr.NS_BINDING_ABORTED);
					}
					catch (e) {}
				}
				this._conns.clear();
				this._restartCount = 0;
				if (this._helperDir) {
					this._launch(this._helperDir);
				}
				this._suppressRestart = false;
			}, 400);
		},

		_scheduleHelperRestart() {
			if (this._suppressRestart) {
				return;
			}
			// 助手意外消失：自动拉起一个，避免"托盘图标没了、窗口还是隐藏状态"的死局
			const now = Date.now();
			if (!this._restartWindowStart || now - this._restartWindowStart > 30000) {
				this._restartWindowStart = now;
				this._restartCount = 0;
			}
			if (this._restartCount >= 3) {
				this._log("helper restart suppressed (too many attempts)");
				return;
			}
			this._restartCount++;
			setTimeout(() => {
				if (this._quitting || this._conns.size > 0) {
					return;
				}
				if (this._helperDir) {
					this._log("relaunching helper (#" + this._restartCount + ")");
					this._launch(this._helperDir);
				}
			}, 1200);
		},

		// ------------------------------------------------------------ 工具
		_randomToken() {
			const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
			let s = "";
			for (let i = 0; i < 32; i++) {
				s += chars.charAt(Math.floor(Math.random() * chars.length));
			}
			return s;
		},

		_log(msg) {
			try {
				Zotero.debug("[MinimizeToTray+] " + msg);
			}
			catch (e) {}
		},
	};
})();
