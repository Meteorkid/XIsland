import Foundation
import Observation

/// 只保留当前页；页码、查询与错误一起切换，避免用旧数据伪装新查询成功。
@MainActor
@Observable
final class HistoryBrowserState {
    let pageSize: Int
    private(set) var sessions: [HistorySessionRow] = []
    private(set) var totalCount = 0
    private(set) var pageIndex = 0
    private(set) var query = ""
    private(set) var error: String?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private var generation = 0

    var canGoBack: Bool { error == nil && pageIndex > 0 }
    var canGoForward: Bool { error == nil && (pageIndex + 1) * pageSize < totalCount }
    var pageCount: Int { max(1, (totalCount + pageSize - 1) / pageSize) }

    init(pageSize: Int = 100) {
        self.pageSize = max(1, min(pageSize, 1000))
    }

    func search(_ value: String, in manager: SessionPersistenceManager) {
        query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        pageIndex = 0
        reload(from: manager)
    }

    func nextPage(in manager: SessionPersistenceManager) {
        guard canGoForward else { return }
        pageIndex += 1
        reload(from: manager)
    }

    func previousPage(in manager: SessionPersistenceManager) {
        guard canGoBack else { return }
        pageIndex -= 1
        reload(from: manager)
    }

    func reload(from manager: SessionPersistenceManager) {
        do {
            var page = try manager.readHistoryPage(limit: pageSize, offset: pageIndex * pageSize, search: query)
            let lastPage = max(0, (page.totalCount - 1) / pageSize)
            if pageIndex > lastPage {
                pageIndex = lastPage
                page = try manager.readHistoryPage(limit: pageSize, offset: pageIndex * pageSize, search: query)
            }
            sessions = page.sessions.map(HistorySessionRow.init)
            totalCount = page.totalCount
            error = nil
        } catch {
            sessions = []
            totalCount = 0
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }

    func cancel() { generation += 1; isLoading = false }

    func searchAsync(_ value: String, in manager: SessionPersistenceManager) async {
        query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        pageIndex = 0
        await reloadAsync(from: manager)
    }

    func nextPageAsync(in manager: SessionPersistenceManager) async {
        guard canGoForward, !isLoading else { return }
        pageIndex += 1
        await reloadAsync(from: manager)
    }

    func previousPageAsync(in manager: SessionPersistenceManager) async {
        guard canGoBack, !isLoading else { return }
        pageIndex -= 1
        await reloadAsync(from: manager)
    }

    func reloadAsync(from manager: SessionPersistenceManager) async {
        generation += 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            var page = try await manager.readHistoryPageAsync(limit: pageSize, offset: pageIndex * pageSize, search: query)
            let lastPage = max(0, (page.totalCount - 1) / pageSize)
            guard !Task.isCancelled, current == generation else { return }
            if pageIndex > lastPage {
                pageIndex = lastPage
                page = try await manager.readHistoryPageAsync(limit: pageSize, offset: pageIndex * pageSize, search: query)
            }
            guard !Task.isCancelled, current == generation else { return }
            sessions = page.sessions
            totalCount = page.totalCount
            error = nil
            hasLoaded = true
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, current == generation else { return }
            sessions = []; totalCount = 0
            self.error = error.localizedDescription
            hasLoaded = true
        }
    }
}
