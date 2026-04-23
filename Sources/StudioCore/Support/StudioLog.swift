import Foundation
import OSLog

public enum StudioLog {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.albertsteenstrup.sqlite-graph-studio"

    public static let db = Logger(subsystem: subsystem, category: "db")
    public static let graph = Logger(subsystem: subsystem, category: "graph")
    public static let ui = Logger(subsystem: subsystem, category: "ui")

    public static let dbSignposter = OSSignposter(subsystem: subsystem, category: "db")
    public static let graphSignposter = OSSignposter(subsystem: subsystem, category: "graph")
}

extension Duration {
    var milliseconds: Double {
        let secondsMS = Double(components.seconds) * 1_000
        let attosecondsMS = Double(components.attoseconds) / 1_000_000_000_000_000
        return secondsMS + attosecondsMS
    }
}
