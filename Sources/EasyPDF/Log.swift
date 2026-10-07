import os

/// Unified-log channels; read with
/// `log show --last 10m --predicate 'subsystem == "com.stolledev.pdfspdfspdfs"'`.
enum Log {
    static let ui = Logger(subsystem: "com.stolledev.pdfspdfspdfs", category: "ui")
}
