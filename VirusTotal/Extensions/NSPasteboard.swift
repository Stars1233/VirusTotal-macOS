//
//  NSPasteboard.swift
//  VirusTotal
//
//  Created by Jerry on 2024-06-05.
//

import Cocoa

extension NSPasteboard {
    /// Get the file URLs from dragged and dropped files.
    func fileURLs() -> [URL] {
        let options: [ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        // Finder and Dock file drags can fail the content-type filter even when they are valid files.
        // Keep the source restricted to file URLs and let callers validate the resulting URLs.

        guard let urls = readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return []
        }

        return urls
    }
}
