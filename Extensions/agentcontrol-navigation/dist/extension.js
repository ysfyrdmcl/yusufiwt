"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.activate = activate;
exports.deactivate = deactivate;
const vscode = __importStar(require("vscode"));
const registrations = new Map();
async function activate(context) {
    context.subscriptions.push(vscode.commands.registerCommand("agentcontrol.captureTerminalContext", captureTerminalContext), vscode.commands.registerCommand("agentcontrol.registerTerminal", registerTerminal), vscode.window.registerUriHandler({ handleUri: revealTerminal }), vscode.window.onDidCloseTerminal((terminal) => {
        for (const [token, registration] of registrations) {
            if (registration.terminal === terminal)
                registrations.delete(token);
        }
    }));
}
async function captureTerminalContext(token) {
    const terminal = vscode.window.activeTerminal;
    if (!terminal)
        return undefined;
    const processId = await terminal.processId;
    const workspaceURI = vscode.workspace.workspaceFolders?.[0]?.uri.toString();
    if (token)
        registrations.set(token, { terminal, processId, workspaceURI });
    return {
        correlationToken: token,
        processId,
        terminalName: terminal.name,
        workspaceURI,
        applicationBundleID: vscode.env.appName.toLowerCase().includes("cursor")
            ? "com.todesktop.230313mzl4w4u92"
            : "com.microsoft.VSCode"
    };
}
async function registerTerminal(token) {
    if (!token) {
        token = await vscode.window.showInputBox({ prompt: "AgentControl session correlation token" });
    }
    if (!token)
        return;
    const captured = await captureTerminalContext(token);
    if (!captured)
        vscode.window.showWarningMessage("AgentControl: no active terminal to register.");
}
async function revealTerminal(uri) {
    if (uri.path !== "/reveal")
        return;
    const token = new URLSearchParams(uri.query).get("token");
    const registration = token ? registrations.get(token) : undefined;
    if (registration) {
        registration.terminal.show(false);
        await reportResult(token, "exactPane");
        return;
    }
    const workspace = new URLSearchParams(uri.query).get("workspace");
    if (workspace) {
        await vscode.commands.executeCommand("vscode.openFolder", vscode.Uri.parse(workspace), false);
        await reportResult(token, "projectFolder");
    }
    else {
        await reportResult(token, "unsupported");
    }
    vscode.window.showWarningMessage("AgentControl could not find the exact terminal; the workspace was opened instead.");
}
async function reportResult(token, level) {
    if (!token)
        return;
    const callback = vscode.Uri.from({
        scheme: "agentcontrol",
        authority: "navigation-result",
        query: new URLSearchParams({ token, level }).toString()
    });
    await vscode.env.openExternal(callback);
}
function deactivate() {
    registrations.clear();
}
