import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SearchCoordinator {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selectionWasUserDriven = false
            if query.isEmpty != oldValue.isEmpty {
                let height = panelHeight
                DispatchQueue.main.async { [weak self] in
                    guard self?.panelHeight == height else { return }
                    self?.onPanelHeightChange?(height)
                }
            }
            guard !isResetting else { return }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                refreshApplicationsIfNeeded()
                refreshSettingsIfNeeded()
            }
            scheduleSearch()
        }
    }
    private(set) var results: [SearchItem] = []
    private(set) var selectedFilter: SearchResultFilter = .all
    var selectedID: SearchItem.ID?
    private(set) var isSearching = false
    private(set) var rootURL: URL
    var focusGeneration = 0

    @ObservationIgnored
    var onDismiss: (() -> Void)?
    @ObservationIgnored
    var onPanelHeightChange: ((CGFloat) -> Void)?
    @ObservationIgnored
    var onShowSettings: (() -> Void)?

    var panelHeight: CGFloat {
        FloodlightMetrics.panelHeight(hasQuery: !query.isEmpty)
    }

    var filterOptions: [SearchFilterOption] {
        let primary = SearchResultFilter.primary.map(makeFilterOption)
        let dynamic = SearchResultFilter.dynamic.compactMap { filter -> SearchFilterOption? in
            let option = makeFilterOption(filter)
            guard option.count > 0 || selectedFilter == filter else { return nil }
            return option
        }
        return primary + dynamic
    }

    private let index: FFFIndex
    private let applicationCatalog: ApplicationCatalog
    private let launchAtLoginController = LaunchAtLoginController()
    private let recentStore: RecentStore
    private let quickLook = QuickLookController()
    private var allResults: [SearchItem] = []
    private var filterCounts = SearchFilterCounts()
    private var applicationMatchCount = 0
    private var settingsMatchCount = 0
    private var isApplicationCatalogLoading = true
    private var isSettingsCatalogLoading = true
    @ObservationIgnored
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored
    private var startupTask: Task<Void, Never>?
    @ObservationIgnored
    private var applicationRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var settingsRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var generation = 0
    @ObservationIgnored
    private var isResetting = false
    @ObservationIgnored
    private var selectionWasUserDriven = false

    init() {
        let fileManager = FileManager.default
        let savedRoot = UserDefaults.standard.string(forKey: "index-root")
        let initialRoot = savedRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser
        let fallbackStorage = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Floodlight",
                isDirectory: true
            )
        let indexStorage = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Floodlight", isDirectory: true))
            ?? fallbackStorage
        let environment = ProcessInfo.processInfo.environment
        let recentStore = RecentStore()

        rootURL = initialRoot
        index = FFFIndex(
            rootURL: initialRoot,
            storageURL: indexStorage,
            enableHomeDirectoryScanning: true,
            logFilePath: environment["FLOODLIGHT_FFF_LOG"],
            logLevel: environment["FLOODLIGHT_FFF_LOG_LEVEL"] ?? "info"
        )
        self.recentStore = recentStore
        applicationCatalog = ApplicationCatalog(
            recentStore: recentStore,
            deferDiscovery: true
        )
    }

    deinit {
        searchTask?.cancel()
        startupTask?.cancel()
        applicationRefreshTask?.cancel()
        settingsRefreshTask?.cancel()
    }

    func start() {
        guard startupTask == nil else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            let signpost = FloodlightPerformance.begin("IndexStartup")
            defer {
                FloodlightPerformance.end("IndexStartup", id: signpost)
            }
            do {
                async let startFiles: Void = index.start()
                async let startApplications: Void = applicationCatalog.start()
                async let startSettings: Void = SystemCatalog.start()

                try await startApplications
                isApplicationCatalogLoading = false
                await startSettings
                isSettingsCatalogLoading = false
                try await startFiles
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scheduleSearch(immediate: true)
                }
            } catch is CancellationError {
                return
            } catch {
                isApplicationCatalogLoading = false
                isSettingsCatalogLoading = false
                NSLog("Floodlight index startup failed: %@", error.localizedDescription)
            }
        }
    }

    func prepareForPresentation() {
        focusGeneration += 1
        refreshApplicationsIfNeeded()
        refreshSettingsIfNeeded()
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleSearch(immediate: true)
        }
    }

    private func refreshApplicationsIfNeeded() {
        guard !isApplicationCatalogLoading, applicationRefreshTask == nil else { return }
        applicationRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { applicationRefreshTask = nil }

            do {
                let changed = try await applicationCatalog.refreshIfNeeded()
                guard changed else { return }
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scheduleSearch(immediate: true)
                }
            } catch is CancellationError {
                return
            } catch {
                NSLog("Floodlight application-catalog refresh failed: %@", error.localizedDescription)
            }
        }
    }

    private func refreshSettingsIfNeeded() {
        guard !isSettingsCatalogLoading, settingsRefreshTask == nil else { return }
        settingsRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { settingsRefreshTask = nil }

            let changed = await SystemCatalog.refreshIfNeeded()
            guard changed else { return }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scheduleSearch(immediate: true)
            }
        }
    }

    func reset() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        isResetting = true
        query = ""
        isResetting = false
        allResults = []
        filterCounts = SearchFilterCounts()
        results = []
        selectedFilter = .all
        applicationMatchCount = 0
        settingsMatchCount = 0
        selectedID = nil
        selectionWasUserDriven = false
        isSearching = false
        quickLook.close()
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in results.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), results.count - 1)
        selectedID = results[nextIndex].id
        selectionWasUserDriven = true
    }

    func activate(_ item: SearchItem) {
        select(item)
        performAction(for: item)
    }

    func select(_ item: SearchItem) {
        selectedID = item.id
        selectionWasUserDriven = true
    }

    func selectFilter(_ filter: SearchResultFilter) {
        selectionWasUserDriven = true
        guard filter != selectedFilter else {
            focusGeneration += 1
            return
        }
        selectedFilter = filter
        applySelectedFilter(resetSelection: true)
        focusGeneration += 1
    }

    func openSelection() {
        guard let item = selectedItem else { return }
        performAction(for: item)
    }

    private func performAction(for item: SearchItem) {
        let selectedQuery = query
        onDismiss?()

        switch item.action {
        case .copy(let value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        case .open(let url):
            open(url, asApplication: item.kind == .application)
            if item.kind == .file || item.kind == .folder {
                index.track(query: selectedQuery, selectedURL: url)
            } else if item.kind == .application {
                applicationCatalog.track(query: selectedQuery, selectedURL: url)
            }
        case .showFloodlightSettings:
            onShowSettings?()
        }
        recentStore.record(item.id)
    }

    func revealSelection() {
        guard let url = selectedItem?.fileURL else { return }
        onDismiss?()
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func copySelection() {
        guard let item = selectedItem else { return }
        let value: String
        switch item.action {
        case .copy(let text):
            value = text
        case .open(let url):
            value = url.isFileURL ? url.path : url.absoluteString
        case .showFloodlightSettings:
            value = item.title
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func togglePreview() {
        guard let url = selectedItem?.fileURL, selectedItem?.isPreviewable == true else { return }
        quickLook.toggle(url)
    }

    @discardableResult
    func chooseRoot() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to search"
        panel.message = "Floodlight will search this folder and keep results up to date."
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }
        changeRoot(to: selectedURL)
        return selectedURL
    }

    func rebuildIndex() {
        Task {
            do {
                try await index.rescan()
            } catch {
                NSLog("Floodlight index rebuild failed: %@", error.localizedDescription)
            }
        }
    }

    var launchesAtLogin: Bool {
        launchAtLoginController.isEnabled
    }

    /// Registers the login item on the very first launch only.
    ///
    /// A launcher is only useful once it is already running, so Floodlight opts
    /// in for you. The `launch-at-login-configured` flag makes this a one-time
    /// decision: if you later turn it off — here or in System Settings — the
    /// next launch leaves it off instead of switching it back on.
    func enableLaunchAtLoginOnFirstRun() {
        launchAtLoginController.enableOnFirstRun()
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        try launchAtLoginController.setEnabled(enabled)
    }

    private var selectedItem: SearchItem? {
        guard let selectedID else { return results.first }
        return results.first { $0.id == selectedID }
    }

    private func open(_ url: URL, asApplication: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let signpost = FloodlightPerformance.begin("OpenSelection")

        if asApplication {
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration,
                completionHandler: { _, _ in
                    FloodlightPerformance.end("OpenSelection", id: signpost)
                }
            )
        } else {
            NSWorkspace.shared.open(
                url,
                configuration: configuration,
                completionHandler: { _, _ in
                    FloodlightPerformance.end("OpenSelection", id: signpost)
                }
            )
        }
    }

    private func changeRoot(to url: URL) {
        Task {
            do {
                try await index.changeRoot(to: url)
                rootURL = url.standardizedFileURL
                UserDefaults.standard.set(rootURL.path, forKey: "index-root")
                scheduleSearch(immediate: true)
            } catch {
                NSLog("Floodlight search-scope update failed: %@", error.localizedDescription)
            }
        }
    }

    private func scheduleSearch(immediate: Bool = false) {
        let immediateSignpost = FloodlightPerformance.begin("ImmediateSearch")
        generation += 1
        let requestGeneration = generation
        let requestQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !requestQuery.isEmpty else {
            allResults = []
            filterCounts = SearchFilterCounts()
            results = []
            selectedFilter = .all
            applicationMatchCount = 0
            settingsMatchCount = 0
            selectedID = nil
            isSearching = false
            FloodlightPerformance.end("ImmediateSearch", id: immediateSignpost)
            return
        }

        let immediateAppPage = applicationCatalog.fastSearchPage(requestQuery)
        let settingsPage = SystemCatalog.searchPage(requestQuery, limit: 24)
        let immediateApps = immediateAppPage.items
        applicationMatchCount = immediateAppPage.totalMatched
        settingsMatchCount = settingsPage.totalMatched
        isSearching = true
        publishResults(
            buildResults(
                query: requestQuery,
                indexed: [],
                apps: immediateApps,
                system: settingsPage.items
            ),
            resetSelection: true
        )
        FloodlightPerformance.end("ImmediateSearch", id: immediateSignpost)

        searchTask = Task { [weak self] in
            guard let self else { return }

            if !immediate {
                let debounce = immediateApps.isEmpty ? 35 : 180
                try? await Task.sleep(for: .milliseconds(debounce))
            }
            guard !Task.isCancelled else { return }

            let asyncSignpost = FloodlightPerformance.begin("IndexedSearch")
            var indexedSearchEnded = false
            defer {
                if !indexedSearchEnded {
                    FloodlightPerformance.end("IndexedSearch", id: asyncSignpost)
                }
                if requestGeneration == generation {
                    isSearching = false
                    reconcileSelectedFilter()
                }
            }

            do {
                async let indexed = searchIndexedFiles(requestQuery)
                async let applications = searchIndexedApplications(requestQuery)
                let fffItems = try await indexed
                let apps = try await applications
                guard !Task.isCancelled, requestGeneration == generation else { return }

                let mapped = fffItems.map { $0.makeSearchItem() }

                publishResults(
                    buildResults(
                        query: requestQuery,
                        indexed: mapped,
                        apps: immediateApps + apps,
                        system: settingsPage.items
                    ),
                    promoteWebFallback: true
                )
                FloodlightPerformance.end("IndexedSearch", id: asyncSignpost)
                indexedSearchEnded = true

                try await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, requestGeneration == generation else { return }
                guard requestQuery.count >= 3, fffItems.count < 12 else { return }
                let contentSignpost = FloodlightPerformance.begin("ContentSearch")
                defer {
                    FloodlightPerformance.end("ContentSearch", id: contentSignpost)
                }
                let contentItems = try await index.searchContent(requestQuery)
                guard
                    !Task.isCancelled,
                    requestGeneration == generation,
                    !contentItems.isEmpty
                else {
                    return
                }
                let content = contentItems.map { item in
                    SearchItem(
                        id: "content:\(item.url.path):\(item.line)",
                        title: item.name,
                        subtitle: "\(item.relativePath):\(item.line) · \(item.snippet)",
                        kind: .file,
                        action: .open(item.url),
                        score: 1_000,
                        fileURL: item.url
                    )
                }
                publishResults(
                    buildResults(
                        query: requestQuery,
                        indexed: mapped + content,
                        apps: immediateApps + apps,
                        system: settingsPage.items
                    ),
                    promoteWebFallback: true
                )
            } catch is CancellationError {
                return
            } catch {
                guard requestGeneration == generation else { return }
                NSLog("Floodlight indexed search failed: %@", error.localizedDescription)
                publishResults(
                    buildResults(
                        query: requestQuery,
                        indexed: [],
                        apps: immediateApps,
                        system: settingsPage.items
                    )
                )
            }
        }
    }

    private func searchIndexedFiles(_ query: String) async throws -> [IndexedSearchItem] {
        let signpost = FloodlightPerformance.begin("FileIndexSearch")
        defer {
            FloodlightPerformance.end("FileIndexSearch", id: signpost)
        }
        return try await index.search(query)
    }

    private func searchIndexedApplications(_ query: String) async throws -> [SearchItem] {
        let signpost = FloodlightPerformance.begin("ApplicationIndexSearch")
        defer {
            FloodlightPerformance.end("ApplicationIndexSearch", id: signpost)
        }
        return try await applicationCatalog.search(query)
    }

    private func buildResults(
        query: String,
        indexed: [SearchItem],
        apps: [SearchItem],
        system: [SearchItem]
    ) -> [SearchItem] {
        var output: [SearchItem] = []

        if let value = Calculator.evaluate(query) {
            let answer = Calculator.format(value)
            output.append(
                SearchItem(
                    id: "calculator",
                    title: answer,
                    subtitle: "\(query) = \(answer) · Press Return to copy",
                    kind: .calculator,
                    action: .copy(answer),
                    score: 100_000
                )
            )
        }

        output.append(contentsOf: FloodlightCommandCatalog.search(query))
        output.append(contentsOf: apps)
        output.append(contentsOf: system)
        output.append(contentsOf: indexed)

        var seen = Set<String>()
        output = output
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.score > rhs.score
            }

        if !query.isEmpty,
           let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            output.append(
                SearchItem(
                    id: Self.webSearchResultID,
                    title: "Search the Web for “\(query)”",
                    subtitle: "Open in your default browser",
                    kind: .web,
                    action: .open(url),
                    score: Int.min
                )
            )
        }

        return Array(output.prefix(80))
    }

    private func publishResults(
        _ newResults: [SearchItem],
        resetSelection: Bool = false,
        promoteWebFallback: Bool = false
    ) {
        allResults = newResults
        filterCounts = SearchFilterCounts(items: newResults)
        applySelectedFilter(
            resetSelection: resetSelection,
            promoteWebFallback: promoteWebFallback
        )
    }

    private func applySelectedFilter(
        resetSelection: Bool,
        promoteWebFallback: Bool = false
    ) {
        let previousSelection = selectedID
        results = allResults.filter(selectedFilter.includes)
        selectedID = Self.reconciledSelectionID(
            previousSelection: previousSelection,
            results: results,
            resetSelection: resetSelection,
            promoteWebFallback: promoteWebFallback && !selectionWasUserDriven
        )
    }

    static func reconciledSelectionID(
        previousSelection: SearchItem.ID?,
        results: [SearchItem],
        resetSelection: Bool,
        promoteWebFallback: Bool
    ) -> SearchItem.ID? {
        guard let first = results.first else { return nil }
        if resetSelection {
            return first.id
        }
        if promoteWebFallback,
           previousSelection == webSearchResultID,
           first.id != webSearchResultID {
            return first.id
        }
        if let previousSelection,
           results.contains(where: { $0.id == previousSelection }) {
            return previousSelection
        }
        return first.id
    }

    private func reconcileSelectedFilter() {
        guard selectedFilter.isDynamic else { return }
        let option = makeFilterOption(selectedFilter)
        guard option.count == 0, !option.isLoading else { return }
        selectedFilter = .all
        applySelectedFilter(resetSelection: true)
    }

    private func makeFilterOption(_ filter: SearchResultFilter) -> SearchFilterOption {
        let visibleCount = filterCounts[filter]
        let count: Int
        switch filter {
        case .applications:
            count = max(applicationMatchCount, visibleCount)
        case .settings:
            count = max(settingsMatchCount, visibleCount)
        case .all, .files, .folders, .pdfs, .images, .documents:
            count = visibleCount
        }

        let isLoading: Bool
        switch filter {
        case .all:
            isLoading = isSearching
                || isApplicationCatalogLoading
                || isSettingsCatalogLoading
        case .applications:
            isLoading = isApplicationCatalogLoading
        case .files, .folders, .pdfs, .images, .documents:
            isLoading = isSearching
        case .settings:
            isLoading = isSettingsCatalogLoading
        }

        return SearchFilterOption(
            filter: filter,
            count: count,
            isLoading: isLoading
        )
    }

    private static let webSearchResultID = "web-search"
}
