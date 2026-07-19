import * as vscode from "vscode";

type TerminalRegistration = {
  terminal: vscode.Terminal;
  processId?: number;
  workspaceURI?: string;
};

const registrations = new Map<string, TerminalRegistration>();

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  context.subscriptions.push(
    vscode.commands.registerCommand("agentcontrol.captureTerminalContext", captureTerminalContext),
    vscode.commands.registerCommand("agentcontrol.registerTerminal", registerTerminal),
    vscode.window.registerUriHandler({ handleUri: revealTerminal }),
    vscode.window.onDidCloseTerminal((terminal) => {
      for (const [token, registration] of registrations) {
        if (registration.terminal === terminal) registrations.delete(token);
      }
    })
  );
}

async function captureTerminalContext(token?: string): Promise<Record<string, unknown> | undefined> {
  const terminal = vscode.window.activeTerminal;
  if (!terminal) return undefined;
  const processId = await terminal.processId;
  const workspaceURI = vscode.workspace.workspaceFolders?.[0]?.uri.toString();
  if (token) registrations.set(token, { terminal, processId, workspaceURI });
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

async function registerTerminal(token?: string): Promise<void> {
  if (!token) {
    token = await vscode.window.showInputBox({ prompt: "yusufiwt session correlation token" });
  }
  if (!token) return;
  const captured = await captureTerminalContext(token);
  if (!captured) vscode.window.showWarningMessage("yusufiwt: no active terminal to register.");
}

async function revealTerminal(uri: vscode.Uri): Promise<void> {
  if (uri.path !== "/reveal") return;
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
  } else {
    await reportResult(token, "unsupported");
  }
  vscode.window.showWarningMessage("yusufiwt could not find the exact terminal; the workspace was opened instead.");
}

async function reportResult(token: string | null, level: string): Promise<void> {
  if (!token) return;
  const callback = vscode.Uri.from({
    scheme: "agentcontrol",
    authority: "navigation-result",
    query: new URLSearchParams({ token, level }).toString()
  });
  await vscode.env.openExternal(callback);
}

export function deactivate(): void {
  registrations.clear();
}
