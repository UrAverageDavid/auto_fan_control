import Foundation
import FanCore

/// Prevent commissioning and the daemon from writing concurrently.
public final class HardwareLock {
    private let descriptor: Int32
    public init() throws {
        descriptor = open("/var/run/local.autofancontrol.hardware.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw FanError.hardware("Cannot obtain hardware lock; root access is required.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw FanError.hardware("Fan helper or another validation process is already running. Unregister the helper before commissioning.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
