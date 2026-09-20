import Darwin
import Foundation

/// A one-shot Unix domain socket server: bind + listen, then block in
/// `acceptOnce()` for a single incoming connection. Used to receive the raw
/// H.264 stream from the bundled AirPlay receiver helper process, which
/// connects to us as a client.
final class UnixSocketListener {
    enum ListenerError: Error {
        case createFailed
        case bindFailed(Int32)
        case listenFailed(Int32)
        case acceptFailed(Int32)
        case pathTooLong
    }

    private var fd: Int32 = -1
    let path: String

    init(path: String) {
        self.path = path
    }

    func start() throws {
        unlink(path) // remove a stale socket file from a previous run

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw ListenerError.createFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < sunPathSize else {
            Darwin.close(s)
            throw ListenerError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { cptr in
                for (i, byte) in pathBytes.enumerated() {
                    cptr[i] = CChar(bitPattern: byte)
                }
                cptr[pathBytes.count] = 0
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(s, sa, addrLen)
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(s)
            throw ListenerError.bindFailed(err)
        }

        guard listen(s, 1) == 0 else {
            let err = errno
            Darwin.close(s)
            throw ListenerError.listenFailed(err)
        }

        self.fd = s
    }

    /// Blocks until one client connects, then returns a socket wrapping it.
    func acceptOnce() throws -> TCPSocket {
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else { throw ListenerError.acceptFailed(errno) }
        return TCPSocket(existingFD: clientFD)
    }

    func stop() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        unlink(path)
    }

    deinit {
        stop()
    }
}
