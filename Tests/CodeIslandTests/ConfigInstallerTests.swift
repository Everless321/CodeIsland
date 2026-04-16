import XCTest
@testable import CodeIsland

final class ConfigInstallerTests: XCTestCase {
    func testRemoveManagedHookEntriesAlsoPrunesLegacyVibeIslandHooks() throws {
        let hooks: [String: Any] = [
            "SessionEnd": [
                [
                    "hooks": [
                        [
                            "command": "/Users/test/.vibe-island/bin/vibe-island-bridge --source claude",
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "command": "~/.claude/hooks/codeisland-hook.sh",
                            "timeout": 5,
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "async": true,
                            "command": "~/.claude/hooks/bark-notify.sh",
                            "timeout": 10,
                            "type": "command",
                        ],
                    ],
                ],
            ],
        ]

        let cleaned = ConfigInstaller.removeManagedHookEntries(from: hooks)
        let sessionEnd = try XCTUnwrap(cleaned["SessionEnd"] as? [[String: Any]])

        XCTAssertEqual(sessionEnd.count, 1)
        let remainingHooks = try XCTUnwrap(sessionEnd.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(remainingHooks.count, 1)
        XCTAssertEqual(remainingHooks.first?["command"] as? String, "~/.claude/hooks/bark-notify.sh")
    }

    // MARK: - Kimi Code CLI TOML hooks

    func testRemoveKimiHooksPreservesNonCodeIslandBlocks() {
        let toml = """
        default_model = "kimi-k2-5"

        [[hooks]]
        event = "Stop"
        command = "/Users/test/.codeisland/codeisland-bridge --source kimi"
        timeout = 5

        [[mcpServers]]
        name = "test"
        command = "npx"

        [[hooks]]
        event = "UserPromptSubmit"
        command = "echo hello"
        timeout = 1
        """

        let cleaned = ConfigInstaller.removeKimiHooks(from: toml)
        XCTAssertFalse(cleaned.contains("codeisland-bridge"))
        XCTAssertTrue(cleaned.contains("[[mcpServers]]"))
        XCTAssertTrue(cleaned.contains("echo hello"))
        XCTAssertTrue(cleaned.contains("default_model"))
    }

    func testContentsContainsKimiHookDetectsInstalledEvent() {
        let toml = """
        [[hooks]]
        event = "PreToolUse"
        command = "/Users/test/.codeisland/codeisland-bridge --source kimi"
        timeout = 5
        matcher = ".*"

        [[hooks]]
        event = "Stop"
        command = "/Users/test/.codeisland/codeisland-bridge --source kimi"
        timeout = 5
        """

        XCTAssertTrue(ConfigInstaller.contentsContainsKimiHook(toml, event: "PreToolUse"))
        XCTAssertTrue(ConfigInstaller.contentsContainsKimiHook(toml, event: "Stop"))
        XCTAssertFalse(ConfigInstaller.contentsContainsKimiHook(toml, event: "SessionStart"))
    }

    func testKimiHookFormatEvents() {
        let events = ConfigInstaller.defaultEvents(for: .kimi)
        let eventNames = events.map { $0.0 }
        XCTAssertTrue(eventNames.contains("UserPromptSubmit"))
        XCTAssertTrue(eventNames.contains("PreToolUse"))
        XCTAssertTrue(eventNames.contains("PostToolUse"))
        XCTAssertTrue(eventNames.contains("PostToolUseFailure"))
        XCTAssertFalse(eventNames.contains("PermissionRequest"), "Kimi does not support PermissionRequest")
        XCTAssertTrue(eventNames.contains("Stop"))
        XCTAssertTrue(eventNames.contains("SessionStart"))
        XCTAssertTrue(eventNames.contains("SessionEnd"))
        XCTAssertTrue(eventNames.contains("Notification"))
        XCTAssertTrue(eventNames.contains("PreCompact"))

        let notificationTimeout = events.first { $0.0 == "Notification" }?.1
        XCTAssertEqual(notificationTimeout, 600, "Kimi max timeout is 600")
    }

    /// Hermetic integration test: uses a temporary directory instead of touching ~/.kimi/config.toml.
    func testInstallKimiHooksIntegration() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config.toml").path
        let originalScalar = "hooks = [\"UserPromptSubmit\"]\n"
        fm.createFile(atPath: configPath, contents: originalScalar.data(using: .utf8))

        let cli = CLIConfig(
            name: "Kimi Code CLI",
            source: "kimi",
            configPath: configPath,
            configKey: "hooks",
            format: .kimi,
            events: ConfigInstaller.defaultEvents(for: .kimi)
        )

        // Install hooks
        XCTAssertTrue(ConfigInstaller.installKimiHooks(cli: cli, fm: fm))

        // Verify file contents
        let data = try XCTUnwrap(fm.contents(atPath: configPath))
        let installed = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(installed.contains("[[hooks]]"))
        XCTAssertTrue(installed.contains("event = \"PreToolUse\""))
        XCTAssertTrue(installed.contains("event = \"Stop\""))
        XCTAssertTrue(installed.contains("codeisland-bridge --source kimi"))
        XCTAssertFalse(installed.contains("\nhooks = "), "Scalar hooks key should be commented out to avoid TOML duplicate key error")
        XCTAssertTrue(installed.contains("# hooks ="), "Legacy scalar hooks should be preserved as comments")

        // Uninstall and verify legacy hooks are restored
        ConfigInstaller.uninstallHooks(cli: cli, fm: fm)
        let uninstalledData = try XCTUnwrap(fm.contents(atPath: configPath))
        let uninstalled = try XCTUnwrap(String(data: uninstalledData, encoding: .utf8))

        XCTAssertTrue(uninstalled.contains("hooks = [\"UserPromptSubmit\"]"), "Legacy scalar hooks should be restored after uninstall")
        XCTAssertFalse(uninstalled.contains("codeisland-bridge"), "CodeIsland hooks should be removed after uninstall")
    }
}


