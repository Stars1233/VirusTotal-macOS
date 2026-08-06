//
//  DropInfo.swift
//  VirusTotal
//
//  Created by Jerry on 2024-06-05.
//

import SwiftUI
import UniformTypeIdentifiers

extension DropInfo {
    /// Return true if the drop contains at least one file URL.
    @MainActor
    func hasFileURLs() -> Bool {
        !itemProviders(for: [.fileURL]).isEmpty
    }
}

extension NSItemProvider {
    @MainActor
    func fileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?

                if let fileURL = item as? URL, fileURL.isFileURL {
                    url = fileURL
                } else if let data = item as? Data, let fileURL = URL(dataRepresentation: data, relativeTo: nil), fileURL.isFileURL {
                    url = fileURL
                } else if let string = item as? String, let fileURL = URL(string: string), fileURL.isFileURL {
                    url = fileURL
                } else {
                    url = nil
                }

                continuation.resume(returning: url?.resolvingSymlinksInPath())
            }
        }
    }
}
