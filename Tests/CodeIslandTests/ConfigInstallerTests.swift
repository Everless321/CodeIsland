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
}
