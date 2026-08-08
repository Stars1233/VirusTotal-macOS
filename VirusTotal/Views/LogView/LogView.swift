//
//  LogView.swift
//  VirusTotal
//
//  Created by Jerry on 2024-06-30.
//

import SwiftUI

// MARK: - Log Level Filter

private enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all      = "All"
    case verbose  = "VERBOSE"
    case debug    = "DEBUG"
    case info     = "INFO"
    case warning  = "WARNING"
    case error    = "ERROR"
    case critical = "CRITICAL"
    case fault    = "FAULT"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .all:       String(localized: "log.level.all")
        case .verbose:   String(localized: "log.level.verbose")
        case .debug:     String(localized: "log.level.debug")
        case .info:      String(localized: "log.level.info")
        case .warning:   String(localized: "log.level.warning")
        case .error:     String(localized: "log.level.error")
        case .critical:  String(localized: "log.level.critical")
        case .fault:     String(localized: "log.level.fault")
        }
    }

    var emoji: String {
        switch self {
        case .all:                       "🗂️"
        case .verbose:                   "🟣"
        case .debug:                     "🟢"
        case .info:                      "🔵"
        case .warning:                   "🟡"
        case .error, .critical, .fault:  "🔴"
        }
    }
}

// MARK: - Time Range Filter

private enum TimeRangeFilter: String, CaseIterable, Identifiable {
    case all      = "All time"
    case last1m   = "Last 1 min"
    case last5m   = "Last 5 min"
    case last15m  = "Last 15 min"
    case last1h   = "Last 1 hour"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .all:     String(localized: "log.time.all")
        case .last1m:  String(localized: "log.time.last_1_min")
        case .last5m:  String(localized: "log.time.last_5_min")
        case .last15m: String(localized: "log.time.last_15_min")
        case .last1h:  String(localized: "log.time.last_1_hour")
        }
    }

    var cutoff: Date? {
        switch self {
        case .all:     nil
        case .last1m:  Date(timeIntervalSinceNow: -60)
        case .last5m:  Date(timeIntervalSinceNow: -300)
        case .last15m: Date(timeIntervalSinceNow: -900)
        case .last1h:  Date(timeIntervalSinceNow: -3600)
        }
    }
}

// MARK: - LogView

struct LogView: View {
    @State private var logManager  = LogManager.shared
    @State private var searchText  = ""
    @State private var levelFilter = LogLevelFilter.all
    @State private var timeFilter  = TimeRangeFilter.all

    var body: some View {
        if logManager.logs.isEmpty && !hasActiveFilter {
            LogEmptyView()
        } else {
            logDisplay
        }
    }

    // MARK: Computed

    private var hasActiveFilter: Bool {
        !searchText.isEmpty || levelFilter != .all || timeFilter != .all
    }

    private var filteredLogs: [LogEntry] {
        logManager.logs.filter { entry in
            // Level
            if levelFilter != .all, !entry.message.contains(levelFilter.rawValue) {
                return false
            }
            // Time range
            if let cutoff = timeFilter.cutoff, entry.timestamp < cutoff {
                return false
            }
            // Free-text
            if !searchText.isEmpty,
               !entry.message.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            return true
        }
    }

    // MARK: Views

    private var logDisplay: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                filterBar
                Divider()
                logList(proxy: proxy)
            }
            .toolbar {
                ToolbarItem {
                    if !logManager.logs.isEmpty {
                        Button(action: clearLogs) {
                            Image(systemName: "trash")
                        }
                        .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            // Free-text search
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("log.searchfield", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            // Level picker
            Picker("log.picker.level", selection: $levelFilter) {
                ForEach(LogLevelFilter.allCases) { level in
                    Text("\(level.emoji) \(level.localizedName)")
                        .tag(level)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 130)

            // Time range picker
            Picker("log.picker.time", selection: $timeFilter) {
                ForEach(TimeRangeFilter.allCases) { range in
                    Text(range.localizedName).tag(range)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 120)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func logList(proxy: ScrollViewProxy) -> some View {
        if filteredLogs.isEmpty {
            ContentUnavailableView.search(text: searchText.isEmpty ? levelFilter.rawValue : searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(filteredLogs) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .font(.body)
                        Text(dateFormatter.string(from: entry.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .id(entry.id)
                    .itemProvider {
                        NSItemProvider(object: entry.message as NSString)
                    }
                }
            }
            .listStyle(.plain)
            .onChange(of: logManager.logs) {
                // Only auto-scroll when no filter is active, so the view
                // doesn't jump unexpectedly mid-search.
                guard !hasActiveFilter, let last = filteredLogs.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: Helpers

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }

    private func clearLogs() {
        logManager.clearLogs()
    }
}
