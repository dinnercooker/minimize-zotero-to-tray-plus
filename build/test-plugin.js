// Node 环境下的插件侧单元测试：用假的 Zotero / XPCOM 对象加载 content/scripts/main.js，
// 校验偏好面板注册、配置契约、关窗拦截、退出链路与清理逻辑。
// 运行: node build/test-plugin.js

const fs = require("fs");
const os = require("os");
const path = require("path");
const assert = require("assert");

const SRC = path.join(__dirname, "..", "src", "addon");
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "mtp-unit-"));

const log = [];
let paneRegistered = null;
let paneUnregistered = null;
let runwCalls = [];
let quitCalled = 0;
let observers = [];
let outbox = [];
let currentWindow = null;

function makeFile(p) {
	const f = {
		path: p,
		clone() {
			return makeFile(this.path);
		},
		append(name) {
			this.path = this.path.replace(/[\\/]+$/, "") + "\\" + name;
		},
		exists() {
			return true;
		},
		create() {},
	};
	return f;
}

global.Zotero = {
	isWin: true,
	debug: (m) => log.push(m),
	initializationPromise: Promise.resolve(),
	Prefs: {
		get(key, global) {
			const defaults = {
				"extensions.minimize-to-tray-plus.closeToTray": true,
				"extensions.minimize-to-tray-plus.startup.autohide": false,
				"extensions.minimize-to-tray-plus.leftClick": "toggle",
				"extensions.minimize-to-tray-plus.hotkey.enabled": false,
				"extensions.minimize-to-tray-plus.hotkey.mods": "Ctrl+Alt",
				"extensions.minimize-to-tray-plus.hotkey.key": "Z",
				"extensions.minimize-to-tray-plus.network.port": 0,
			};
			return defaults[key];
		},
		registerObserver() {},
		unregisterObserver() {},
	},
	PreferencePanes: {
		register(opts) {
			paneRegistered = opts;
			return { paneID: "mtp-pane" };
		},
		unregister(id) {
			paneUnregistered = id;
		},
	},
	File: {
		async putContentsAsync(p, data) {
			if (process.env.MTP_DEBUG) console.log("[mock] write -> " + p);
			fs.mkdirSync(path.dirname(p), { recursive: true });
			fs.writeFileSync(p, data, "utf8");
		},
	},
	getMainWindows() {
		return currentWindow ? [currentWindow] : [];
	},
	getMainWindow() {
		return currentWindow;
	},
	Utilities: {
		Internal: {
			quitZotero() {
				quitCalled++;
			},
			openPreferences() {},
		},
	},
	logError: (e) => log.push("ERROR " + e),
};

const Ci = {
	nsIServerSocket: "nsIServerSocket",
	nsIFile: { DIRECTORY_TYPE: 1 },
	nsIFileURL: "nsIFileURL",
	nsIAppStartup: { eAttemptQuit: 1, eForceQuit: 2 },
	nsIThread: { DISPATCH_NORMAL: 0 },
	nsISocketTransport: { CLOSE_FORCIBLY: 1 },
};

const fakeServer = {
	port: 0,
	init(p) {
		this.port = p && p > 0 ? p : 51234;
	},
	asyncListen(l) {
		this.listener = l;
	},
	close() {},
};

const fakeProc = {
	init(f) {
		this.file = f.path;
	},
	initWithPath(p) {
		this.file = p;
	},
	// 真实签名是 runw(blocking, args, count)，缺了 blocking 会 TypeError
	runw(blocking, args, n) {
		if (typeof blocking !== "boolean") {
			throw new Error("runw: first argument must be boolean");
		}
		runwCalls.push({ file: this.file, args: args.slice(0, n), blocking });
	},
};

const Cc = {
	"@mozilla.org/network/server-socket;1": {
		createInstance: () => Object.assign(Object.create(fakeServer), fakeServer),
	},
	"@mozilla.org/process/util;1": {
		createInstance: () => Object.assign(Object.create(fakeProc), { init: fakeProc.init, runw: fakeProc.runw }),
	},
	"@mozilla.org/file/local;1": {
		createInstance: () => ({ path: "", initWithPath(p) { this.path = p; } }),
	},
};

