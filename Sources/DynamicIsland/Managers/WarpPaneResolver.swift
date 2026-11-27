import Foundation
import SQLite3

struct WarpPaneMatch: Equatable, Sendable {
    let paneId: Int64
    let tabId: Int64
    let windowDbId: Int64
    let cwd: String
    let tabIndexInWindow: Int
    let tabCountInWindow: Int
    let isActiveTab: Bool
    let isPaneActive: Bool
    let isPaneFocused: Bool
}

/// Warp has no AppleScript dictionary and its URI scheme explicitly refuses to
/// target an existing tab. Its local SQLite state is the only available map
/// from a pane's working directory to the tab index used by `Cmd+1`…`Cmd+9`.
///
/// This is deliberately best-effort: if the database is missing, the cwd is
/// ambiguous, or the tab shortcut cannot be synthesized, the navigator reports
/// a failure instead of raising whichever tab happens to be active.
struct WarpPaneResolver {
    let sqlitePath: String

    init(sqlitePath: String = WarpPaneResolver.defaultSQLitePath) {
        self.sqlitePath = sqlitePath
    }

    static let defaultSQLitePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
    }()

    func resolve(cwd: String) throws -> [WarpPaneMatch] {
        let variants = Self.cwdVariants(cwd)
        guard !variants.isEmpty else { return [] }
        guard FileManager.default.fileExists(atPath: sqlitePath) else {
            throw NSError(domain: "WarpPaneResolver", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "warp.sqlite is missing"])
        }
        return try query(cwdCandidates: Array(variants),
                         caseInsensitive: Self.isCaseInsensitivePath(cwd))
    }

    /// Only a single unambiguous pane may be focused. Warp's window order is
    /// not public, so selecting one of several same-cwd tabs by guess would
    /// violate the "never focus the wrong tab" contract.
    func bestMatch(cwd: String) -> WarpPaneMatch? {
        guard let matches = try? resolve(cwd: cwd), !matches.isEmpty else { return nil }
        // A tab index is only meaningful inside one Warp window. Matching a
        // background window's pane would otherwise press Cmd+N in the front
        // window and focus an unrelated tab.
        guard Set(matches.map(\.windowDbId)).count == 1 else { return nil }
        if matches.count == 1 { return matches[0] }
        let selected = matches.filter { $0.isActiveTab || $0.isPaneFocused }
        return selected.count == 1 ? selected[0] : nil
    }

    static func cwdVariants(_ raw: String) -> Set<String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var variants = Set<String>()
        variants.insert(trimmed)
        variants.insert(trimmed.hasSuffix("/") && trimmed != "/" ? String(trimmed.dropLast()) : trimmed + "/")
        for seed in Array(variants) {
            if seed.hasPrefix("/private/") {
                variants.insert(String(seed.dropFirst("/private".count)))
            } else if seed.hasPrefix("/tmp") || seed.hasPrefix("/var") || seed.hasPrefix("/etc") {
                variants.insert("/private" + seed)
            }
        }
        return variants
    }

    static func isCaseInsensitivePath(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        while !fm.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        if let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
           let supportsCaseSensitive = values.volumeSupportsCaseSensitiveNames {
            return !supportsCaseSensitive
        }
        return true
    }

    static func fileURI(for path: String) -> String {
        var encoded = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "%": encoded.append("%25")
            case "?": encoded.append("%3F")
            case "#": encoded.append("%23")
            case " ": encoded.append("%20")
            default: encoded.unicodeScalars.append(scalar)
            }
        }
        return "file://\(encoded)?mode=ro"
    }

    private func query(cwdCandidates: [String], caseInsensitive: Bool) throws -> [WarpPaneMatch] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(Self.fileURI(for: sqlitePath), &db, flags, nil) == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close_v2(db) }
            throw NSError(domain: "WarpPaneResolver", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot open warp.sqlite"])
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 150)

        let placeholders = cwdCandidates.map { _ in "?" }.joined(separator: ", ")
        let whereClause = caseInsensitive
            ? "tp.cwd IN (\(placeholders)) OR tp.cwd COLLATE NOCASE IN (\(placeholders))"
            : "tp.cwd IN (\(placeholders))"
        let sql = """
        SELECT tp.id, tp.cwd, tp.is_active,
               COALESCE(pl.is_focused, 0) AS focused,
               pn.tab_id, t.window_id, w.active_tab_index,
               (SELECT COUNT(*) FROM tabs t2 WHERE t2.window_id = t.window_id AND t2.id < t.id) AS tab_idx,
               (SELECT COUNT(*) FROM tabs t3 WHERE t3.window_id = t.window_id) AS tab_count
        FROM terminal_panes tp
        LEFT JOIN pane_leaves pl ON tp.id = pl.pane_node_id AND pl.kind = 'terminal'
        LEFT JOIN pane_nodes pn ON tp.id = pn.id
        LEFT JOIN tabs t ON pn.tab_id = t.id
        LEFT JOIN windows w ON t.window_id = w.id
        WHERE \(whereClause)
          AND pn.tab_id IS NOT NULL
          AND t.id IS NOT NULL
          AND w.id IS NOT NULL
        ORDER BY tp.is_active DESC, focused DESC, tp.id DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let query = statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw NSError(domain: "WarpPaneResolver", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "prepare failed: \(message)"])
        }
        defer { sqlite3_finalize(query) }

        for (index, candidate) in cwdCandidates.enumerated() {
            guard bind(candidate, to: query, index: Int32(index + 1)) else {
                throw NSError(domain: "WarpPaneResolver", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "bind failed"])
            }
        }
        if caseInsensitive {
            let offset = cwdCandidates.count
            for (index, candidate) in cwdCandidates.enumerated() {
                guard bind(candidate, to: query, index: Int32(offset + index + 1)) else {
                    throw NSError(domain: "WarpPaneResolver", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: "bind failed"])
                }
            }
        }

        var matches: [WarpPaneMatch] = []
        while sqlite3_step(query) == SQLITE_ROW {
            matches.append(WarpPaneMatch(
                paneId: sqlite3_column_int64(query, 0),
                tabId: sqlite3_column_int64(query, 4),
                windowDbId: sqlite3_column_int64(query, 5),
                cwd: sqlite3_column_text(query, 1).map { String(cString: $0) } ?? "",
                tabIndexInWindow: Int(sqlite3_column_int(query, 7)),
                tabCountInWindow: Int(sqlite3_column_int(query, 8)),
                isActiveTab: sqlite3_column_int(query, 6) == sqlite3_column_int(query, 7),
                isPaneActive: sqlite3_column_int(query, 2) != 0,
                isPaneFocused: sqlite3_column_int(query, 3) != 0
            ))
        }
        return matches
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) -> Bool {
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        return value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, transient) == SQLITE_OK
        }
    }
}
