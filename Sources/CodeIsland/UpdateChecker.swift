import AppKit
import Combine
import os.log

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    private static let log = Logger(subsystem: "com.codeisland", category: "UpdateChecker")
    private let repo = "wxtsky/CodeIsland"

    @Published var isDownloading = false

    private var currentVersion: String { AppVersion.current }

    private var isHomebrewInstall: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/Caskroom/") || path.contains("/homebrew/")
    }

    func checkForUpdates(silent: Bool = true) {
        // Skip silent check in Xcode preview / test environment
        if silent && currentVersion == AppVersion.fallback && Bundle.main.bundleIdentifier == nil { return }

        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else { return }

                let remote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let local = self.currentVersion

                // Find DMG asset download URL
                var dmgURL: String? = nil
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String,
                           name.hasSuffix(".dmg"),
                           let downloadURL = asset["browser_download_url"] as? String {
                            dmgURL = downloadURL
                            break
                        }
                    }
                }

                if self.isNewer(remote: remote, local: local) {
                    self.showUpdateAlert(remoteVersion: remote, releaseURL: htmlURL, dmgURL: dmgURL)
                } else if !silent {
                    self.showUpToDateAlert()
                }
            } catch {
                Self.log.debug("Update check failed: \(error.localizedDescription)")
            }
        }
    }

    private func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    private func showUpdateAlert(remoteVersion: String, releaseURL: String, dmgURL: String?) {
        if isHomebrewInstall {
            showHomebrewAlert(remoteVersion: remoteVersion)
            return
        }

        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.regular)
        }

        let alert = NSAlert()
        alert.messageText = L10n.shared["update_available_title"]
        alert.informativeText = String(format: L10n.shared["update_available_body"], remoteVersion, currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.shared["update_now"])
        alert.addButton(withTitle: L10n.shared["later"])

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.accessory)
        }

        if response == .alertFirstButtonReturn {
            if let dmgURL, let downloadURL = URL(string: dmgURL) {
                Task {
                    await self.performUpdate(dmgURL: downloadURL, releaseURL: releaseURL)
                }
            } else if let url = URL(string: releaseURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showHomebrewAlert(remoteVersion: String) {
        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.regular)
        }

        let alert = NSAlert()
        alert.messageText = L10n.shared["update_homebrew_title"]
        alert.informativeText = String(format: L10n.shared["update_homebrew_body"], remoteVersion)
        alert.alertStyle = .informational
        // Show the brew command in a text field so it's visible
        let tf = NSTextField(string: L10n.shared["update_homebrew_command"])
        tf.isEditable = false
        tf.isBezeled = true
        tf.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        alert.accessoryView = tf
        alert.addButton(withTitle: L10n.shared["update_copy_command"])
        alert.addButton(withTitle: L10n.shared["ok"])

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.accessory)
        }

        if response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(L10n.shared["update_homebrew_command"], forType: .string)
        }
    }

    private func showUpToDateAlert() {
        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.regular)
        }

        let alert = NSAlert()
        alert.messageText = L10n.shared["no_update_title"]
        alert.informativeText = String(format: L10n.shared["no_update_body"], currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.shared["ok"])

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func showUpdateFailedAlert(message: String, releaseURL: String) {
        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.regular)
        }

        let alert = NSAlert()
        alert.messageText = L10n.shared["update_failed_title"]
        alert.informativeText = String(format: L10n.shared["update_failed_body"], message)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.shared["update_manual_download"])
        alert.addButton(withTitle: L10n.shared["ok"])

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.accessory)
        }

        if response == .alertFirstButtonReturn, let url = URL(string: releaseURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Auto-update flow

    private func performUpdate(dmgURL: URL, releaseURL: String) async {
        isDownloading = true
        defer { isDownloading = false }

        let tempDir = NSTemporaryDirectory()
        let dmgPath = tempDir + "CodeIsland-update.dmg"
        let mountPoint = "/tmp/codeisland-update-mount"

        do {
            // 1. Download DMG
            Self.log.info("Downloading update from \(dmgURL.absoluteString)")
            let (data, _) = try await URLSession.shared.data(from: dmgURL)
            try data.write(to: URL(fileURLWithPath: dmgPath))

            // 2. Mount DMG
            Self.log.info("Mounting DMG at \(dmgPath)")
            let attachOutput = try runProcess(
                "/usr/bin/hdiutil",
                args: ["attach", "-nobrowse", "-quiet", "-mountpoint", mountPoint, dmgPath]
            )
            Self.log.debug("hdiutil attach output: \(attachOutput)")

            // 3. Find CodeIsland.app in mounted volume
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(atPath: mountPoint),
                  let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                _ = try? runProcess("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"])
                try? fm.removeItem(atPath: dmgPath)
                throw UpdateError.appNotFoundInDMG
            }

            let sourceAppPath = mountPoint + "/" + appName
            let currentAppPath = Bundle.main.bundlePath

            // 4. Replace current app
            Self.log.info("Replacing \(currentAppPath) with \(sourceAppPath)")
            if fm.fileExists(atPath: currentAppPath) {
                try fm.removeItem(atPath: currentAppPath)
            }
            try fm.copyItem(atPath: sourceAppPath, toPath: currentAppPath)

            // 5. Unmount and cleanup
            _ = try? runProcess("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"])
            try? fm.removeItem(atPath: dmgPath)

            // 6. Relaunch
            Self.log.info("Relaunching app")
            NSWorkspace.shared.open(URL(fileURLWithPath: currentAppPath))
            try await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)

        } catch {
            Self.log.error("Update failed: \(error.localizedDescription)")
            _ = try? runProcess("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"])
            try? FileManager.default.removeItem(atPath: dmgPath)
            showUpdateFailedAlert(message: error.localizedDescription, releaseURL: releaseURL)
        }
    }

    @discardableResult
    private nonisolated func runProcess(_ executable: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private enum UpdateError: LocalizedError {
        case appNotFoundInDMG

        var errorDescription: String? {
            switch self {
            case .appNotFoundInDMG:
                return "Could not find the app bundle in the downloaded disk image."
            }
        }
    }
}
