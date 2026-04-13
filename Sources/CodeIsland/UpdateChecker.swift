import AppKit
import Combine
import os.log

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, dmgURL: String?, releaseURL: String)
    case downloading(progress: Double)
    case installing
    case failed(String)
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    private static let log = Logger(subsystem: "com.codeisland", category: "UpdateChecker")
    private let repo = "wxtsky/CodeIsland"

    @Published var state: UpdateState = .idle

    private var currentVersion: String { AppVersion.current }
    private var isChecking = false

    var isHomebrewInstall: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/Caskroom/") || path.contains("/homebrew/")
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        if currentVersion == AppVersion.fallback && Bundle.main.bundleIdentifier == nil { return }
        isChecking = true
        state = .checking

        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            state = .failed("Invalid URL")
            isChecking = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        Task {
            defer { isChecking = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else {
                    state = .failed("Invalid response")
                    return
                }

                let remote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

                var dmgURL: String?
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

                if isNewer(remote: remote, local: currentVersion) {
                    state = .available(version: remote, dmgURL: dmgURL, releaseURL: htmlURL)
                } else {
                    state = .upToDate
                }
            } catch {
                Self.log.debug("Update check failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func performUpdate() {
        guard case let .available(_, dmgURL, releaseURL) = state else { return }
        guard let dmgURL, let downloadURL = URL(string: dmgURL) else {
            if let url = URL(string: releaseURL) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        state = .downloading(progress: 0)

        let currentAppPath = Bundle.main.bundlePath
        let dmgPath = NSTemporaryDirectory() + "CodeIsland-update.dmg"
        let mountPoint = "/tmp/codeisland-update-mount"

        Task {
            do {
                // 1. Download DMG with progress via URLSessionDownloadDelegate
                Self.log.info("Downloading update from \(downloadURL.absoluteString)")
                let progressDelegate = DownloadProgressDelegate { [weak self] progress in
                    Task { @MainActor in self?.state = .downloading(progress: progress) }
                }
                let session = URLSession(configuration: .default, delegate: progressDelegate, delegateQueue: nil)
                let (tempURL, _) = try await session.download(from: downloadURL, delegate: progressDelegate)
                session.invalidateAndCancel()

                state = .downloading(progress: 1.0)

                // 2. Move downloaded file, mount, replace — all off main thread
                state = .installing
                try await Task.detached {
                    let fm = FileManager.default
                    // Move downloaded temp file to known path
                    try? fm.removeItem(atPath: dmgPath)
                    try fm.moveItem(at: tempURL, to: URL(fileURLWithPath: dmgPath))

                    // Mount DMG
                    try Self.runShellProcess("/usr/bin/hdiutil", args: ["attach", "-nobrowse", "-quiet", "-mountpoint", mountPoint, dmgPath])

                    // Find .app in mounted volume
                    guard let contents = try? fm.contentsOfDirectory(atPath: mountPoint),
                          let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                        _ = try? Self.runShellProcess("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"])
                        try? fm.removeItem(atPath: dmgPath)
                        throw UpdateError.appNotFoundInDMG
                    }

                    // Replace current app
                    let sourceAppPath = mountPoint + "/" + appName
                    if fm.fileExists(atPath: currentAppPath) {
                        try fm.removeItem(atPath: currentAppPath)
                    }
                    try fm.copyItem(atPath: sourceAppPath, toPath: currentAppPath)

                    // Cleanup
                    _ = try? Self.runShellProcess("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"])
                    try? fm.removeItem(atPath: dmgPath)
                }.value

                // 3. Relaunch (back on MainActor)
                Self.log.info("Relaunching app")
                NSWorkspace.shared.open(URL(fileURLWithPath: currentAppPath))
                try await Task.sleep(nanoseconds: 500_000_000)
                NSApp.terminate(nil)

            } catch {
                Self.log.error("Update failed: \(error.localizedDescription)")
                await Task.detached {
                    _ = try? Self.runShellProcess("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"])
                    try? FileManager.default.removeItem(atPath: dmgPath)
                }.value
                state = .failed(error.localizedDescription)
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

    @discardableResult
    private nonisolated static func runShellProcess(_ executable: String, args: [String]) throws -> String {
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
            "App not found in DMG"
        }
    }
}

// MARK: - Download progress delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled by the async download(from:delegate:) return value
    }
}