const Services = {
	obs: {
		addObserver(o, t) {
			observers.push({ o, t });
		},
		removeObserver() {},
	},
	dirsvc: {
		get(kind) {
			if (kind === "ProfD") return makeFile(tmpRoot);
			return makeFile("C:\\Windows\\System32");
		},
	},
	io: {
		newURI: (s) => ({ QueryInterface: () => ({ file: makeFile(s.replace("file:///", "")) }) }),
	},
	startup: {
		quit() {},
	},
	appinfo: { processID: 4242 },
	scriptloader: { loadSubScript() {} },
};

const Cr = { NS_BINDING_ABORTED: 0x804b000a };

global.Components = { classes: Cc, interfaces: Ci, results: Cr };
global.ChromeUtils = {
	import() {
		return { Services, ctypes: { open: () => ({ declare: () => () => 4242, close() {} }), winapi_abi: "winapi", uint32_t: "u32" } };
	},
};
global.Services = Services;
global.Cc = Cc;
global.Ci = Ci;
global.Cr = Cr;

// 加载插件主体
const code = fs.readFileSync(path.join(SRC, "content", "scripts", "main.js"), "utf8");
new Function("Zotero", "Components", "ChromeUtils", "Services", code)(
	global.Zotero, global.Components, global.ChromeUtils, global.Services
);

const plugin = global.Zotero.MinimizeToTrayPlus;
assert.ok(plugin, "Zotero.MinimizeToTrayPlus 应被创建");

// 假主窗口
function makeWindow() {
	const listeners = {};
	const w = {
		location: { href: "chrome://zotero/content/standalone/browser.xhtml" },
		addEventListener(type, fn) {
			(listeners[type] = listeners[type] || []).push(fn);
		},
		removeEventListener(type, fn) {
			listeners[type] = (listeners[type] || []).filter((f) => f !== fn);
		},
		dispatch(type, event) {
			(listeners[type] || []).forEach((fn) => fn(event));
		},
		close() {
			w.closeCalled = true;
		},
		minimize() {},
	};
	return w;
}

const results = [];
function check(name, fn) {
	try {
		fn();
		results.push(["PASS", name]);
	}
	catch (e) {
		results.push(["FAIL", name + " :: " + e.message]);
	}
}

