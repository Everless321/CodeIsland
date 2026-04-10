import AppKit
import CodeIslandCore

/// Activates the terminal window/tab running a specific Claude Code session.
/// Supports tab-level switching for: Ghostty, iTerm2, Terminal.app, WezTerm, kitty.
/// Falls back to app-level activation for: Alacritty, Warp, Hyper, Tabby, Rio.
struct TerminalActivator {

    private static let knownTerminals: [(name: String, bundleId: String)] = [
        ("Ghostty", "com.mitchellh.ghostty"),
        ("iTerm2", "com.googlecode.iterm2"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("Alacritty", "org.alacritty"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Terminal", "com.apple.Terminal"),
    ]

    /// Fallback: source-based app jump for CLIs with NO terminal mode.
    /// Most sources should use nativeAppBundles instead (by bundle ID).
    private static let appSources: [String: String] = [:]

    /// Bundle IDs of apps that have both APP and CLI modes.
    /// When termBundleId matches, bring that app to front;
    /// otherwise fall through to terminal tab-matching.
    private static let nativeAppBundles: [String: String] = [
        "com.openai.codex": "Codex",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.qoder.ide": "Qoder",
        "com.factory.app": "Factory",
        "com.tencent.codebuddy": "CodeBuddy",
        "ai.opencode.desktop": "OpenCode",
    ]

    static func activate(session: SessionSnapshot, sessionId: String? = nil) {
        // Collaborator: focus the canvas tile, not just the app window
        if session.termBundleId == "com.collaborator.desktop" {
            activateCollaborator(session: session)
            return
        }

        // Native app by bundle ID (e.g. Codex APP vs Codex CLI)
        if let bundleId = session.termBundleId,
           let appName = nativeAppBundles[bundleId] {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleId
            }) {
                if app.isHidden { app.unhide() }
                app.activate(options: .activateIgnoringOtherApps)
            } else {
                bringToFront(appName)
            }
            return
        }

        // IDE sources: just bring the app to front
        if let appName = appSources[session.source] {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName == appName
            }) {
                if app.isHidden { app.unhide() }
                app.activate(options: .activateIgnoringOtherApps)
            } else {
                bringToFront(appName)
            }
            return
        }

        // Resolve terminal: bundle ID (most accurate) → TERM_PROGRAM → scan running apps
        let termApp: String
        if let bundleId = session.termBundleId,
           let resolved = knownTerminals.first(where: { $0.bundleId == bundleId })?.name {
            termApp = resolved
        } else {
            let raw = session.termApp ?? ""
            // "tmux" / "screen" etc. are not GUI apps — fall back to scanning
            if raw.isEmpty || raw.lowercased() == "tmux" || raw.lowercased() == "screen" {
                termApp = detectRunningTerminal()
            } else {
                termApp = raw
            }
        }
        let lower = termApp.lowercased()

        // --- tmux: switch pane first, then bring terminal to front ---
        if let pane = session.tmuxPane, !pane.isEmpty {
            activateTmux(pane: pane)
            bringToFront(termApp)
            return
        }

        // --- Tab-level switching (5 terminals) ---

        if lower.contains("iterm") {
            if let itermId = session.itermSessionId, !itermId.isEmpty {
                activateITerm(sessionId: itermId)
            } else {
                bringToFront("iTerm2")
            }
            return
        }

        if lower.contains("ghostty") {
            activateGhostty(cwd: session.cwd, sessionId: sessionId, source: session.source)
            return
        }

        if lower.contains("terminal") || lower.contains("apple_terminal") {
            activateTerminalApp(ttyPath: session.ttyPath)
            return
        }

        if lower.contains("wezterm") || lower.contains("wez") {
            activateWezTerm(ttyPath: session.ttyPath, cwd: session.cwd)
            return
        }

        if lower.contains("kitty") {
            activateKitty(windowId: session.kittyWindowId, cwd: session.cwd, source: session.source)
            return
        }

        // --- App-level only (Alacritty, Warp, Hyper, Tabby, Rio, etc.) ---
        bringToFront(termApp)
    }

    // MARK: - Ghostty (AppleScript: match by CWD + session ID in title)

    private static func activateGhostty(cwd: String?, sessionId: String? = nil, source: String = "claude") {
        guard let cwd = cwd, !cwd.isEmpty else { bringToFront("Ghostty"); return }
        // Ensure app is unhidden and brought to front (Space switching)
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" }) {
            if app.isHidden { app.unhide() }
            app.activate(options: .activateIgnoringOtherApps)
        }
        let escaped = escapeAppleScript(cwd)
        // Match by session ID in title first (disambiguates same-CWD sessions),
        // then by source-specific keyword in title, then first CWD match
        let idFilter: String
        if let sid = sessionId, !sid.isEmpty {
            let escapedSid = escapeAppleScript(String(sid.prefix(8)))
            idFilter = """
                repeat with t in matches
                    if name of t contains "\(escapedSid)" then
                        focus t
                        activate
                        return
                    end if
                end repeat
            """
        } else {
            idFilter = ""
        }
        // Use source name as keyword to prefer the right tab when multiple share CWD
        let keyword = escapeAppleScript(source)
        let script = """
        tell application "Ghostty"
            set matches to (every terminal whose working directory is "\(escaped)")
            \(idFilter)
            repeat with t in matches
                if name of t contains "\(keyword)" then
                    focus t
                    activate
                    return
                end if
            end repeat
            if (count of matches) > 0 then
                focus (item 1 of matches)
            end if
            activate
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - iTerm2 (AppleScript: match by session ID)

    private static func activateITerm(sessionId: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.googlecode.iterm2" }) {
            if app.isHidden { app.unhide() }
            app.activate(options: .activateIgnoringOtherApps)
        }
        let script = """
        try
            tell application "iTerm2"
                repeat with aWindow in windows
                    if miniaturized of aWindow then set miniaturized of aWindow to false
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if unique ID of aSession is "\(escapeAppleScript(sessionId))" then
                                set miniaturized of aWindow to false
                                select aTab
                                select aSession
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        end try
        """
        runAppleScript(script)
    }

    // MARK: - Terminal.app (AppleScript: match by TTY)

    private static func activateTerminalApp(ttyPath: String?) {
        guard let tty = ttyPath, !tty.isEmpty else { bringToFront("Terminal"); return }
        let escaped = escapeAppleScript(tty)
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escaped)" then
                        if miniaturized of w then set miniaturized of w to false
                        set selected tab of w to t
                        set index of w to 1
                    end if
                end repeat
            end repeat
            activate
        end tell
        """
        runAppleScript(script)
    }

    // MARK: - WezTerm (CLI: wezterm cli list + activate-tab)

    private static func activateWezTerm(ttyPath: String?, cwd: String?) {
        bringToFront("WezTerm")
        guard let bin = findBinary("wezterm") else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let json = runProcess(bin, args: ["cli", "list", "--format", "json"]),
                  let panes = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return }

            // Find tab: prefer TTY match, fallback to CWD
            var tabId: Int?
            if let tty = ttyPath {
                tabId = panes.first(where: { ($0["tty_name"] as? String) == tty })?["tab_id"] as? Int
            }
            if tabId == nil, let cwd = cwd {
                let cwdUrl = "file://" + cwd
                tabId = panes.first(where: {
                    guard let paneCwd = $0["cwd"] as? String else { return false }
                    return paneCwd == cwdUrl || paneCwd == cwd
                })?["tab_id"] as? Int
            }

            if let id = tabId {
                _ = runProcess(bin, args: ["cli", "activate-tab", "--tab-id", "\(id)"])
            }
        }
    }

    // MARK: - kitty (CLI: kitten @ focus-window/focus-tab)

    private static func activateKitty(windowId: String?, cwd: String?, source: String = "claude") {
        bringToFront("kitty")
        guard let bin = findBinary("kitten") else { return }

        // Prefer window ID for precise switching
        if let windowId = windowId, !windowId.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = runProcess(bin, args: ["@", "focus-window", "--match", "id:\(windowId)"])
            }
            return
        }

        // Fallback to CWD matching, then title with source keyword
        guard let cwd = cwd, !cwd.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if runProcess(bin, args: ["@", "focus-tab", "--match", "cwd:\(cwd)"]) == nil {
                _ = runProcess(bin, args: ["@", "focus-tab", "--match", "title:\(source)"])
            }
        }
    }

    // MARK: - tmux (CLI: tmux select-window/select-pane)

    private static func activateTmux(pane: String) {
        guard let bin = findBinary("tmux") else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Switch to the window containing the pane, then select the pane
            _ = runProcess(bin, args: ["select-window", "-t", pane])
            _ = runProcess(bin, args: ["select-pane", "-t", pane])
        }
    }

    // MARK: - Collaborator (JSON-RPC canvas.tileFocus)

    private static func activateCollaborator(session: SessionSnapshot) {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.collaborator.desktop"
        }) {
            if app.isHidden { app.unhide() }
            app.activate(options: .activateIgnoringOtherApps)
        } else {
            bringToFront("Collaborator")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let tileId = resolveCollaboratorTile(session: session) else { return }

            let socketPathFile = NSHomeDirectory() + "/.collaborator/socket-path"
            guard let socketPath = try? String(contentsOfFile: socketPathFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !socketPath.isEmpty else { return }

            collabRpc(socketPath: socketPath, method: "canvas.tileFocus",
                      params: ["tileIds": [tileId]])
        }
    }

    /// Resolve which Collaborator canvas tile corresponds to this session.
    ///
    /// Strategies (in priority order):
    /// 1. tmux pane → session name (`collab-<ptySessionId>`) → tile
    /// 2. tmux socket path contains ptySessionId → tile
    /// 3. PID hierarchy: walk up from cliPid to find the tile's shell process
    /// 4. cwd match (last resort — ambiguous when multiple tiles share CWD)
    private static func resolveCollaboratorTile(session: SessionSnapshot) -> String? {
        let base = NSHomeDirectory() + "/.collaborator"

        var dataDirs = [base]
        let devDir = base + "/dev"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: devDir) {
            dataDirs += entries.map { devDir + "/" + $0 }
        }

        // Collect all (tileId, ptySessionId) pairs across canvases
        var tilePairs: [(tileId: String, ptyId: String, dir: String)] = []
        for dir in dataDirs {
            let canvasFile = dir + "/canvas-state.json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: canvasFile)),
                  let canvas = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tiles = canvas["tiles"] as? [[String: Any]] else { continue }
            for tile in tiles where tile["type"] as? String == "term" {
                if let tileId = tile["id"] as? String,
                   let ptyId = tile["ptySessionId"] as? String {
                    tilePairs.append((tileId, ptyId, dir))
                }
            }
        }

        // Strategy 1: tmux pane → session name → ptySessionId
        if let tmuxPane = session.tmuxPane, !tmuxPane.isEmpty,
           let tmuxSocket = session.tmuxSocketPath, !tmuxSocket.isEmpty,
           let tmuxBin = findBinary("tmux"),
           let output = runProcess(tmuxBin, args: ["-S", tmuxSocket, "list-panes", "-a",
                                                    "-F", "#{pane_id}\t#{session_name}"]) {
            let lines = (String(data: output, encoding: .utf8) ?? "").split(separator: "\n")
            for line in lines {
                let parts = line.split(separator: "\t", maxSplits: 1)
                if parts.count == 2 && String(parts[0]) == tmuxPane {
                    let sessionName = String(parts[1])
                    if sessionName.hasPrefix("collab-") {
                        let ptyId = String(sessionName.dropFirst("collab-".count))
                        if let match = tilePairs.first(where: { $0.ptyId == ptyId }) {
                            return match.tileId
                        }
                    }
                    break
                }
            }
        }

        // Strategy 2: tmux socket path contains a ptySessionId
        if let socketPath = session.tmuxSocketPath, !socketPath.isEmpty {
            for pair in tilePairs {
                if socketPath.contains(pair.ptyId) {
                    return pair.tileId
                }
            }
        }

        // Strategy 3: PID hierarchy — walk up from cliPid, match tile's shell PID
        if let cliPid = session.cliPid, cliPid > 0 {
            for pair in tilePairs {
                let metaFile = pair.dir + "/terminal-sessions/\(pair.ptyId).json"
                guard let metaData = try? Data(contentsOf: URL(fileURLWithPath: metaFile)),
                      let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                      let tilePid = meta["pid"] as? Int, tilePid > 0 else { continue }

                var current = cliPid
                for _ in 0..<10 {
                    if Int(current) == tilePid { return pair.tileId }
                    guard let ppid = PIDResolver.parentPid(of: current), ppid > 1 else { break }
                    current = ppid
                }
            }
        }

        // Strategy 4 (last resort): cwd match
        if let cwd = session.cwd, !cwd.isEmpty {
            for pair in tilePairs {
                let metaFile = pair.dir + "/terminal-sessions/\(pair.ptyId).json"
                guard let metaData = try? Data(contentsOf: URL(fileURLWithPath: metaFile)),
                      let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                      let tileCwd = meta["cwd"] as? String else { continue }
                if tileCwd == cwd { return pair.tileId }
            }
        }

        return nil
    }

    /// Send a JSON-RPC request to Collaborator's Unix socket.
    @discardableResult
    private static func collabRpc(socketPath: String, method: String, params: [String: Any]) -> [String: Any]? {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { _ = strcpy(ptr, $0) }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1,
            "method": method, "params": params,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        data.append(0x0A)

        let sent = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return send(sock, base, buf.count, 0)
        }
        guard sent == data.count else { return nil }

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(sock, &buf, buf.count, 0)
            if n <= 0 { break }
            response.append(contentsOf: buf[..<n])
            if response.contains(0x0A) { break }
        }

        return (try? JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    // MARK: - Generic (bring app to front)

    private static func bringToFront(_ termApp: String) {
        let name: String
        let lower = termApp.lowercased()
        if lower.contains("ghostty") { name = "Ghostty" }
        else if lower.contains("iterm") { name = "iTerm2" }
        else if lower.contains("terminal") || lower.contains("apple_terminal") { name = "Terminal" }
        else if lower.contains("wezterm") || lower.contains("wez") { name = "WezTerm" }
        else if lower.contains("alacritty") || lower.contains("lacritty") { name = "Alacritty" }
        else if lower.contains("kitty") { name = "kitty" }
        else if lower.contains("warp") { name = "Warp" }
        else if lower.contains("hyper") { name = "Hyper" }
        else if lower.contains("tabby") { name = "Tabby" }
        else if lower.contains("rio") { name = "Rio" }
        else { name = termApp }

        // Try NSRunningApplication first — handles Space switching and unhide
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(name)
        }) {
            if app.isHidden { app.unhide() }
            app.activate(options: .activateIgnoringOtherApps)
            return
        }
        // Fallback: open -a (app not running yet)
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", name]
            try? proc.run()
        }
    }

    // MARK: - Helpers

    private static func detectRunningTerminal() -> String {
        let running = NSWorkspace.shared.runningApplications
        for (name, bundleId) in knownTerminals {
            if running.contains(where: { $0.bundleIdentifier == bundleId }) {
                return name
            }
        }
        return "Terminal"
    }

    private static func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let script = NSAppleScript(source: source) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
            }
        }
    }

    /// Escape special characters for AppleScript string interpolation
    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Find a CLI binary in common paths (Homebrew Intel + Apple Silicon, system)
    private static func findBinary(_ name: String) -> String? {
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run a process and return stdout. Returns nil on failure.
    @discardableResult
    private static func runProcess(_ path: String, args: [String]) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            // Read BEFORE wait to avoid deadlock (pipe buffer full blocks the process)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return proc.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }
}
