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

// MARK: - SSE Session

private final class SSESession {
    let id: String
    let connection: NWConnection
    var peerPort: UInt16?

    init(id: String, connection: NWConnection, peerPort: UInt16? = nil) {
        self.id = id
        self.connection = connection
        self.peerPort = peerPort
    }

    func send(event: String, data: String) {
        let payload = "event: \(event)\ndata: \(data)\n\n"
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { error in
            if let error { log.error("SSE send failed: \(error)") }
        })
    }

    func sendKeepAlive() {
        let payload = Data(":\n\n".utf8)
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }
}

// MARK: - MCPServer

@MainActor
class MCPServer {
    private let appState: AppState
    private var listener: NWListener?
    private var sessions: [String: SSESession] = [:]
    private var keepAliveTimer: Timer?
    private(set) var isRunning = false
    let port: UInt16

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
                log.info("MCPServer listening on 127.0.0.1:\(self.port)")
            case .failed(let error):
                log.error("MCPServer failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
        isRunning = true

        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendKeepAlives()
            }
        }
    }

    func stop() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        for session in sessions.values {
            session.connection.cancel()
        }
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

        if method == "GET" && path == "/sse" {
            handleSSE(connection: connection)
        } else if method == "POST" && path.hasPrefix("/messages") {
            let body = extractHTTPBody(from: str)
            let sessionId = extractQueryParam(from: path, key: "sessionId")
            handleMessages(connection: connection, sessionId: sessionId, body: body)
        } else {
            sendHTTPResponse(connection: connection, status: 404, body: "Not Found")
        }
    }

    // MARK: - SSE endpoint

    private func handleSSE(connection: NWConnection) {
        let sessionId = UUID().uuidString

        var peerPort: UInt16?
        if case .hostPort(_, let port) = connection.currentPath?.remoteEndpoint {
            peerPort = port.rawValue
        }

        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: *",
            "\r\n"
        ].joined(separator: "\r\n")

        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let session = SSESession(id: sessionId, connection: connection, peerPort: peerPort)
                self.sessions[sessionId] = session

                let endpointData = "/messages?sessionId=\(sessionId)"
                session.send(event: "endpoint", data: endpointData)

                self.monitorSSEDisconnect(sessionId: sessionId, connection: connection)
                log.info("SSE session \(sessionId) established (peerPort: \(peerPort ?? 0))")
            }
        })
    }

    private func monitorSSEDisconnect(sessionId: String, connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil || connection.state == .cancelled {
                    self.sessions.removeValue(forKey: sessionId)
                    log.info("SSE session \(sessionId) disconnected")
                } else {
                    self.monitorSSEDisconnect(sessionId: sessionId, connection: connection)
                }
            }
        }
    }

    // MARK: - Messages endpoint

    private func handleMessages(connection: NWConnection, sessionId: String?, body: String) {
        guard let sessionId, let session = sessions[sessionId] else {
            sendHTTPResponse(connection: connection, status: 404, body: "Session not found")
            return
        }

        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendHTTPResponse(connection: connection, status: 400, body: "Invalid JSON")
            return
        }

        let method = json["method"] as? String ?? ""
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        // Notifications (no id) — just acknowledge
        guard id != nil else {
            sendHTTPResponse(connection: connection, status: 202, body: "Accepted")
            return
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "charon", "version": "1.0.0"]
            ]
            sendJSONRPC(session: session, id: id!, result: result)

        case "notifications/initialized":
            break

        case "tools/list":
            sendJSONRPC(session: session, id: id!, result: ["tools": toolsList()])

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            handleToolCall(session: session, id: id!, toolName: toolName, args: args)

        case "ping":
            sendJSONRPC(session: session, id: id!, result: [:] as [String: Any])

        default:
            sendJSONRPCError(session: session, id: id!, code: -32601, message: "Method not found: \(method)")
        }

        sendHTTPResponse(connection: connection, status: 202, body: "Accepted")
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

    private func handleToolCall(session: SSESession, id: Any, toolName: String, args: [String: Any]) {
        switch toolName {
        case "list_servers":
            handleListServers(session: session, id: id)

        case "request_server_info":
            let serverName = args["server_name"] as? String ?? ""
            handleRequestServerInfo(session: session, id: id, serverName: serverName)

        case "save_server":
            handleSaveServer(session: session, id: id, args: args)

        case "delete_server":
            let serverName = args["server_name"] as? String ?? ""
            handleDeleteServer(session: session, id: id, serverName: serverName)

        default:
            sendJSONRPCError(session: session, id: id, code: -32601, message: "Unknown tool: \(toolName)")
        }
    }

    private func handleListServers(session: SSESession, id: Any) {
        let servers = ServerStore.loadServers()
        let names = servers.map { ["name": $0.name, "note": $0.note as Any] }
        if let data = try? JSONSerialization.data(withJSONObject: names, options: .prettyPrinted),
           let text = String(data: data, encoding: .utf8) {
            sendToolResult(session: session, id: id, text: text)
        } else {
            sendToolResult(session: session, id: id, text: "[]")
        }
    }

    private func handleSaveServer(session: SSESession, id: Any, args: [String: Any]) {
        guard let name = args["name"] as? String, !name.isEmpty,
              let host = args["host"] as? String, !host.isEmpty,
              let username = args["username"] as? String, !username.isEmpty else {
            sendToolResult(session: session, id: id, text: "Missing required fields: name, host, username", isError: true)
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
        sendToolResult(session: session, id: id, text: "Server '\(name)' saved successfully.")
    }

    private func handleDeleteServer(session: SSESession, id: Any, serverName: String) {
        guard !serverName.isEmpty else {
            sendToolResult(session: session, id: id, text: "Missing required field: server_name", isError: true)
            return
        }

        let servers = ServerStore.loadServers()
        guard let server = servers.first(where: { $0.name == serverName }) else {
            sendToolResult(session: session, id: id, text: "Server '\(serverName)' not found.", isError: true)
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
                self.sendToolResult(session: session, id: id, text: "Server '\(serverName)' deleted.")
            } else {
                self.sendToolResult(session: session, id: id, text: "Delete request denied by user.", isError: true)
            }
        }
    }

    private func handleRequestServerInfo(session: SSESession, id: Any, serverName: String) {
        let servers = ServerStore.loadServers()
        guard let server = servers.first(where: { $0.name == serverName }) else {
            sendToolResult(session: session, id: id, text: "Server '\(serverName)' not found. Use list_servers to see available servers.", isError: true)
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
                    self.sendToolResult(session: session, id: id, text: text)
                } else {
                    self.sendToolResult(session: session, id: id, text: "Error serializing server info", isError: true)
                }
            } else {
                self.sendToolResult(session: session, id: id, text: "Request denied by user", isError: true)
            }
        }
    }

    // MARK: - JSON-RPC helpers

    private func sendJSONRPC(session: SSESession, id: Any, result: Any) {
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let text = String(data: data, encoding: .utf8) else { return }
        session.send(event: "message", data: text)
    }

    private func sendJSONRPCError(session: SSESession, id: Any, code: Int, message: String) {
        let response: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": code, "message": message]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let text = String(data: data, encoding: .utf8) else { return }
        session.send(event: "message", data: text)
    }

    private func sendToolResult(session: SSESession, id: Any, text: String, isError: Bool = false) {
        var result: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { result["isError"] = true }
        sendJSONRPC(session: session, id: id, result: result)
    }

    // MARK: - HTTP helpers

    private func sendHTTPResponse(connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Unknown"
        }

        let response = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: text/plain",
            "Content-Length: \(body.utf8.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
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
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
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

    private func sendKeepAlives() {
        for session in sessions.values {
            session.sendKeepAlive()
        }
    }

    private func extractHTTPBody(from request: String) -> String {
        guard let range = request.range(of: "\r\n\r\n") else { return "" }
        return String(request[range.upperBound...])
    }

    private func extractQueryParam(from path: String, key: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = path[path.index(after: queryStart)...]
        for param in query.split(separator: "&") {
            let kv = param.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == key {
                return String(kv[1]).removingPercentEncoding
            }
        }
        return nil
    }
}
