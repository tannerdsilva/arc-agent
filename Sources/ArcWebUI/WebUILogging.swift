import Logging
import Synchronization

/// Process-wide logging installation for the web UI: every swift-log line goes
/// into the in-app ring buffer instead of stdout, so the Logs panel is the
/// operator view.
///
/// Idempotent: the daemon installs it at boot and a hosted `WebUIHost` may ask
/// again — `LoggingSystem.bootstrap` itself must only ever run once, and the
/// first caller wins.
public enum WebUILogging {

    private static let installed = Mutex(false)

    public static func install() {
        let first = installed.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        guard first else { return }
        LoggingSystem.bootstrap { label in
            WebUILogHandler(label: label)
        }
    }
}