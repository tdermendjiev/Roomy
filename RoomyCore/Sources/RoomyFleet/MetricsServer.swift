//
//  MetricsServer.swift
//  RoomyFleet
//
//  A deliberately tiny HTTP/1.1 server on POSIX sockets: GET /metrics, GET /healthz, GET /report.
//  Single accept loop, one request per connection. Enough for a Prometheus scrape, nothing more.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class MetricsServer: @unchecked Sendable {
    private let lock = NSLock()
    private var metricsText = "# roomy: no run yet\n"
    private var reportJSON = "{}"
    private var healthy = true
    private var socketFD: Int32 = -1
    private var thread: Thread?
    private var stopping = false

    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public func update(metrics: String, reportJSON: String? = nil, healthy: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        metricsText = metrics
        if let r = reportJSON { self.reportJSON = r }
        self.healthy = healthy
    }

    /// Binds and starts serving on a background thread. Throws if the port is taken.
    public func start() throws {
        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if host == "0.0.0.0" || host.isEmpty {
            addr.sin_addr.s_addr = INADDR_ANY
        } else if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            close(fd)
            throw ServerError.badAddress(host)
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { let e = errno; close(fd); throw ServerError.bind(e) }
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw ServerError.listen(e) }
        socketFD = fd

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "roomy-metrics-server"
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
            handle(client: client)
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = recv(client, &buffer, buffer.count, 0)
        guard n > 0 else { return }
        let request = String(decoding: buffer[0..<Int(n)], as: UTF8.self)
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]).split(separator: "?").first.map(String.init) ?? "/" : "/"

        let (status, contentType, body): (String, String, String)
        lock.lock()
        switch (method, path) {
        case ("GET", "/metrics"), ("GET", "/"):
            (status, contentType, body) = ("200 OK", "text/plain; version=0.0.4; charset=utf-8", metricsText)
        case ("GET", "/healthz"):
            (status, contentType, body) = healthy ? ("200 OK", "text/plain", "ok\n") : ("503 Service Unavailable", "text/plain", "degraded\n")
        case ("GET", "/report"):
            (status, contentType, body) = ("200 OK", "application/json", reportJSON)
        case ("GET", _):
            (status, contentType, body) = ("404 Not Found", "text/plain", "not found\n")
        default:
            (status, contentType, body) = ("405 Method Not Allowed", "text/plain", "method not allowed\n")
        }
        lock.unlock()

        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nServer: roomy\r\n\r\n\(body)"
        response.utf8CString.withUnsafeBufferPointer { ptr in
            var offset = 0
            let total = ptr.count - 1
            while offset < total {
                let sent = send(client, ptr.baseAddress! + offset, total - offset, 0)
                if sent <= 0 { break }
                offset += Int(sent)
            }
        }
    }

    public enum ServerError: Error, LocalizedError {
        case socket(Int32), bind(Int32), listen(Int32), badAddress(String)
        public var errorDescription: String? {
            switch self {
            case .socket(let e): return "socket() failed: \(String(cString: strerror(e)))"
            case .bind(let e): return "bind() failed: \(String(cString: strerror(e)))"
            case .listen(let e): return "listen() failed: \(String(cString: strerror(e)))"
            case .badAddress(let a): return "not an IPv4 address: \(a)"
            }
        }
    }
}
