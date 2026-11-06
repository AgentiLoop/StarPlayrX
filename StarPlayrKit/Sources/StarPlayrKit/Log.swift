//
//  Log.swift
//  StarPlayrKit
//

import os

/// A Logger that also prints: OS_ACTIVITY_MODE=disable in the schemes hides Logger output in
/// Xcode's console, print still shows. Console.app keeps getting every line.
public struct Log {
    private let logger: Logger

    public init(subsystem: String, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func log(_ line: String) { print(line); logger.log("\(line, privacy: .public)") }
    public func info(_ line: String) { print(line); logger.info("\(line, privacy: .public)") }
    public func notice(_ line: String) { print(line); logger.notice("\(line, privacy: .public)") }
    public func error(_ line: String) { print(line); logger.error("\(line, privacy: .public)") }
}
