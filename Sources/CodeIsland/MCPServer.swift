import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "MCPServer")

// MARK: - MCP Approval Request

enum MCPRequestKind {
    case access
    case delete
}

struct MCPApprovalRequest {
    let id: String
    let serverName: String
    let serverHost: String
    let serverPort: UInt16
    let sessionId: String?
    let kind: MCPRequestKind
    let continuation: CheckedContinuation<Bool, Never>
    let timestamp: Date = Date()
}

// MARK: - MCP Session (stateful per MCP-Session-Id)

private final class MCPSession {
    let id: String
    var peerPort: UInt16?

    init(id: String, peerPort: UInt16? = nil) {
        self.id = id
        self.peerPort = peerPort
    }
}

// MARK: - MCPServer (Streamable HTTP transport — spec 2025-03-26)

@MainActor
class MCPServer {
    private let appState: AppState
    private var listener: NWListener?
    private var sessions: [String: MCPSession] = [:]
    private(set) var isRunning = false
    let port: UInt16
    private static let protocolVersion = "2025-03-26"
    private static let endpointPath = "/mcp"

    init(appState: AppState, port: UInt16 = 9800) {
        self.appState = appState
        self.port = port
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        do {
            listener = try NWListener(using: params)
        } catch {
            log.error("Failed to create MCP listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.handleConnection(conn)
            }
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log.info("MCPServer listening on 127.0.0.1:\(self.port)\(Self.endpointPath) (Streamable HTTP)")
            case .failed(let error):
                log.error("MCPServer failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
        isRunning = true
    }

    func stop() {
        sessions.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveHTTP(connection: connection, accumulated: Data())
    }

    private func receiveHTTP(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                var data = accumulated
                if let content { data.append(content) }

                if data.count > 1_048_576 {
                    connection.cancel()
                    return
                }

                if self.hasCompleteHTTPRequest(data) {
                    self.routeHTTP(data: data, connection: connection)
                } else if isComplete || error != nil {
                    self.routeHTTP(data: data, connection: connection)
                } else {
                    self.receiveHTTP(connection: connection, accumulated: data)
                }
            }
        }
    }

