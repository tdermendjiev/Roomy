//
//  HTTPServer.swift
//  RoomyFleet
//
//  A small HTTP/1.1 server on POSIX sockets for the hub: parses method, path, query, headers
//  and a bounded body, hands the request to one handler, writes one response, closes. No TLS;
//  put it behind your reverse proxy or on a private network, like node_exporter.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names lower-cased.
    public var headers: [String: String]
    public var body: Data

    public var bearerToken: String? {
        if let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return query["token"]
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func text(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(s.utf8))
    }

    public static func html(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(s.utf8))
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200, pretty: Bool = false) -> HTTPResponse {
        let data = (try? (pretty ? HubJSON.prettyEncoder : HubJSON.encoder).encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    public static func error(_ message: String, status: Int) -> HTTPResponse {
        json(["error": message, "status": "\(status)"], status: status)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"; case 201: return "Created"; case 204: return "No Content"
        case 400: return "Bad Request"; case 401: return "Unauthorized"; case 402: return "Payment Required"; case 403: return "Forbidden"
        case 404: return "Not Found"; case 405: return "Method Not Allowed"; case 409: return "Conflict"; case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"; case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"; case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse

    public let host: String
    public private(set) var port: UInt16
    public var maxBodyBytes = 8 * 1_048_576
    private let handler: Handler
    private var socketFD: Int32 = -1
    private var thread: Thread?
    private let lock = NSLock()
    private var stopping = false
    private let workers = DispatchQueue(label: "roomy-hub-http", attributes: .concurrent)

    public init(host: String, port: UInt16, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.handler = handler
    }

    /// Binds and serves on a background thread. With port 0 the kernel picks one; read `port` afterwards.
    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw MetricsServer.ServerError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if host == "0.0.0.0" || host.isEmpty {
            addr.sin_addr.s_addr = INADDR_ANY
        } else if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            close(fd)
            throw MetricsServer.ServerError.badAddress(host)
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw MetricsServer.ServerError.bind(e) }
        guard listen(fd, 64) == 0 else { let e = errno; close(fd); throw MetricsServer.ServerError.listen(e) }
        if port == 0 {
            var actual = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            port = UInt16(bigEndian: actual.sin_port)
        }
        socketFD = fd
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "roomy-hub-accept"
        t.start()
        thread = t
    }

    public func stop() {
        lock.lock(); stopping = true; lock.unlock()
        if socketFD >= 0 { shutdown(socketFD, Int32(SHUT_RDWR)); close(socketFD); socketFD = -1 }
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let stop = stopping; lock.unlock()
            if stop { return }
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(socketFD, $0, &len) }
            }
            if client < 0 { if errno == EINTR { continue } else { return } }
            workers.async { [weak self] in self?.handle(client: client) }
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let request = readRequest(client) else { return }
        let response = handler(request)
        write(response, to: client, headOnly: request.method == "HEAD")
    }

    private func readRequest(_ client: Int32) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = recv(client, &chunk, chunk.count, 0)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<Int(n)])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if buffer.count > 64 * 1024, headerEnd == nil { return nil }
        }
        guard let end = headerEnd else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= maxBodyBytes else {
            write(.error("body too large", status: 413), to: client, headOnly: false)
            return nil
        }
        var body = Data(buffer[end.upperBound...])
        while body.count < contentLength {
            let n = recv(client, &chunk, min(chunk.count, contentLength - body.count), 0)
            guard n > 0 else { return nil }
            body.append(contentsOf: chunk[0..<Int(n)])
        }
        if body.count > contentLength { body = body.prefix(contentLength) }

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[k] = v
            }
        }
        path = path.removingPercentEncoding ?? path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func write(_ response: HTTPResponse, to client: Int32, headOnly: Bool) {
        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Server"] = "roomy-hub"
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if !headOnly { out.append(response.body) }
        out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let sent = send(client, base + offset, raw.count - offset, 0)
                if sent <= 0 { break }
                offset += Int(sent)
            }
        }
    }
}