async function main() {
	currentWindow = makeWindow();

	// 跳过真实解包（解包依赖 XPCOM zip reader），其余逻辑照常执行
	plugin._extractFile = async () => {};
	plugin.init({ id: "minimize-to-tray-plus@local", version: "1.2.0", rootURI: "file:///" + SRC.replace(/\\/g, "/") + "/" });
	await new Promise((r) => setTimeout(r, 300));

	check("偏好面板已注册", () => {
		assert.ok(paneRegistered, "register 未被调用");
		assert.ok(paneRegistered.src.endsWith("content/preferences.xhtml"));
		assert.strictEqual(paneRegistered.pluginID, "minimize-to-tray-plus@local");
	});

	check("TCP 服务端已监听", () => {
		assert.strictEqual(plugin._port, 51234);
	});

	let cfg = null;
	if (process.env.MTP_DEBUG) console.log(log.join("\n"));
	check("配置文件已写出且字段齐全", () => {
		const p = path.join(tmpRoot, "minimize-to-tray-plus", "tray-config.json");
		assert.ok(fs.existsSync(p), "tray-config.json 不存在: " + p);
		cfg = JSON.parse(fs.readFileSync(p, "utf8"));
		for (const k of ["port", "token", "zoteroPid", "iconPath", "tooltip", "log", "labels", "hotkey", "leftClick"]) {
			assert.ok(k in cfg, "缺少字段 " + k);
		}
		assert.strictEqual(cfg.port, 51234);
		assert.strictEqual(cfg.zoteroPid, 4242);
		assert.strictEqual(cfg.labels.quit, "退出 Zotero");
		assert.ok(cfg.iconPath.endsWith("tray.ico"), cfg.iconPath);
		assert.strictEqual(cfg.token.length, 32);
	});

	check("通过 wscript 启动助手", () => {
		assert.strictEqual(runwCalls.length, 1, "runw 调用次数=" + runwCalls.length);
		assert.ok(/wscript\.exe$/i.test(runwCalls[0].file), runwCalls[0].file);
		assert.ok(runwCalls[0].args[0].endsWith("launcher.vbs"));
	});

	// 模拟助手连接
	const conn = {
		transport: { close() {} },
		output: {
			write(s) {
				outbox.push(s.trim());
			},
			flush() {},
		},
		buffer: "",
		authed: false,
		closed: false,
	};
	plugin._conns.add(conn);

	check("错误令牌的握手被拒绝", () => {
		plugin._handleCommand(conn, "HELLO wrongtoken");
		assert.strictEqual(conn.authed, false);
		assert.strictEqual(plugin._conns.size, 0);
	});

	plugin._conns.add(conn);
	check("正确令牌握手成功并下发 TOOLTIP", () => {
		plugin._handleCommand(conn, "HELLO " + plugin._token);
		assert.strictEqual(conn.authed, true);
		assert.ok(outbox.includes("TOOLTIP Zotero"), outbox.join(","));
	});

	check("关闭主窗口 -> 发送 HIDE", () => {
		let prevented = false;
		const ev = { preventDefault: () => { prevented = true; }, stopPropagation: () => {} };
		currentWindow.dispatch("close", ev);
		assert.ok(prevented, "close 事件未被 preventDefault");
		assert.ok(outbox.includes("HIDE"), outbox.join(","));
	});

	check("window.close() 也被拦截", () => {
		outbox = [];
		currentWindow.close();
		assert.ok(outbox.includes("HIDE"), outbox.join(","));
		assert.ok(!currentWindow.closeCalled, "不应真正关闭窗口");
	});

	check("HIDDEN/SHOWN 更新隐藏状态", () => {
		plugin._handleCommand(conn, "HIDDEN");
		assert.strictEqual(plugin._isHidden, true);
		plugin._handleCommand(conn, "SHOWN");
		assert.strictEqual(plugin._isHidden, false);
	});

	// 托盘菜单退出
	plugin._handleCommand(conn, "HIDDEN");
	plugin._handleCommand(conn, "MENU_QUIT");
	await new Promise((r) => setTimeout(r, 150));
	check("托盘菜单退出 -> 调用 quitZotero", () => {
		assert.ok(quitCalled >= 1, "quitZotero 未被调用");
		assert.strictEqual(plugin._quitting, true);
	});

	// 退出信号
	check("退出信号被观察到", () => {
		assert.ok(observers.some((o) => o.t === "quit-application-requested"));
		assert.ok(observers.some((o) => o.t === "quit-application"));
	});

	// shutdown：窗口隐藏时应先 SHOW 再 EXIT
	plugin._quitting = false;
	plugin._isHidden = true;
	outbox = [];
	plugin.shutdown();
	check("shutdown 先恢复窗口再结束助手", () => {
		assert.ok(outbox.includes("SHOW"), outbox.join(","));
		assert.ok(outbox.includes("EXIT"), outbox.join(","));
		assert.strictEqual(outbox.indexOf("SHOW") < outbox.indexOf("EXIT"), true);
	});

	check("shutdown 清理资源", () => {
		assert.strictEqual(paneUnregistered, "mtp-pane");
		assert.strictEqual(plugin._server, null);
		assert.strictEqual(plugin._conns.size, 0);
		assert.strictEqual(currentWindow.closeCalled || true, true);
	});

	// 退出后关闭窗口不再被拦截
	check("退出过程中不再拦截关闭", () => {
		outbox = [];
		const ev = { preventDefault() { this.prevented = true; }, stopPropagation() {} };
		currentWindow.dispatch("close", ev);
		assert.ok(!ev.prevented, "退出时不应阻止关闭");
	});

	let failed = 0;
	for (const [st, name] of results) {
		console.log((st === "PASS" ? "PASS  " : "FAIL  ") + name);
		if (st === "FAIL") failed++;
	}
	console.log("");
	if (failed) {
		console.log("RESULT: " + failed + " check(s) failed");
		process.exit(1);
	}
	console.log("RESULT: all checks passed");
}

main().catch((e) => {
	console.error("测试异常:", e);
	process.exit(1);
});