    private func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8) else { return false }
        guard let headerEnd = str.range(of: "\r\n\r\n") else { return false }
        let headers = str[..<headerEnd.lowerBound]
        if let cl = headers.range(of: "Content-Length: ", options: .caseInsensitive) {
            let rest = headers[cl.upperBound...]
            if let end = rest.firstIndex(of: "\r") ?? rest.firstIndex(of: "\n"),
               let length = Int(rest[..<end]) {
                let bodyStart = str.distance(from: str.startIndex, to: headerEnd.upperBound)
                return data.count >= bodyStart + length
            }
        }
        return true
    }

    // MARK: - HTTP routing

    private func routeHTTP(data: Data, connection: NWConnection) {
        guard let str = String(data: data, encoding: .utf8) else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let lines = str.split(separator: "\r\n", maxSplits: 1)
        guard let requestLine = lines.first else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        if method == "OPTIONS" {
            sendCORSPreflight(connection: connection)
            return
        }

        // Only the single MCP endpoint is supported
        guard path == Self.endpointPath || path.hasPrefix(Self.endpointPath + "?") else {
            sendHTTPResponse(connection: connection, status: 404, body: "Not Found")
            return
        }

        let headers = parseHeaders(from: str)
        let sessionIdHeader = headerValue(headers, name: "mcp-session-id")

        switch method {
        case "POST":
            let body = extractHTTPBody(from: str)
            var peerPort: UInt16?
            if case .hostPort(_, let port) = connection.currentPath?.remoteEndpoint {
                peerPort = port.rawValue
            }
            handlePOST(connection: connection, sessionIdHeader: sessionIdHeader, peerPort: peerPort, body: body)

        case "DELETE":
            if let sid = sessionIdHeader, sessions[sid] != nil {
                sessions.removeValue(forKey: sid)
                log.info("MCP session \(sid) terminated via DELETE")
            }
            sendHTTPResponse(connection: connection, status: 200, body: "")

        case "GET":
            // We don't use server-initiated messages — signal not supported.
            sendHTTPResponse(connection: connection, status: 405, body: "Method Not Allowed")

        default:
            sendHTTPResponse(connection: connection, status: 405, body: "Method Not Allowed")
        }
    }

    // MARK: - POST /mcp (JSON-RPC request)

    private func handlePOST(connection: NWConnection, sessionIdHeader: String?, peerPort: UInt16?, body: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendHTTPResponse(connection: connection, status: 400, body: "Invalid JSON")
            return
        }

        let method = json["method"] as? String ?? ""
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        let isInitialize = method == "initialize"
        let session: MCPSession
        let assignedSessionId: String?

        if isInitialize {
            let newId = UUID().uuidString
            let newSession = MCPSession(id: newId, peerPort: peerPort)
            sessions[newId] = newSession
            session = newSession
            assignedSessionId = newId
            log.info("MCP session \(newId) initialized (peerPort: \(peerPort ?? 0))")
        } else {
            guard let sid = sessionIdHeader, let existing = sessions[sid] else {
                sendHTTPResponse(connection: connection, status: 404, body: "Session not found")
                return
            }
            // Refresh peerPort each call in case the client reconnects on a new ephemeral port
            if let p = peerPort { existing.peerPort = p }
            session = existing
            assignedSessionId = nil
        }

        // Notification (no id) → 202 Accepted, no body
        if id == nil {
            sendHTTPResponse(connection: connection, status: 202, body: "")
            return
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "charon", "version": "1.0.0"]
            ]
            sendJSONRPCResponse(connection: connection, id: id!, result: result, sessionId: assignedSessionId)

        case "tools/list":
            sendJSONRPCResponse(connection: connection, id: id!, result: ["tools": toolsList()], sessionId: nil)

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            handleToolCall(connection: connection, session: session, id: id!, toolName: toolName, args: args)

        case "ping":
            sendJSONRPCResponse(connection: connection, id: id!, result: [:] as [String: Any], sessionId: nil)

        default:
            sendJSONRPCError(connection: connection, id: id!, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - MCP Tools

    private func toolsList() -> [[String: Any]] {
        [
            [
                "name": "list_servers",
                "description": "List all available SSH server names (without sensitive details). Returns server names and notes.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String]
                ] as [String: Any]
            ],
            [
                "name": "request_server_info",
                "description": "Request full SSH connection details for a server. Requires user approval via macOS notification. Returns host, port, username, auth method, jump host info, and ready-to-use SSH command.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "server_name": [
                            "type": "string",
                            "description": "Name of the server to request connection info for"
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["server_name"]
                ] as [String: Any]
            ],
            [
                "name": "save_server",
                "description": "Save or update an SSH server configuration. Creates a new server or updates an existing one by name.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Unique server name (used as identifier)"] as [String: Any],
                        "host": ["type": "string", "description": "Hostname or IP address"] as [String: Any],
                        "port": ["type": "integer", "description": "SSH port (default: 22)"] as [String: Any],
                        "username": ["type": "string", "description": "SSH username"] as [String: Any],
                        "auth_type": ["type": "string", "enum": ["password", "key"], "description": "Authentication method: 'password' or 'key'"] as [String: Any],
                        "password": ["type": "string", "description": "Password (when auth_type is 'password')"] as [String: Any],
                        "key_path": ["type": "string", "description": "Path to private key file (when auth_type is 'key')"] as [String: Any],
                        "jump_host": ["type": "string", "description": "Name of another saved server to use as jump host"] as [String: Any],
                        "note": ["type": "string", "description": "Optional note or description"] as [String: Any],
                        "original_name": ["type": "string", "description": "If renaming, provide the old server name here"] as [String: Any]
                    ] as [String: Any],
                    "required": ["name", "host", "username"]
                ] as [String: Any]
            ],
            [
                "name": "delete_server",
                "description": "Delete a saved SSH server configuration by name.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "server_name": [
                            "type": "string",
                            "description": "Name of the server to delete"
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["server_name"]
                ] as [String: Any]
            ]
        ]
    }

    private func handleToolCall(connection: NWConnection, session: MCPSession, id: Any, toolName: String, args: [String: Any]) {
        switch toolName {
        case "list_servers":
            handleListServers(connection: connection, id: id)

        case "request_server_info":
            let serverName = args["server_name"] as? String ?? ""
            handleRequestServerInfo(connection: connection, session: session, id: id, serverName: serverName)

        case "save_server":
            handleSaveServer(connection: connection, id: id, args: args)

        case "delete_server":
            let serverName = args["server_name"] as? String ?? ""
            handleDeleteServer(connection: connection, session: session, id: id, serverName: serverName)

        default:
            sendJSONRPCError(connection: connection, id: id, code: -32601, message: "Unknown tool: \(toolName)")
        }
    }

    private func handleListServers(connection: NWConnection, id: Any) {
        let servers = ServerStore.loadServers()
        let names = servers.map { ["name": $0.name, "note": $0.note as Any] }
        if let data = try? JSONSerialization.data(withJSONObject: names, options: .prettyPrinted),
           let text = String(data: data, encoding: .utf8) {
            sendToolResult(connection: connection, id: id, text: text)
        } else {
            sendToolResult(connection: connection, id: id, text: "[]")
        }
    }

    private func handleSaveServer(connection: NWConnection, id: Any, args: [String: Any]) {
        guard let name = args["name"] as? String, !name.isEmpty,
              let host = args["host"] as? String, !host.isEmpty,
              let username = args["username"] as? String, !username.isEmpty else {
            sendToolResult(connection: connection, id: id, text: "Missing required fields: name, host, username", isError: true)
            return
        }

        let port: UInt16 = (args["port"] as? Int).map { UInt16($0) } ?? 22
        let authTypeRaw = args["auth_type"] as? String ?? "password"
        let authType = AuthType(rawValue: authTypeRaw) ?? .password

        let server = ServerConfig(
            name: name,
            host: host,
            port: port,
            username: username,
            authType: authType,
            password: args["password"] as? String,
            keyPath: args["key_path"] as? String,
            jumpHost: args["jump_host"] as? String,
            note: args["note"] as? String
        )

        let originalName = args["original_name"] as? String
        ServerStore.saveServer(server, originalName: originalName)
        sendToolResult(connection: connection, id: id, text: "Server '\(name)' saved successfully.")
    }

    private func handleDeleteServer(connection: NWConnection, session: MCPSession, id: Any, serverName: String) {
        guard !serverName.isEmpty else {
            sendToolResult(connection: connection, id: id, text: "Missing required field: server_name", isError: true)
            return
        }

        let servers = ServerStore.loadServers()
        guard let server = servers.first(where: { $0.name == serverName }) else {
            sendToolResult(connection: connection, id: id, text: "Server '\(serverName)' not found.", isError: true)
            return
        }

        let matchedSessionId: String?
        if let peerPort = session.peerPort {
            let pid = PIDResolver.pidForLocalPort(peerPort)
            matchedSessionId = pid.flatMap { PIDResolver.matchSession(pid: $0, sessions: appState.sessions) }
        } else {
            matchedSessionId = nil
        }

        let requestId = String(UUID().uuidString.prefix(8))

        Task {
            let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let request = MCPApprovalRequest(
                    id: requestId,
                    serverName: serverName,
                    serverHost: server.host,
                    serverPort: server.port,
                    sessionId: matchedSessionId,
                    kind: .delete,
                    continuation: continuation
                )
                appState.handleMCPRequest(request)
            }

            if approved {
                ServerStore.deleteServer(name: serverName)
                self.sendToolResult(connection: connection, id: id, text: "Server '\(serverName)' deleted.")
            } else {
                self.sendToolResult(connection: connection, id: id, text: "Delete request denied by user.", isError: true)
            }
        }
    }

    private func handleRequestServerInfo(connection: NWConnection, session: MCPSession, id: Any, serverName: String) {
        let servers = ServerStore.loadServers()
        guard let server = servers.first(where: { $0.name == serverName }) else {
            sendToolResult(connection: connection, id: id, text: "Server '\(serverName)' not found. Use list_servers to see available servers.", isError: true)
            return
        }

        // Resolve session via PID
        let matchedSessionId: String?
        if let peerPort = session.peerPort {
            let pid = PIDResolver.pidForLocalPort(peerPort)
            matchedSessionId = pid.flatMap { PIDResolver.matchSession(pid: $0, sessions: appState.sessions) }
        } else {
            matchedSessionId = nil
        }

        let requestId = String(UUID().uuidString.prefix(8))

        Task {
            let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let request = MCPApprovalRequest(
                    id: requestId,
                    serverName: serverName,
                    serverHost: server.host,
                    serverPort: server.port,
                    sessionId: matchedSessionId,
                    kind: .access,
                    continuation: continuation
                )
                appState.handleMCPRequest(request)
            }

            if approved {
                let info = server.toResponseJSON(servers: servers)
                if let data = try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted),
                   let text = String(data: data, encoding: .utf8) {
                    self.sendToolResult(connection: connection, id: id, text: text)
                } else {
                    self.sendToolResult(connection: connection, id: id, text: "Error serializing server info", isError: true)
                }
            } else {
                self.sendToolResult(connection: connection, id: id, text: "Request denied by user", isError: true)
            }
        }
    }

    // MARK: - JSON-RPC response helpers (send full HTTP response + close)

    private func sendJSONRPCResponse(connection: NWConnection, id: Any, result: Any, sessionId: String?) {
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        sendJSONResponse(connection: connection, status: 200, payload: response, sessionId: sessionId)
    }

    private func sendJSONRPCError(connection: NWConnection, id: Any, code: Int, message: String) {
        let response: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": code, "message": message]
        ]
        sendJSONResponse(connection: connection, status: 200, payload: response, sessionId: nil)
    }

    private func sendToolResult(connection: NWConnection, id: Any, text: String, isError: Bool = false) {
        var result: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { result["isError"] = true }
        sendJSONRPCResponse(connection: connection, id: id, result: result, sessionId: nil)
    }

    // MARK: - HTTP helpers

    private func sendJSONResponse(connection: NWConnection, status: Int, payload: [String: Any], sessionId: String?) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else {
            sendHTTPResponse(connection: connection, status: 500, body: "Serialization failed")
            return
        }

        var lines = [
            "HTTP/1.1 \(status) \(statusText(status))",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS",
            "Access-Control-Allow-Headers: *",
            "Access-Control-Expose-Headers: Mcp-Session-Id",
            "Connection: close"
        ]
        if let sessionId {
            lines.append("Mcp-Session-Id: \(sessionId)")
        }
        lines.append("")
        lines.append(body)

        let response = lines.joined(separator: "\r\n")
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendHTTPResponse(connection: NWConnection, status: Int, body: String) {
        let response = [
            "HTTP/1.1 \(status) \(statusText(status))",
            "Content-Type: text/plain",
            "Content-Length: \(body.utf8.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS",
            "Access-Control-Allow-Headers: *",
            "Connection: close",
            "",
            body
        ].joined(separator: "\r\n")

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendCORSPreflight(connection: NWConnection) {
        let response = [
            "HTTP/1.1 204 No Content",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS",
            "Access-Control-Allow-Headers: *",
            "Access-Control-Max-Age: 86400",
            "Content-Length: 0",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }

    private func extractHTTPBody(from request: String) -> String {
        guard let range = request.range(of: "\r\n\r\n") else { return "" }
        return String(request[range.upperBound...])
    }

    private func parseHeaders(from request: String) -> [(String, String)] {
        guard let headerEnd = request.range(of: "\r\n\r\n") else { return [] }
        let headerBlock = request[..<headerEnd.lowerBound]
        let lines = headerBlock.split(separator: "\r\n").dropFirst()
        var result: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result.append((name, value))
        }
        return result
    }

    private func headerValue(_ headers: [(String, String)], name: String) -> String? {
        let lower = name.lowercased()
        return headers.first(where: { $0.0.lowercased() == lower })?.1
    }
}
