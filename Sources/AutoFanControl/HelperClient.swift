import Foundation
import FanCore
import FanIPC

@MainActor final class HelperClient {
    private var connection: NSXPCConnection?
    var disconnected: (() -> Void)?
    func connect() throws {
        guard connection == nil else { return }
        guard let team = HelperConstants.teamID() else {
            throw FanError.unavailable("This build is ad-hoc signed. Build with an Apple-issued signing identity to enable the privileged helper.")
        }
        let connection = NSXPCConnection(machServiceName: HelperConstants.service, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.setCodeSigningRequirement(HelperConstants.requirement(identifier: HelperConstants.service, team: team))
        connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil; self?.disconnected?() } }
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.disconnect(); self?.disconnected?() } }
        self.connection = connection; connection.resume()
    }
    func disconnect() {
        let old = connection; connection = nil
        old?.invalidationHandler = nil; old?.interruptionHandler = nil; old?.invalidate()
    }
    private func call<T: Decodable>(_ send: (FanHelperProtocol, @escaping (Data?, String?) -> Void) -> Void) async throws -> T {
        try connect()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = ReplyOnce<T>(continuation)
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in reply.finish(nil, error.localizedDescription) }) as? FanHelperProtocol else {
                reply.finish(nil, "Helper connection unavailable."); return
            }
            reply.armTimeout()
            send(proxy) { data, error in reply.finish(data, error) }
        }
    }
    func capabilities() async throws -> Capabilities { try await call { $0.capabilities(reply: $1) } }
    func update(_ request: SessionRequest) async throws -> ControlStatus {
        let data = try JSONEncoder().encode(request)
        return try await call { $0.startOrUpdate(data, reply: $1) }
    }
    func restore() async throws -> ControlStatus { try await call { $0.restoreAutomatic(reply: $1) } }
}
private final class ReplyOnce<T: Decodable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var timeout: DispatchWorkItem?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func armTimeout() {
        lock.lock(); defer { lock.unlock() }
        guard continuation != nil else { return }
        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil, "The helper did not respond within three seconds.") }
        self.timeout = timeout; DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
    }
    func finish(_ data: Data?, _ error: String?) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil; timeout?.cancel(); timeout = nil; lock.unlock()
        if let error { continuation.resume(throwing: FanError.unavailable(error)) }
        else if let data {
            do { continuation.resume(returning: try JSONDecoder().decode(T.self, from: data)) }
            catch { continuation.resume(throwing: error) }
        } else { continuation.resume(throwing: FanError.unavailable("Empty helper response.")) }
    }
}
