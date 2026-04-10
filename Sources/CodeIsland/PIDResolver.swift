import Darwin
import Foundation
import os.log
import CodeIslandCore

enum PIDResolver {
    private static let log = Logger(subsystem: "com.codeisland", category: "PIDResolver")

    static func pidForLocalPort(_ port: UInt16) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [
            "-i", "TCP@127.0.0.1:\(port)",
            "-sTCP:ESTABLISHED",
            "-n", "-P", "-Fp"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            log.error("lsof launch failed: \(error)")
            return nil
        }

        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n") {
            if line.hasPrefix("p"), let pid = pid_t(line.dropFirst()) {
                return pid
            }
        }

        return nil
    }

    static func matchSession(pid: pid_t, sessions: [String: SessionSnapshot]) -> String? {
        for (sessionId, session) in sessions {
            if session.cliPid == pid { return sessionId }
        }

        var current = pid
        for _ in 0..<5 {
            guard let ppid = parentPid(of: current), ppid > 1 else { break }
            for (sessionId, session) in sessions {
                if session.cliPid == ppid { return sessionId }
            }
            current = ppid
        }

        return nil
    }

    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        let ppid = pid_t(info.pbi_ppid)
        return ppid > 0 ? ppid : nil
    }
}
