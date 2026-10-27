//
//  HTTPClient.swift
//  RoomyFleet
//
//  A small HTTP/1.1 client on POSIX sockets, so the static Linux binary needs no libcurl or
//  FoundationNetworking. Plain `http://` is handled here; `https://` is delegated to the system
//  `curl`, which every host has, so TLS still works without linking a TLS stack.
//

import Foundation
import RoomyCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct HTTPClientResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
}

public enum HTTPClientError: Error, LocalizedError, Equatable {
    case badURL(String)
    case resolve(String)
    case connect(String)
    case io(String)
    case malformed
    case timeout
    case noTLSSupport

    public var errorDescription: String? {
        switch self {
        case .badURL(let u): return "not an http(s) URL: \(u)"
        case .resolve(let h): return "cannot resolve \(h)"
        case .connect(let m): return "cannot connect: \(m)"
        case .io(let m): return "connection error: \(m)"
        case .malformed: return "malformed HTTP response"
        case .timeout: return "timed out"
        case .noTLSSupport: return "https needs `curl` on PATH (not found)"
        }
    }
}

public enum HTTPClient {
    /// Performs one request and returns the whole response. Blocking; callers wrap it in a task.
    public static func request(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil,
                               timeout: TimeInterval = 15) throws -> HTTPClientResponse {
        guard let scheme = url.scheme?.lowercased(), let host = url.host else { throw HTTPClientError.badURL(url.absoluteString) }
        switch scheme {
        case "http": return try socketRequest(method: method, url: url, host: host, headers: headers, body: body, timeout: timeout)
        case "https": return try curlRequest(method: method, url: url, headers: headers, body: body, timeout: timeout)
        default: throw HTTPClientError.badURL(url.absoluteString)
        }
    }

    // MARK: Plain HTTP over a socket

    static func socketRequest(method: String, url: URL, host: String, headers: [String: String], body: Data?, timeout: TimeInterval) throws -> HTTPClientResponse {
        let port = url.port ?? 80
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { throw HTTPClientError.resolve(host) }
        defer { freeaddrinfo(info) }

        var fd: Int32 = -1
        var lastError = "no addresses"
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                #if canImport(Darwin)
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                #endif
                if connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { fd = s; break }
                lastError = String(cString: strerror(errno))
                close(s)
            }
            cursor = ai.pointee.ai_next
        }
        guard fd >= 0 else { throw HTTPClientError.connect(lastError) }
        defer { close(fd) }

        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { path += "?" + q }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\(url.port.map { ":\($0)" } ?? "")\r\nConnection: close\r\nUser-Agent: roomy/\(RoomyCoreInfo.version)\r\nAccept: application/json, text/plain, */*\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        try out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                #if os(Linux)
                let n = send(fd, base + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                #else
                let n = send(fd, base + offset, raw.count - offset, 0)
                #endif
                if n <= 0 { throw HTTPClientError.io(String(cString: strerror(errno))) }
                offset += n
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); if buffer.count > 64 * 1_048_576 { throw HTTPClientError.io("response too large") }; continue }
            if n == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw HTTPClientError.timeout }
            throw HTTPClientError.io(String(cString: strerror(errno)))
        }
        return try parse(buffer)
    }

    static func parse(_ raw: Data) throws -> HTTPClientResponse {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { throw HTTPClientError.malformed }
        let head = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPClientError.malformed }
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { throw HTTPClientError.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(raw[end.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try dechunk(body)
        } else if let len = headers["content-length"].flatMap({ Int($0) }), body.count > len {
            body = body.prefix(len)
        }
        return HTTPClientResponse(status: status, headers: headers, body: body)
    }

    static func dechunk(_ data: Data) throws -> Data {
        var out = Data()
        var i = data.startIndex
        while i < data.endIndex {
            guard let lineEnd = data[i...].range(of: Data("\r\n".utf8)) else { throw HTTPClientError.malformed }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw HTTPClientError.malformed }
            if size == 0 { break }
            let start = lineEnd.upperBound
            let stop = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<stop])
            i = data.index(stop, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }

    // MARK: HTTPS via curl

    static func curlRequest(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) throws -> HTTPClientResponse {
        guard let curl = ProcessRunner.which("curl") else { throw HTTPClientError.noTLSSupport }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bodyFile = tmp.appendingPathComponent("body"), outFile = tmp.appendingPathComponent("out"), headFile = tmp.appendingPathComponent("head")
        var args = ["-sS", "-X", method, "--max-time", "\(Int(timeout))", "-o", outFile.path, "-D", headFile.path, "-w", "%{http_code}", "-A", "roomy/\(RoomyCoreInfo.version)"]
        for (k, v) in headers { args += ["-H", "\(k): \(v)"] }
        if let body {
            try body.write(to: bodyFile)
            args += ["--data-binary", "@\(bodyFile.path)"]
        }
        args.append(url.absoluteString)
        guard let result = ProcessRunner.run(executable: curl, arguments: args, timeout: timeout + 5) else { throw HTTPClientError.timeout }
        guard result.succeeded, let status = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw HTTPClientError.connect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "curl exited \(result.status)" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var headers: [String: String] = [:]
        if let h = try? String(contentsOf: headFile, encoding: .utf8) {
            for line in h.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return HTTPClientResponse(status: status, headers: headers, body: (try? Data(contentsOf: outFile)) ?? Data())
    }
}
