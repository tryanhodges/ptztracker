import Foundation
import Network

/// Minimal HTTP server for Bitfocus Companion Generic HTTP actions.
final class CompanionHTTPServer {
    enum Action {
        case status
        case on
        case off
        case toggle
    }

    struct Response {
        var status: Int
        var body: String
        var contentType: String = "text/plain"
    }

    private let port: UInt16
    private let handler: @MainActor (Action) -> Response
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ptz.companion.http")

    init(port: UInt16, handler: @escaping @MainActor (Action) -> Response) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                NSLog("Companion HTTP listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("Companion HTTP receive error: \(error)")
                connection.cancel()
                return
            }

            var next = buffer
            if let data { next.append(data) }

            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = next.subdata(in: next.startIndex..<range.lowerBound)
                let requestText = String(data: headerData, encoding: .utf8) ?? ""
                self.respond(to: requestText, on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, buffer: next)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]).uppercased() : "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"

        guard method == "GET" || method == "POST" else {
            send(Response(status: 405, body: "Method Not Allowed"), on: connection)
            return
        }

        let action: Action?
        switch normalizedPath(path) {
        case "/", "/status", "/tracking/status":
            action = .status
        case "/tracking/on", "/on":
            action = .on
        case "/tracking/off", "/off":
            action = .off
        case "/tracking/toggle", "/toggle":
            action = .toggle
        default:
            action = nil
        }

        guard let action else {
            let help = """
            PTZ Tracker Companion API
            GET /status
            GET /tracking/on
            GET /tracking/off
            GET /tracking/toggle
            """
            send(Response(status: 404, body: help), on: connection)
            return
        }

        Task { @MainActor in
            let response = self.handler(action)
            self.send(response, on: connection)
        }
    }

    private func normalizedPath(_ path: String) -> String {
        guard let url = URL(string: path) else {
            return path.lowercased()
        }
        let trimmed = url.path.lowercased()
        if trimmed.count > 1, trimmed.hasSuffix("/") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let bodyData = Data(response.body.utf8)
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        let header = """
        HTTP/1.1 \(response.status) \(reason)\r
        Content-Type: \(response.contentType); charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r

        """
        var payload = Data(header.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
