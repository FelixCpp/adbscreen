import Darwin
import Foundation

/// Minimal blocking TCP client over loopback, used to talk to the scrcpy
/// server through an `adb forward` tunnel. Intended to be driven from a
/// dedicated background thread (one per socket).
final class TCPSocket {
    private var fd: Int32 = -1

    enum SocketError: Error {
        case createFailed
        case connectFailed(Int32)
        case closed
    }

    init() {}

    /// Wraps an already-connected/accepted file descriptor (e.g. from
    /// `accept()` on a Unix domain socket listener) instead of dialing out.
    init(existingFD: Int32) {
        self.fd = existingFD
    }

    func connect(host: String = "127.0.0.1", port: UInt16, timeout: TimeInterval) throws {
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { throw SocketError.createFailed }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(s)
            throw SocketError.connectFailed(errno)
        }

        var one: Int32 = 1
        setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        self.fd = s
    }

    func readExact(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                recv(fd, raw.baseAddress!.advanced(by: received), count - received, 0)
            }
            if n <= 0 {
                throw SocketError.closed
            }
            received += n
        }
        return buf
    }

    func write(_ data: [UInt8]) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            while sent < data.count {
                let n = send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    throw SocketError.closed
                }
                sent += n
            }
        }
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit {
        close()
    }
}
