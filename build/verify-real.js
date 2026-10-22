// 在真实 Zotero 10 中做一次端到端验证：
// 安装 XPI -> 等待启动 -> 检查插件是否激活 -> 检查托盘助手是否真的拉起 -> 关掉 Zotero 看助手是否自退
const { spawn, execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const prof = path.join(root, "build", "_zp10");
const data = path.join(root, "build", "_zd10");
const xpi = path.join(root, "dist", "minimize-to-tray-plus-1.3.0.xpi");

function rmrf(p) {
	if (fs.existsSync(p)) fs.rmSync(p, { recursive: true, force: true });
}
rmrf(prof);
rmrf(data);
fs.mkdirSync(path.join(prof, "extensions"), { recursive: true });
fs.mkdirSync(data, { recursive: true });
fs.copyFileSync(xpi, path.join(prof, "extensions", "minimize-to-tray-plus@local.xpi"));

const prefs = [
	'user_pref("extensions.zotero.useDataDir", true);',
	`user_pref("extensions.zotero.dataDir", ${JSON.stringify(data)});`,
	'user_pref("extensions.zotero.firstRun2", true);',
	'user_pref("extensions.zotero.sync.server.username", "");',
	'user_pref("extensions.autoDisableScopes", 0);',
	'user_pref("extensions.enabledScopes", 15);',
	"",
].join("\n");
fs.writeFileSync(path.join(prof, "prefs.js"), prefs, "utf8");

function helperPids() {
	try {
		const out = execSync(
			'powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \\"Name=\'powershell.exe\'\\" | Where-Object { $_.CommandLine -like \'*tray-helper*\' } | ForEach-Object { $_.ProcessId }"',
			{ encoding: "utf8", timeout: 30000 }
		);
		return out.split(/\s+/).filter(Boolean).map(Number);
	}
	catch (e) {
		return [];
	}
}

(async () => {
	const zot = spawn("D:\\Program Files\\Zotero\\zotero.exe", ["-profile", prof, "-no-remote"], {
		stdio: "ignore",
	});
	console.log("zotero pid=" + zot.pid);

	await new Promise((r) => setTimeout(r, 45000));

	const raw = fs.readFileSync(path.join(prof, "extensions.json"), "utf8");
	const i = raw.indexOf('"id":"minimize-to-tray-plus@local"');
	console.log("addon listed: " + (i >= 0));
	if (i >= 0) {
		const seg = raw.slice(i, i + 700);
		console.log("active=" + /"active":true/.test(seg) + " appDisabled=" + /"appDisabled":true/.test(seg));
	}

	const dir = path.join(prof, "minimize-to-tray-plus");
	const files = fs.existsSync(dir) ? fs.readdirSync(dir) : [];
	console.log("helper dir files: " + JSON.stringify(files));
	const logPath = path.join(dir, "tray-helper.log");
	console.log("helper log exists: " + fs.existsSync(logPath));
	if (fs.existsSync(logPath)) {
		console.log(fs.readFileSync(logPath, "utf8").split(/\r?\n/).slice(0, 12).join("\n"));
	}

	const before = helperPids();
	console.log("helper pids while running: " + JSON.stringify(before));

	zot.kill();
	await new Promise((r) => setTimeout(r, 8000));
	const after = helperPids();
	console.log("zotero alive after kill: " + (zot.exitCode === null && zot.signalCode === null));
	console.log("helper pids after kill: " + JSON.stringify(after));
	process.exit(0);
})();
