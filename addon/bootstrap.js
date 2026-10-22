/* global Zotero, ChromeUtils, Services */

// Firefox 140（Zotero 8 及以后）已把 Services.jsm 改为 ESM，
// 这里按 全局对象 → Services.sys.mjs → 旧 Services.jsm 的顺序兜底获取。
function getServices() {
	if (typeof Services !== "undefined" && Services) {
		return Services;
	}
	if (globalThis.Services) {
		return globalThis.Services;
	}
	try {
		const CU = (typeof ChromeUtils !== "undefined") ? ChromeUtils : globalThis.ChromeUtils;
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
	}
	catch (e) {}
	return null;
}

var MTP_Svcs = getServices();

function log(msg) {
	try {
		Zotero.debug("[MinimizeToTray+] " + msg);
	}
	catch (e) {}
}

function install() {}

function uninstall() {}

async function startup({ id, version, rootURI }, reason) {
	await Zotero.initializationPromise;

	// 插件被禁用后重新启用（不重启 Zotero）时，先清理旧实例
	if (Zotero.MinimizeToTrayPlus) {
		try {
			Zotero.MinimizeToTrayPlus.shutdown();
		}
		catch (e) {
			log("shutdown of previous instance failed: " + e);
		}
		delete Zotero.MinimizeToTrayPlus;
	}

	if (!MTP_Svcs) {
		log("Services unavailable; plugin disabled");
		return;
	}

	MTP_Svcs.scriptloader.loadSubScript(rootURI + "content/scripts/main.js", globalThis);
	Zotero.MinimizeToTrayPlus.init({ id, version, rootURI });
}

function shutdown(data, reason) {
	if (Zotero.MinimizeToTrayPlus) {
		try {
			Zotero.MinimizeToTrayPlus.shutdown();
		}
		catch (e) {
			log("shutdown failed: " + e);
		}
		delete Zotero.MinimizeToTrayPlus;
	}
}

function onMainWindowLoad({ window }) {
	if (Zotero.MinimizeToTrayPlus) {
		Zotero.MinimizeToTrayPlus.onMainWindowLoad(window);
	}
}

function onMainWindowUnload({ window }) {
	if (Zotero.MinimizeToTrayPlus) {
		Zotero.MinimizeToTrayPlus.onMainWindowUnload(window);
	}
}
