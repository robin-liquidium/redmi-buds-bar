import Foundation
import OSLog

/// Local, bounded diagnostics, shared with the controls extension for USB retrieval.
/// Command payloads are deliberately omitted: authentication data must not enter logs.
@MainActor
enum BudsDiagnostics {
    private static let session = UUID().uuidString
    private static let logger = Logger(subsystem: "build.robin.RedmiBuds", category: "Diagnostics")
    private static let file: URL? = {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.build.robin.RedmiBuds") else { return nil }
        let directory = group.appendingPathComponent("Library/Diagnostics", isDirectory: true)
        do {
            let initialDirectory = group.appendingPathComponent("Diagnostics", isDirectory: true)
            if FileManager.default.fileExists(atPath: initialDirectory.path), !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: initialDirectory, to: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let role = Bundle.main.bundleIdentifier?.hasSuffix(".Controls") == true ? "controls" : "app"
            return directory.appendingPathComponent("\(role).jsonl")
        } catch {
            logger.error("Cannot create diagnostics directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func record(_ event: String, _ details: [String: String] = [:]) {
        guard let file else { return }
        var entry = details
        entry["event"] = event
        entry["time"] = Date().ISO8601Format()
        entry["session"] = session
        entry["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        entry["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        do {
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: file.path)[.size]) as? NSNumber, size.intValue > 512 * 1024 {
                let previous = file.appendingPathExtension("previous")
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: file, to: previous)
            }
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0a)
            if !manager.fileExists(atPath: file.path) {
                try data.write(to: file, options: [.atomic])
                try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            } else {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch {
            logger.error("Cannot save diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }
}
