import Foundation
import os.log
import SQLite3

// MARK: - Models

enum AuthType: String, Codable {
    case password
    case key
}

struct ServerConfig: Codable {
    var name: String
    var host: String
    var port: UInt16 = 22
    var username: String
    var authType: AuthType = .password
    var password: String?
    var keyPath: String?
    var jumpHost: String?
    var note: String?

    func sshCommand(servers: [ServerConfig]) -> String {
        var parts = ["ssh"]

        if let jumpHostName = jumpHost,
           let jump = servers.first(where: { $0.name == jumpHostName }) {
            if jump.authType == .key, let key = jump.keyPath {
                let portFlag = jump.port != 22 ? " -p \(jump.port)" : ""
                parts.append("-o ProxyCommand=\"ssh -i \(key)\(portFlag) -W %h:%p \(jump.username)@\(jump.host)\"")
            } else {
                let hostPort = jump.port != 22 ? "\(jump.host):\(jump.port)" : jump.host
                parts.append("-J \(jump.username)@\(hostPort)")
            }
        }

        if authType == .key, let key = keyPath {
            parts.append("-i \(key)")
        }

        if port != 22 {
            parts.append("-p \(port)")
        }

        parts.append("\(username)@\(host)")
        return parts.joined(separator: " ")
    }

    func toResponseJSON(servers: [ServerConfig]) -> [String: Any] {
        var result: [String: Any] = [
            "host": host,
            "port": port,
            "username": username,
            "auth_type": authType.rawValue,
            "ssh_command": sshCommand(servers: servers)
        ]

        if let pw = password { result["password"] = pw }
        if let kp = keyPath { result["key_path"] = kp }
        if let n = note { result["note"] = n }

        if let jumpHostName = jumpHost,
           let jump = servers.first(where: { $0.name == jumpHostName }) {
            var jumpObj: [String: Any] = [
                "name": jump.name,
                "host": jump.host,
                "port": jump.port,
                "username": jump.username,
                "auth_type": jump.authType.rawValue
            ]
            if let pw = jump.password { jumpObj["password"] = pw }
            if let kp = jump.keyPath { jumpObj["key_path"] = kp }
            result["jump_host"] = jumpObj
        }

        return result
    }
}

// MARK: - ServerStore

enum ServerStore {
    private static let log = Logger(subsystem: "com.codeisland", category: "ServerStore")
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func configDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".charon")
    }

    static func ensureConfigDir() {
        let dir = configDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func openDB() -> OpaquePointer? {
        ensureConfigDir()
        let path = configDir().appendingPathComponent("charon.db").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            log.error("Failed to open database at \(path)")
            return nil
        }
        createTableIfNeeded(db: db)
        return db
    }

    private static func createTableIfNeeded(db: OpaquePointer?) {
        let sql = """
        CREATE TABLE IF NOT EXISTS servers (
            name      TEXT PRIMARY KEY,
            host      TEXT NOT NULL,
            port      INTEGER NOT NULL DEFAULT 22,
            username  TEXT NOT NULL,
            auth_type TEXT NOT NULL DEFAULT 'password',
            password  TEXT,
            key_path  TEXT,
            jump_host TEXT,
            note      TEXT
        )
        """
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            log.error("Failed to create table: \(msg)")
            sqlite3_free(err)
        }
    }

    static func loadServers() -> [ServerConfig] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }

        let sql = "SELECT name, host, port, username, auth_type, password, key_path, jump_host, note FROM servers ORDER BY name"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("Failed to prepare SELECT statement")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var servers: [ServerConfig] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let host = String(cString: sqlite3_column_text(stmt, 1))
            let port = UInt16(sqlite3_column_int(stmt, 2))
            let username = String(cString: sqlite3_column_text(stmt, 3))
            let authTypeRaw = String(cString: sqlite3_column_text(stmt, 4))
            let authType = AuthType(rawValue: authTypeRaw) ?? .password

            let password = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let keyPath = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let jumpHost = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let note = sqlite3_column_text(stmt, 8).map { String(cString: $0) }

            servers.append(ServerConfig(
                name: name,
                host: host,
                port: port,
                username: username,
                authType: authType,
                password: password,
                keyPath: keyPath,
                jumpHost: jumpHost,
                note: note
            ))
        }
        return servers
    }

    static func saveServer(_ server: ServerConfig, originalName: String? = nil) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        if let old = originalName, old != server.name {
            let del = "DELETE FROM servers WHERE name = ?"
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, del, -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delStmt, 1, old, -1, SQLITE_TRANSIENT)
                sqlite3_step(delStmt)
                sqlite3_finalize(delStmt)
            }
        }

        let sql = """
        INSERT OR REPLACE INTO servers (name, host, port, username, auth_type, password, key_path, jump_host, note)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("Failed to prepare INSERT statement")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, server.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, server.host, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(server.port))
        sqlite3_bind_text(stmt, 4, server.username, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, server.authType.rawValue, -1, SQLITE_TRANSIENT)

        if let pw = server.password {
            sqlite3_bind_text(stmt, 6, pw, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        if let kp = server.keyPath {
            sqlite3_bind_text(stmt, 7, kp, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        if let jh = server.jumpHost {
            sqlite3_bind_text(stmt, 8, jh, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        if let n = server.note {
            sqlite3_bind_text(stmt, 9, n, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            log.error("Failed to save server: \(server.name)")
        }
    }

    static func deleteServer(name: String) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        let sql = "DELETE FROM servers WHERE name = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("Failed to prepare DELETE statement")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            log.error("Failed to delete server: \(name)")
        }
    }
}
