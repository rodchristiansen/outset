//
//  LogSessionStore.swift
//  Managed State Keeper
//
//  Lists outset's runs under /Library/Managed State/logs. Each run is a session
//  directory, YYYY-MM-DD/HHMMSS/ (HHMMSS_2 … _9 when two runs start in the same
//  second), holding outset.log beside events.jsonl and session.json. The shared
//  flat outset.log and its rotations at the root predate that layout and are
//  still listed.
//

import Foundation

struct LogSession: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let date: Date?
    let size: Int64

    var displayDate: String {
        guard let date else { return name }
        return LogSessionStore.displayDateFormatter.string(from: date)
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

enum LogSessionStore {
    static let logFileName = "outset.log"

    static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func stampFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// Parses a session stamp, yyyy-MM-dd-HHmmss with a yyyy-MM-dd-HHmm
    /// fallback. A same-second suffix (_2 … _9) is ignored.
    static func parseStamp(_ stamp: String) -> Date? {
        var base = stamp
        if let underscore = stamp.lastIndex(of: "_"),
           stamp[stamp.index(after: underscore)...].allSatisfy(\.isNumber) {
            base = String(stamp[..<underscore])
        }
        return stampFormatter("yyyy-MM-dd-HHmmss").date(from: base)
            ?? stampFormatter("yyyy-MM-dd-HHmm").date(from: base)
    }

    /// Every run under `root`, newest first.
    static func sessions(in root: String, fileManager fm: FileManager = .default) -> [LogSession] {
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var found: [LogSession] = []
        for day in entries {
            let dayPath = (root as NSString).appendingPathComponent(day)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dayPath, isDirectory: &isDirectory), isDirectory.boolValue,
                  let sessions = try? fm.contentsOfDirectory(atPath: dayPath) else { continue }
            for session in sessions {
                let sessionPath = (dayPath as NSString).appendingPathComponent(session)
                guard let files = try? fm.contentsOfDirectory(atPath: sessionPath) else { continue }
                guard let log = files.first(where: { $0 == logFileName })
                    ?? files.sorted().first(where: { $0.hasSuffix(".log") }) else { continue }
                let stamp = "\(day)-\(session)"
                let path = (sessionPath as NSString).appendingPathComponent(log)
                found.append(LogSession(
                    id: stamp,
                    name: stamp,
                    path: path,
                    date: parseStamp(stamp),
                    size: fileSize(path, fm)
                ))
            }
        }

        // Legacy flat logs: outset.log and its rotations (outset.log.1, …), and
        // any other *.log a previous layout left at the root.
        for name in entries where name.hasSuffix(".log") || name.hasPrefix("\(logFileName).") {
            let path = (root as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            found.append(LogSession(
                id: name,
                name: name,
                path: path,
                date: parseStamp(name.replacingOccurrences(of: ".log", with: "")) ?? modified,
                size: fileSize(path, fm)
            ))
        }

        return found.sorted {
            let lhs = $0.date ?? .distantPast
            let rhs = $1.date ?? .distantPast
            return lhs == rhs ? $0.name > $1.name : lhs > rhs
        }
    }

    private static func fileSize(_ path: String, _ fm: FileManager) -> Int64 {
        ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
