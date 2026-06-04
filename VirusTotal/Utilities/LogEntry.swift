//
//  LogEntry.swift
//  VirusTotal
//
//  Created by Jerry on 2024-06-30.
//

import Foundation
import OSLog

// Global log accessor
let log = AppLogger.shared

// MARK: - LogEntry

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let message: String

    init(timestamp: Date, message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

// MARK: - LogLevel

private enum LogLevel: String {
    case verbose  = "VERBOSE"
    case debug    = "DEBUG"
    case info     = "INFO"
    case warning  = "WARNING"
    case error    = "ERROR"
    case critical = "CRITICAL"
    case fault    = "FAULT"

    var consolePrefix: String {
        switch self {
        case .verbose:            "💜 "
        case .debug:              "💚 "
        case .info:               "💙 "
        case .warning:            "💛 "
        case .error, .critical, .fault: "❤️ "
        }
    }

    var logViewPrefix: String {
        switch self {
        case .verbose:            "🟣 "
        case .debug:              "🟢 "
        case .info:               "🔵 "
        case .warning:            "🟡 "
        case .error, .critical, .fault: "🔴 "
        }
    }
}

// MARK: - AppLogger

/// A lightweight, dependency-free logger that writes to three sinks in parallel:
///   1. OSLog (visible in Console.app and Xcode's debug console)
///   2. `LogManager` (in-app log viewer, bounded to 1 000 entries)
///   3. A plain-text log file under ~/Library/Logs/
///
/// All sink writes are dispatched onto a dedicated serial `DispatchQueue` so the
/// call-site thread is never blocked.  The timestamp is captured *before* the
/// dispatch so entries always reflect the true call time even under queue pressure.
///
/// **Thread-safety contract**: every mutable stored property (`fileHandle`,
/// `hasReportedFileSinkFailure`) is accessed exclusively from `queue`.  The three
/// `DateFormatter` instances are likewise only used from `queue` after `init`
/// completes — satisfying the Foundation requirement that a formatter is not used
/// from multiple threads *concurrently*.  The class is marked `@unchecked Sendable`
/// because Swift's concurrency checker cannot verify serial-queue isolation, but the
/// above invariants make it safe in practice.
final class AppLogger: @unchecked Sendable {

    static let shared = AppLogger()

    // MARK: Private state

    private let subsystem = "org.eu.moyuapp.VirusTotal"
    private let category  = "VirusTotal"

    private let queue = DispatchQueue(
        label: "org.eu.moyuapp.VirusTotal.logging",
        qos: .utility
    )

    private let fileManager   = FileManager.default
    private let consoleLogger: Logger

    // Three formatters, one per sink.  Created once in init() and used only from
    // `queue` thereafter — serial dispatch guarantees non-concurrent access.
    private let consoleDateFormatter: DateFormatter
    private let logViewDateFormatter: DateFormatter
    private let fileDateFormatter: DateFormatter

    // Persistent file handle: opened lazily on first write, kept open to avoid
    // per-message open/close overhead.  Closed and set to nil on write failure so
    // the next write attempt re-opens it (handles log rotation or deletion at runtime).
    // nonisolated(unsafe) documents that mutation happens only from `queue`.
    nonisolated(unsafe) private var fileHandle: FileHandle?
    nonisolated(unsafe) private var hasReportedFileSinkFailure = false

    // Resolved once at init time; never mutated afterwards (no isolation needed).
    private let logFileURL: URL?

    private let logFileName = "VirusTotal.log"

    // MARK: Init / deinit

    private init() {
        consoleLogger        = Logger(subsystem: subsystem, category: category)
        consoleDateFormatter = Self.makeDateFormatter(format: "HH:mm:ss.SSS")
        logViewDateFormatter = Self.makeDateFormatter(format: "HH:mm:ss.SSS")
        fileDateFormatter    = Self.makeDateFormatter(format: "yyyy-MM-dd HH:mm:ss.SSS")

        do {
            logFileURL = try Self.resolveLogFileURL(
                fileManager: fileManager,
                logFileName: logFileName
            )
        } catch {
            logFileURL = nil
            // Use os_log directly — `self` is not fully initialised yet so we
            // cannot call instance methods here.
            os_log(
                .error,
                log: OSLog(subsystem: subsystem, category: category),
                "Failed to configure file logging: %{public}@",
                error.localizedDescription
            )
        }
    }

    deinit {
        // Close the file handle synchronously on the queue so an in-flight write
        // can complete before the handle is torn down.
        queue.sync { [weak self] in self?.closeFileHandle() }
    }

    // MARK: Public logging API

    func verbose(
        _ message: @autoclosure () -> Any,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        write(level: .verbose, message: String(describing: message()),
              file: file, function: function, line: line)
    }

    func debug(
        _ message: @autoclosure () -> Any,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        write(level: .debug, message: String(describing: message()),
              file: file, function: function, line: line)
    }

    func info(
        _ message: @autoclosure () -> Any,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        write(level: .info, message: String(describing: message()),
              file: file, function: function, line: line)
    }

    func warning(
        _ message: @autoclosure () -> Any,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        write(level: .warning, message: String(describing: message()),
              file: file, function: function, line: line)
    }

    func error(
        _ message: @autoclosure () -> Any,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        write(level: .error, message: String(describing: message()),
              file: file, function: function, line: line)
    }

    func critical(
        _ message: @autoclosure () -> Any,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        write(level: .critical, message: String(describing: message()),
              file: file, function: function, line: line)
    }

    func fault(
        _ message: @autoclosure () -> Any,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        write(level: .fault, message: String(describing: message()),
              file: file, function: function, line: line)
    }

    // MARK: Core dispatch

    private func write(
        level: LogLevel,
        message: String,
        file: String,
        function: String,
        line: Int
    ) {
        // Capture timestamp and cheap metadata on the call-site thread.
        // This ensures the logged time reflects when the call was *made*,
        // not when the queue eventually executes the block.
        let timestamp        = Date()
        let strippedFunction = stripParams(function)
        let fileName         = fileNameWithoutSuffix(file)

        queue.async { [self] in
            // --- Console (OSLog) ---
            let consoleMessage = formattedMessage(
                timestamp: timestamp,
                formatter: consoleDateFormatter,
                prefix: level.consolePrefix,
                level: level,
                fileName: fileName,
                function: strippedFunction,
                line: line,
                message: message
            )
            writeToConsole(consoleLogger, message: consoleMessage, level: level)

            // --- In-app log viewer (main actor) ---
            let logViewMessage = formattedMessage(
                timestamp: timestamp,
                formatter: logViewDateFormatter,
                prefix: level.logViewPrefix,
                level: level,
                fileName: fileName,
                function: strippedFunction,
                line: line,
                message: message
            )
            Task { @MainActor in
                LogManager.shared.addLog(logViewMessage, timestamp: timestamp)
            }

            // --- File ---
            let fileMessage = formattedMessage(
                timestamp: timestamp,
                formatter: fileDateFormatter,
                prefix: "",
                level: level,
                fileName: fileName,
                function: strippedFunction,
                line: line,
                message: message
            )
            writeToFile(fileMessage)
        }
    }

    // MARK: Formatting

    // swiftlint:disable function_parameter_count
    private func formattedMessage(
        timestamp: Date,
        formatter: DateFormatter,
        prefix: String,
        level: LogLevel,
        fileName: String,
        function: String,
        line: Int,
        message: String
    ) -> String {
        let timeStamp = formatter.string(from: timestamp)
        return "\(timeStamp) \(prefix)\(level.rawValue) \(fileName).\(function):\(line) - \(message)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // swiftlint:enable function_parameter_count

    // MARK: Sink: console

    private func writeToConsole(
        _ logger: Logger,
        message: String,
        level: LogLevel
    ) {
        switch level {
        case .verbose:  logger.trace(    "\(message, privacy: .public)")
        case .debug:    logger.debug(    "\(message, privacy: .public)")
        case .info:     logger.info(     "\(message, privacy: .public)")
        case .warning:  logger.warning(  "\(message, privacy: .public)")
        case .error:    logger.error(    "\(message, privacy: .public)")
        case .critical: logger.critical( "\(message, privacy: .public)")
        case .fault:    logger.fault(    "\(message, privacy: .public)")
        }
    }

    // MARK: Sink: file
    //
    // The file handle is kept open between writes to avoid per-message
    // open/close/seek syscall overhead.  If a write fails (e.g. the file was
    // rotated or deleted externally) the handle is closed and recreated on the
    // next call.
    //
    // seekToEnd() is called only when the handle is first opened.  Subsequent
    // writes append in order without an extra seek because no other process is
    // expected to write to this specific file.

    private func writeToFile(_ message: String) {
        guard let url = logFileURL else { return }
        do {
            let handle = try openOrReuseFileHandle(for: url)
            try handle.write(contentsOf: Data((message + "\n").utf8))
            hasReportedFileSinkFailure = false
        } catch {
            closeFileHandle()
            reportFileSinkFailure(error, url: url)
        }
    }

    /// Returns the existing open handle, or creates and positions a new one.
    private func openOrReuseFileHandle(for url: URL) throws -> FileHandle {
        if let existing = fileHandle {
            return existing
        }

        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()   // Position once at open; writes append from here.
        fileHandle = handle
        return handle
    }

    private func closeFileHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func reportFileSinkFailure(_ error: Error, url: URL) {
        guard !hasReportedFileSinkFailure else { return }
        hasReportedFileSinkFailure = true
        consoleLogger.error(
            "Failed to write log file \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }

    // MARK: Helpers

    private func stripParams(_ function: String) -> String {
        guard let braceIndex = function.firstIndex(of: "(") else { return function }
        return "\(function[..<braceIndex])()"
    }

    private func fileNameWithoutSuffix(_ file: String) -> String {
        URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
    }

    // MARK: Static factories

    /// Resolves (and creates if necessary) the log file URL under ~/Library/Logs/.
    /// Throws on any filesystem error so the caller can log and fall back gracefully.
    private static func resolveLogFileURL(
        fileManager: FileManager,
        logFileName: String
    ) throws -> URL {
        guard let logsDir = fileManager
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent(logFileName)
    }

    /// Returns a configured `DateFormatter`.  Call only from `init()` — formatters
    /// are not thread-safe and must not be shared across concurrent callers.
    private static func makeDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale   = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - LogManager

@MainActor
@Observable
final class LogManager {

    static let shared = LogManager()

    private(set) var logs: [LogEntry] = []

    private init() {}

    func addLog(_ message: String, timestamp: Date) {
        logs.append(LogEntry(timestamp: timestamp, message: message))
        // Cap the buffer to avoid unbounded memory growth.
        if logs.count > 1_000 {
            logs.removeFirst(logs.count - 1_000)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: App lifecycle

    static func configureLogging() {
        log.verbose("App launched")
    }
}
