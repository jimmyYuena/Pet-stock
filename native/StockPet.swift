import SwiftUI
import Foundation
import AppKit
import AVFoundation
import UserNotifications

struct Position: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var value: Double
    var change: Double
    var symbol: String? = nil
}

struct StockSearchResult: Identifiable, Equatable {
    let market: String
    let code: String
    let name: String
    let category: String

    var id: String { symbol }

    var symbol: String {
        switch market.lowercased() {
        case "us":
            let ticker = code.split(separator: ".").first.map(String.init) ?? code
            return "us\(ticker.uppercased())"
        default:
            return "\(market.lowercased())\(code)"
        }
    }

    var marketName: String {
        switch market.lowercased() {
        case "sh": return "沪市"
        case "sz": return "深市"
        case "hk": return "港股"
        case "us": return "美股"
        default: return market.uppercased()
        }
    }

    var instrumentName: String {
        let normalizedCategory = category.uppercased()
        let normalizedName = name.uppercased()
        if normalizedCategory.contains("ETF") || normalizedName.contains("ETF") {
            return "ETF"
        }
        if normalizedCategory.contains("LOF") || normalizedName.contains("LOF") {
            return "LOF"
        }
        if normalizedCategory.hasPrefix("JJ") || normalizedName.contains("基金") {
            return "基金"
        }
        return "股票"
    }

    var isSupportedInstrument: Bool {
        let normalizedCategory = category.uppercased()
        let normalizedName = name.uppercased()
        return normalizedCategory.hasPrefix("GP")
            || normalizedCategory.hasPrefix("JJ")
            || normalizedCategory.contains("ETF")
            || normalizedCategory.contains("LOF")
            || normalizedCategory.contains("FUND")
            || normalizedName.contains("ETF")
            || normalizedName.contains("LOF")
            || normalizedName.contains("基金")
    }
}

struct MarketIndexSnapshot: Identifiable {
    let id: String
    let name: String
    let price: Double
    let change: Double
    let changePercent: Double
}

struct PositionMarketSnapshot {
    let currentPrice: Double?
    let changeAmount: Double
    let changePercent: Double
    let trend: [Double]
    let isLive: Bool
}

private struct MinuteQueryResponse: Decodable {
    let data: [String: MinuteSymbolContainer]
}

private struct MinuteSymbolContainer: Decodable {
    let data: MinuteSeries
}

private struct MinuteSeries: Decodable {
    let data: [String]
}

struct StockNews: Identifiable, Hashable {
    let id: String
    let stock: String
    let title: String
    let source: String
    let link: URL?
    let publishedAt: Date
}

final class StockNewsRSSParser: NSObject, XMLParserDelegate {
    private let stock: String
    private var insideItem = false
    private var currentText = ""
    private var title = ""
    private var link = ""
    private var guid = ""
    private var source = ""
    private var publishedAt = ""
    private(set) var items: [StockNews] = []

    init(stock: String) {
        self.stock = stock
    }

    static func parse(_ data: Data, stock: String) -> [StockNews] {
        let delegate = StockNewsRSSParser(stock: stock)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentText = ""
        if elementName.lowercased() == "item" {
            insideItem = true
            title = ""
            link = ""
            guid = ""
            source = ""
            publishedAt = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if insideItem {
            switch element {
            case "title": title = text
            case "link": link = text
            case "guid": guid = text
            case "source": source = text
            case "pubdate": publishedAt = text
            case "item":
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                let date = formatter.date(from: publishedAt) ?? Date.distantPast
                let cleanTitle = source.isEmpty ? title : title.replacingOccurrences(of: " - \(source)", with: "")
                if !cleanTitle.isEmpty {
                    items.append(StockNews(
                        id: guid.isEmpty ? link : guid,
                        stock: stock,
                        title: cleanTitle,
                        source: source,
                        link: URL(string: link),
                        publishedAt: date
                    ))
                }
                insideItem = false
            default: break
            }
        }
        currentText = ""
    }
}

@MainActor
final class PetStore: ObservableObject {
    @Published var positions: [Position] = [] {
        didSet {
            guard !isRestoringPositions else { return }
            schedulePositionsSave()
        }
    }
    @Published var notificationsEnabled = true
    @Published var screenshot: NSImage?
    @Published var showingEditor = false
    @Published var newsItems: [StockNews] = []
    @Published var hiddenNewsIDs: Set<String> = []
    @Published var isLoadingNews = false
    @Published var newsError: String?
    @Published var marketIndices: [MarketIndexSnapshot] = []
    @Published var positionMarkets: [UUID: PositionMarketSnapshot] = [:]
    @Published var isLoadingMarket = false
    @Published var marketUpdatedAt: Date?
    @Published var marketError: String?
    @Published var stockSearchResults: [StockSearchResult] = []
    @Published var isSearchingStocks = false
    @Published var stockSearchError: String?

    private let key = "stockPet.positions.v1"
    private let hiddenNewsKey = "stockPet.hiddenNews.v1"
    private let speaker = AVSpeechSynthesizer()
    private var isRestoringPositions = true
    private var hasLoadedNews = false
    private var positionsSaveTask: Task<Void, Never>?
    private var newsPollingTask: Task<Void, Never>?
    private var marketPollingTask: Task<Void, Never>?

    init() {
        if let saved = Self.loadSavedPositions(forKey: key) {
            positions = saved
        } else {
            positions = Self.defaultPositions
        }
        isRestoringPositions = false
        hiddenNewsIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenNewsKey) ?? [])
        startNewsPolling()
        startMarketPolling()
    }

    private static func loadSavedPositions(forKey key: String) -> [Position]? {
        guard UserDefaults.standard.object(forKey: key) != nil,
              let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([Position].self, from: data) else {
            return nil
        }
        return normalizePositions(saved)
    }

    private static var defaultPositions: [Position] {
        [
            Position(name: "贵州茅台", value: 52_000, change: 2.35, symbol: "sh600519"),
            Position(name: "宁德时代", value: 38_000, change: 0.42, symbol: "sz300750"),
            Position(name: "腾讯控股", value: 26_000, change: -1.15, symbol: "hk00700")
        ]
    }

    private static func normalizePositions(_ positions: [Position]) -> [Position] {
        positions.map { position in
            var position = position
            if position.symbol?.isEmpty != false {
                position.symbol = defaultSymbol(for: position.name)
            }
            return position
        }
    }

    private func startNewsPolling() {
        guard newsPollingTask == nil else { return }
        newsPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNews()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func startMarketPolling() {
        guard marketPollingTask == nil else { return }
        marketPollingTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                // 报价（收益率数字）每 2 秒刷新一次；分时走势较重，约每 30 秒才重新拉取。
                await self.refreshMarketData(includeTrend: tick % 15 == 0)
                tick += 1
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func refreshMarketData(includeTrend: Bool = true) async {
        guard !isLoadingMarket else { return }
        isLoadingMarket = true
        marketError = nil
        defer { isLoadingMarket = false }

        let indexDefinitions = [
            ("sh000001", "上证指数", 3955.58),
            ("sz399001", "深证成指", 14779.40),
            ("sz399006", "创业板指", 3804.70),
            ("sh000688", "科创50", 1924.27),
            ("sh000300", "沪深300", 4786.78)
        ]
        let symbols = Set(indexDefinitions.map(\.0) + positions.compactMap(\.symbol).filter { !$0.isEmpty })

        do {
            let quotes = try await fetchQuotes(Array(symbols))
            marketIndices = indexDefinitions.map { code, name, fallbackPrice in
                let quote = quotes[code]
                return MarketIndexSnapshot(
                    id: code,
                    name: name,
                    price: quote?.price ?? fallbackPrice,
                    change: quote?.change ?? 0,
                    changePercent: quote?.percent ?? 0
                )
            }

            var snapshots: [UUID: PositionMarketSnapshot] = [:]
            for position in positions {
                let symbol = position.symbol ?? ""
                let quote = quotes[symbol]
                let changePercent = quote?.percent ?? position.change
                let previous = positionMarkets[position.id]
                var liveTrend: [Double]? = nil
                if includeTrend, !symbol.isEmpty {
                    liveTrend = try? await fetchMinuteTrend(symbol)
                }

                let resolvedTrend: [Double]
                let isLive: Bool
                if let liveTrend, !liveTrend.isEmpty {
                    resolvedTrend = liveTrend
                    isLive = quote != nil
                } else if let previous, previous.isLive, !previous.trend.isEmpty {
                    // 未到分时刷新周期时，复用上一次的真实走势，只更新报价数字。
                    resolvedTrend = previous.trend
                    isLive = quote != nil
                } else {
                    resolvedTrend = Self.fallbackTrend(seed: changePercent)
                    isLive = false
                }

                snapshots[position.id] = PositionMarketSnapshot(
                    currentPrice: quote?.price,
                    changeAmount: quote?.change ?? 0,
                    changePercent: changePercent,
                    trend: resolvedTrend,
                    isLive: isLive
                )
            }
            positionMarkets = snapshots
            marketUpdatedAt = Date()
        } catch {
            marketError = "行情连接失败，当前展示本地走势"
            marketIndices = indexDefinitions.map {
                MarketIndexSnapshot(id: $0.0, name: $0.1, price: $0.2, change: 0, changePercent: 0)
            }
            positionMarkets = Dictionary(uniqueKeysWithValues: positions.map { position in
                (position.id, PositionMarketSnapshot(
                    currentPrice: nil,
                    changeAmount: 0,
                    changePercent: position.change,
                    trend: Self.fallbackTrend(seed: position.change),
                    isLive: false
                ))
            })
        }
    }

    private struct QuoteValue {
        let price: Double
        let change: Double
        let percent: Double
    }

    private func fetchQuotes(_ symbols: [String]) async throws -> [String: QuoteValue] {
        guard !symbols.isEmpty,
              let url = URL(string: "https://qt.gtimg.cn/q=" + symbols.map { "s_\($0)" }.joined(separator: ",")) else {
            return [:]
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("StockPet/0.4", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .isoLatin1) else {
            throw URLError(.badServerResponse)
        }

        var result: [String: QuoteValue] = [:]
        for line in text.components(separatedBy: ";") {
            guard let equals = line.firstIndex(of: "="),
                  let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""), firstQuote < lastQuote else { continue }
            let rawKey = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawKey.replacingOccurrences(of: "v_s_", with: "")
            let start = line.index(after: firstQuote)
            let fields = line[start..<lastQuote].split(separator: "~", omittingEmptySubsequences: false)
            guard fields.count > 5,
                  let price = Double(fields[3]),
                  let change = Double(fields[4]),
                  let percent = Double(fields[5]) else { continue }
            result[key] = QuoteValue(price: price, change: change, percent: percent)
        }
        return result
    }

    private func fetchMinuteTrend(_ symbol: String) async throws -> [Double] {
        var components = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query")
        components?.queryItems = [URLQueryItem(name: "code", value: symbol)]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("StockPet/0.4", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(MinuteQueryResponse.self, from: data)
        let rows = decoded.data[symbol]?.data.data ?? []
        return rows.compactMap { row in
            let fields = row.split(separator: " ")
            guard fields.count > 1 else { return nil }
            return Double(fields[1])
        }
    }

    func searchStocks(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearStockSearch()
            return
        }

        isSearchingStocks = true
        stockSearchError = nil
        defer { isSearchingStocks = false }

        var components = URLComponents(string: "https://smartbox.gtimg.cn/s3/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "t", value: "all")
        ]
        guard let url = components?.url else {
            stockSearchResults = []
            stockSearchError = "搜索关键词无效"
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("StockPet/0.5", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8),
                  let firstQuote = text.firstIndex(of: "\""),
                  let lastQuote = text.lastIndex(of: "\""),
                  firstQuote < lastQuote else {
                throw URLError(.badServerResponse)
            }

            let encodedPayload = String(text[text.index(after: firstQuote)..<lastQuote])
            let jsonString = "\"\(encodedPayload)\""
            let payload = (try? JSONDecoder().decode(String.self, from: Data(jsonString.utf8))) ?? encodedPayload
            var seenSymbols = Set<String>()
            stockSearchResults = payload
                .split(separator: "^")
                .compactMap { record -> StockSearchResult? in
                    let fields = record.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
                    guard fields.count >= 5 else { return nil }
                    let result = StockSearchResult(
                        market: fields[0],
                        code: fields[1],
                        name: fields[2],
                        category: fields[4]
                    )
                    guard ["sh", "sz", "hk", "us"].contains(result.market.lowercased()),
                          result.isSupportedInstrument,
                          !result.name.isEmpty,
                          !seenSymbols.contains(result.symbol) else {
                        return nil
                    }
                    seenSymbols.insert(result.symbol)
                    return result
                }
                .prefix(8)
                .map { $0 }

            if stockSearchResults.isEmpty {
                stockSearchError = "没有找到匹配的股票或 ETF"
            }
        } catch is CancellationError {
            return
        } catch {
            stockSearchResults = []
            stockSearchError = "搜索暂时不可用，请稍后重试"
        }
    }

    func clearStockSearch() {
        stockSearchResults = []
        stockSearchError = nil
        isSearchingStocks = false
    }

    func addStock(_ result: StockSearchResult) {
        guard !positions.contains(where: { $0.symbol?.lowercased() == result.symbol.lowercased() }) else {
            return
        }
        positions.append(Position(name: result.name, value: 0, change: 0, symbol: result.symbol))
        save()
    }

    func addManualPosition() {
        positions.append(Position(name: "未命名股票", value: 0, change: 0, symbol: ""))
        save()
    }

    func removePosition(id: UUID) {
        positions.removeAll { $0.id == id }
        save()
    }

    static func fallbackTrend(seed: Double, count: Int = 72) -> [Double] {
        let normalizedSeed = max(-10, min(10, seed))
        return (0..<count).map { index in
            let progress = Double(index) / Double(max(1, count - 1))
            let wave = sin(Double(index) * 0.43 + seed) * 0.32 + cos(Double(index) * 0.17) * 0.18
            return 100 + normalizedSeed * progress + wave
        }
    }

    private static func defaultSymbol(for name: String) -> String? {
        switch name {
        case "贵州茅台": return "sh600519"
        case "宁德时代": return "sz300750"
        case "腾讯控股": return "hk00700"
        default: return nil
        }
    }

    /// 单个持仓的“今日涨跌幅”：优先用实时行情，取不到再退回手动录入的备用收益率。
    func todayChange(for position: Position) -> Double {
        positionMarkets[position.id]?.changePercent ?? position.change
    }

    /// 今日全部持仓的总收益率（只看今天，不含历史成本）。
    /// 有市值时按市值加权；未填市值时退化为等权平均，保证仍反映今日涨跌而不是 0.00%。
    var totalReturn: Double {
        guard !positions.isEmpty else { return 0 }
        let totalValue = positions.reduce(0) { $0 + max(0, $1.value) }
        if totalValue > 0 {
            return positions.reduce(0) { result, position in
                result + max(0, position.value) * todayChange(for: position)
            } / totalValue
        }
        return positions.reduce(0) { $0 + todayChange(for: $1) } / Double(positions.count)
    }

    var topPositions: [Position] {
        Array(positions.sorted { $0.value > $1.value }.prefix(3))
    }

    var visibleNews: [StockNews] {
        newsItems.filter { !hiddenNewsIDs.contains($0.id) }
    }

    func save() {
        positionsSaveTask?.cancel()
        positionsSaveTask = nil
        persistPositions()
    }

    private func schedulePositionsSave() {
        positionsSaveTask?.cancel()
        positionsSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.positionsSaveTask = nil
                self?.persistPositions()
            }
        }
    }

    private func persistPositions() {
        if let data = try? JSONEncoder().encode(positions) {
            UserDefaults.standard.set(data, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }

    func refreshNews() async {
        guard !isLoadingNews else { return }
        isLoadingNews = true
        newsError = nil
        defer { isLoadingNews = false }

        let previousIDs = Set(newsItems.map(\.id))
        var gathered: [StockNews] = []

        for position in topPositions {
            var components = URLComponents(string: "https://news.google.com/rss/search")
            components?.queryItems = [
                URLQueryItem(name: "q", value: position.name),
                URLQueryItem(name: "hl", value: "zh-CN"),
                URLQueryItem(name: "gl", value: "CN"),
                URLQueryItem(name: "ceid", value: "CN:zh-Hans")
            ]
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("StockPet/0.3", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                gathered.append(contentsOf: StockNewsRSSParser.parse(data, stock: position.name).prefix(3))
            } catch {
                newsError = "资讯暂时不可用"
            }
        }

        var seenTitles = Set<String>()
        newsItems = gathered
            .sorted { $0.publishedAt > $1.publishedAt }
            .filter { seenTitles.insert($0.title).inserted }
            .prefix(9)
            .map { $0 }

        if hasLoadedNews,
           let newest = newsItems.first(where: { !previousIDs.contains($0.id) }) {
            sendNewsNotification(newest)
        }
        hasLoadedNews = true
    }

    func hideNews(_ item: StockNews) {
        hiddenNewsIDs.insert(item.id)
        persistHiddenNews()
    }

    func hideAllNews() {
        hiddenNewsIDs.formUnion(newsItems.map(\.id))
        persistHiddenNews()
    }

    private func persistHiddenNews() {
        UserDefaults.standard.set(Array(hiddenNewsIDs.suffix(100)), forKey: hiddenNewsKey)
    }

    private func sendNewsNotification(_ item: StockNews) {
        guard notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(item.stock) · 热门资讯"
            content.body = item.title
            content.sound = .default
            // 记录对应新闻链接，点击通知时打开网页。
            if let link = item.link?.absoluteString {
                content.userInfo = ["link": link]
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
    }

    func testAlert(returnRate: Double? = nil) {
        guard notificationsEnabled else { return }
        let rate = returnRate ?? totalReturn
        let direction = rate >= 0 ? "上涨" : "下跌"
        let ending = rate >= 0 ? "牛宠物正在庆祝。" : "熊宠物上线了。"
        let message = "你的总仓位当前\(direction) \(String(format: "%.2f", abs(rate)))%，\(ending)"

        let speech = AVSpeechUtterance(string: message)
        speech.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        speech.rate = 0.48
        speaker.stopSpeaking(at: .immediate)
        speaker.speak(speech)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = "持仓异动提醒"
            content.body = message
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

private let mainPetWindowTitle = "持仓宠物"

private func configureMainPetWindowPresentation(_ window: NSWindow) {
    window.level = .statusBar
    window.isMovableByWindowBackground = true
    window.styleMask = [.borderless, .fullSizeContentView]
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isOpaque = false
    window.backgroundColor = .clear
    window.canHide = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "StockPet", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let window = self.mainPetWindow else { return }
            configureMainPetWindowPresentation(window)
            window.hasShadow = false
            window.setContentSize(NSSize(width: 150, height: 165))
            window.center()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        restoreMainPetWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        restoreMainPetWindow()
    }

    func applicationDidResignActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.keepMainPetWindowFloating()
        }
    }

    private var mainPetWindow: NSWindow? {
        NSApplication.shared.windows.first(where: { $0.title == mainPetWindowTitle })
    }

    private func restoreMainPetWindow() {
        guard let window = mainPetWindow else { return }
        configureMainPetWindowPresentation(window)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.setIsVisible(true)
        window.orderFrontRegardless()
    }

    private func keepMainPetWindowFloating() {
        guard let window = mainPetWindow, !window.isMiniaturized else { return }
        configureMainPetWindowPresentation(window)
        window.setIsVisible(true)
        window.orderFrontRegardless()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // 点击通知：如果带有新闻链接就用默认浏览器打开对应网页。
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["link"] as? String,
           let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}

final class CompactPetInteractionNSView: NSView {
    var onClick: () -> Void = {}

    private var mouseDownScreenLocation: NSPoint?
    private var windowOriginAtMouseDown: NSPoint?
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenLocation = NSEvent.mouseLocation
        windowOriginAtMouseDown = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownScreenLocation,
              let startOrigin = windowOriginAtMouseDown,
              let window else { return }

        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - startLocation.x
        let deltaY = currentLocation.y - startLocation.y
        if hypot(deltaX, deltaY) >= 3 { didDrag = true }

        guard didDrag else { return }
        window.setFrameOrigin(NSPoint(x: startOrigin.x + deltaX, y: startOrigin.y + deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick() }
        mouseDownScreenLocation = nil
        windowOriginAtMouseDown = nil
        didDrag = false
    }
}

struct CompactPetInteractionLayer: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> CompactPetInteractionNSView {
        let view = CompactPetInteractionNSView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: CompactPetInteractionNSView, context: Context) {
        nsView.onClick = onClick
    }
}

private enum WindowResizeRegion: Equatable {
    case none
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var resizesLeft: Bool {
        self == .left || self == .topLeft || self == .bottomLeft
    }

    var resizesRight: Bool {
        self == .right || self == .topRight || self == .bottomRight
    }

    var resizesTop: Bool {
        self == .top || self == .topLeft || self == .topRight
    }

    var resizesBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }
}

private struct WindowResizeHandle: View {
    let region: WindowResizeRegion
    let onResizeEnded: () -> Void
    @State private var initialWindowFrame: NSRect?
    @State private var initialMouseLocation: NSPoint?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    resizeCursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in resizeWindow() }
                    .onEnded { _ in
                        initialWindowFrame = nil
                        initialMouseLocation = nil
                        onResizeEnded()
                    }
            )
    }

    // 只用系统原生的缩放光标提示用户可拖拽改变大小，不再叠加图标。
    private var resizeCursor: NSCursor {
        switch region {
        case .top: return .frameResize(position: .top, directions: .all)
        case .bottom: return .frameResize(position: .bottom, directions: .all)
        case .left: return .frameResize(position: .left, directions: .all)
        case .right: return .frameResize(position: .right, directions: .all)
        case .topLeft: return .frameResize(position: .topLeft, directions: .all)
        case .topRight: return .frameResize(position: .topRight, directions: .all)
        case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
        case .none: return .arrow
        }
    }

    // 用屏幕绝对坐标算位移，避免窗口一边缩放一边反馈到手势本地坐标而抖动。
    private func resizeWindow() {
        guard region != .none,
              let window = NSApplication.shared.windows.first(where: { $0.title == "持仓宠物" })
                ?? NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first else { return }

        if initialWindowFrame == nil {
            initialWindowFrame = window.frame
            initialMouseLocation = NSEvent.mouseLocation
        }
        guard let initialFrame = initialWindowFrame,
              let startMouse = initialMouseLocation else { return }

        // 屏幕坐标：x 向右为正，y 向上为正（与 AppKit 窗口 frame 一致）。
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y

        let minimum = window.contentMinSize
        let maximum = window.contentMaxSize
        let minWidth = max(1, minimum.width)
        let minHeight = max(1, minimum.height)
        let maxWidth = maximum.width > 0 ? maximum.width : .greatestFiniteMagnitude
        let maxHeight = maximum.height > 0 ? maximum.height : .greatestFiniteMagnitude

        var frame = initialFrame

        // 水平：拖右边固定左缘，拖左边固定右缘。
        if region.resizesRight {
            let width = min(max(initialFrame.width + dx, minWidth), maxWidth)
            frame.origin.x = initialFrame.minX
            frame.size.width = width
        } else if region.resizesLeft {
            let width = min(max(initialFrame.width - dx, minWidth), maxWidth)
            frame.size.width = width
            frame.origin.x = initialFrame.maxX - width
        }

        // 垂直：拖顶边固定底缘，拖底边固定顶缘。
        if region.resizesTop {
            let height = min(max(initialFrame.height + dy, minHeight), maxHeight)
            frame.origin.y = initialFrame.minY
            frame.size.height = height
        } else if region.resizesBottom {
            let height = min(max(initialFrame.height - dy, minHeight), maxHeight)
            frame.size.height = height
            frame.origin.y = initialFrame.maxY - height
        }

        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }
}

private struct WindowResizeInteractionLayer: View {
    let onResizeEnded: () -> Void
    private let edgeThickness: CGFloat = 10
    private let cornerSize: CGFloat = 16

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                WindowResizeHandle(region: .left, onResizeEnded: onResizeEnded).frame(width: edgeThickness)
                Spacer(minLength: 0)
                WindowResizeHandle(region: .right, onResizeEnded: onResizeEnded).frame(width: edgeThickness)
            }
            VStack(spacing: 0) {
                WindowResizeHandle(region: .top, onResizeEnded: onResizeEnded).frame(height: edgeThickness)
                Spacer(minLength: 0)
                WindowResizeHandle(region: .bottom, onResizeEnded: onResizeEnded).frame(height: edgeThickness)
            }
            WindowResizeHandle(region: .topLeft, onResizeEnded: onResizeEnded)
                .frame(width: cornerSize, height: cornerSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            WindowResizeHandle(region: .topRight, onResizeEnded: onResizeEnded)
                .frame(width: cornerSize, height: cornerSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            WindowResizeHandle(region: .bottomLeft, onResizeEnded: onResizeEnded)
                .frame(width: cornerSize, height: cornerSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            WindowResizeHandle(region: .bottomRight, onResizeEnded: onResizeEnded)
                .frame(width: cornerSize, height: cornerSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}

/// 全局动画调速（帧动画皮肤播放速度倍率），由调试面板控制
enum PetAnimTuning {
    static var speedMultiplier: Double = 1.0
}

@MainActor
final class PetDebugState: ObservableObject {
    @Published var isMockingReturn = false
    @Published var mockReturnRate = 0.0
    @Published var actionToken = UUID()

    @Published var speedMultiplier: Double {
        didSet {
            PetAnimTuning.speedMultiplier = speedMultiplier
            UserDefaults.standard.set(speedMultiplier, forKey: "stockPet.animSpeed.v1")
        }
    }

    /// 锁定的演示收益率：开启后覆盖真实收益率，关闭调试窗口和重启应用后仍然生效
    @Published var overrideEnabled: Bool {
        didSet { UserDefaults.standard.set(overrideEnabled, forKey: "stockPet.mockOverride.enabled.v1") }
    }
    @Published var overrideValue: Double {
        didSet { UserDefaults.standard.set(overrideValue, forKey: "stockPet.mockOverride.value.v1") }
    }

    init() {
        overrideEnabled = UserDefaults.standard.bool(forKey: "stockPet.mockOverride.enabled.v1")
        overrideValue = UserDefaults.standard.double(forKey: "stockPet.mockOverride.value.v1")
        let savedSpeed = UserDefaults.standard.double(forKey: "stockPet.animSpeed.v1")
        speedMultiplier = savedSpeed > 0 ? savedSpeed : 1.0
        PetAnimTuning.speedMultiplier = speedMultiplier
    }
}

@main
struct StockPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = PetStore()
    @StateObject private var debugState = PetDebugState()

    var body: some Scene {
        WindowGroup("持仓宠物") {
            ContentView(store: store, debugState: debugState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)

        Window("宠物调试", id: "pet-debug") {
            ContentView(store: store, debugState: debugState, isDebugWindow: true)
        }
        .defaultSize(width: 440, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
    }
}

enum PetMood: Equatable {
    case bull, bear

    var accessibilityName: String {
        switch self { case .bull: "红色牛宠物"; case .bear: "绿色熊宠物" }
    }

    var color: Color {
        switch self { case .bull: Color(red: 0.96, green: 0.13, blue: 0.16); case .bear: Color(red: 0.14, green: 0.76, blue: 0.39) }
    }
}

struct PetSkinSpec {
    let idleFrames: Int
    let happyFrames: Int
    let sadFrames: Int
}

enum PetAppearance: String, CaseIterable, Identifiable {
    case robot, mech, polar
    case labubu, chiikawa, usagi, hachiware, capy, shuitunlulu, deskotter, nai, gugugaga, crybaby
    case beretbear, woolbell, bubu, jokebear, obear

    var id: String { rawValue }

    static var availableCases: [PetAppearance] {
#if LOCAL_EXTENDED_SKINS
        Array(allCases)
#else
        [.robot, .mech, .polar]
#endif
    }

    var name: String {
        switch self {
        case .robot: return "行情机器人"
        case .mech: return "涨跌机甲"
        case .polar: return "红绿北极熊"
        case .labubu: return "拉布布"
        case .chiikawa: return "吉伊"
        case .usagi: return "疯兔"
        case .hachiware: return "小八"
        case .capy: return "卡皮巴拉"
        case .shuitunlulu: return "水豚噜噜"
        case .deskotter: return "上班水獭"
        case .nai: return "奶龙"
        case .gugugaga: return "咕咕嘎嘎"
        case .crybaby: return "哭包娃娃"
        case .beretbear: return "贝雷咖啡熊"
        case .woolbell: return "铃铛绵羊"
        case .bubu: return "布布熊"
        case .jokebear: return "搞笑白熊"
        case .obear: return "围巾棕熊"
        }
    }

    /// 帧动画皮肤规格（nil 表示非帧动画皮肤）
    var skinSpec: PetSkinSpec? {
        switch self {
        case .mech:
            return PetSkinSpec(idleFrames: 10, happyFrames: 10, sadFrames: 10)
        case .polar:
            return PetSkinSpec(idleFrames: 12, happyFrames: 12, sadFrames: 10)
        case .labubu, .chiikawa, .usagi, .hachiware, .capy, .shuitunlulu, .deskotter, .nai, .gugugaga, .crybaby:
            return PetSkinSpec(idleFrames: 6, happyFrames: 9, sadFrames: 8)
        case .beretbear, .woolbell:
            return PetSkinSpec(idleFrames: 6, happyFrames: 9, sadFrames: 8)
        case .bubu, .jokebear, .obear:
            return PetSkinSpec(idleFrames: 6, happyFrames: 9, sadFrames: 8)
        default:
            return nil
        }
    }

    var previewName: String {
        switch self {
        case .robot: return ""
        default: return "skin_\(rawValue)_idle_0"
        }
    }

    var assetName: String? {
        nil
    }

    var tagline: String {
        switch self {
        case .robot: return "红涨绿跌随行情变身，元气担当"
        case .mech: return "七档收益动作：奔跑、跳跃、攻击、滑倒"
        case .polar: return "八档收益动作：欢跑、投掷、受击、眩晕"
        case .labubu: return "顶流拉布布，涨跌都拉风"
        case .chiikawa: return "小小一只，替你扛住大盘"
        case .usagi: return "乌拉！涨了跟你一起发疯"
        case .hachiware: return "乐观小八，跌了也想得开"
        case .capy: return "情绪稳定卡皮巴拉，头顶橘子稳如山"
        case .shuitunlulu: return "橘帽水豚，慢悠悠陪你等反弹"
        case .deskotter: return "工位同款水獭，替你摸鱼盯盘"
        case .nai: return "黄黄一坨奶龙，亏了也理直气壮"
        case .gugugaga: return "企鹅工装，办公室秘密盯盘搭子"
        case .crybaby: return "赚了笑亏了哭，情绪全帮你表达"
        case .beretbear: return "贝雷帽咖啡熊，边看盘边拉花"
        case .woolbell: return "卷角铃铛羊，跌了咩咩安慰你"
        case .bubu: return "软乎乎布布，跌了也抱抱你"
        case .jokebear: return "淡定白熊，涨跌都好笑"
        case .obear: return "红围巾棕熊，暖暖守护仓位"
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: PetStore
    @ObservedObject var debugState: PetDebugState
    let isDebugWindow: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("stockPet.appearance.v1") private var selectedAppearanceRaw = PetAppearance.robot.rawValue
    @State private var isExpanded = false
    @State private var showingNews = false
    @State private var hoveringCompact = false
    @State private var compactPetHovering = false
    @State private var compactWindowFrameBeforeExpansion: NSRect?
    @GestureState private var draggingCompactWindow = false
    @State private var hoveringPet = false
    @State private var importingScreenshot = false
    @State private var alertPulse = false
    @State private var motionToken = UUID()
    @State private var showingPetStore = false
    @State private var showingShareCard = false
    @State private var shareIncludePositions = false
    @State private var shareFeedback = ""
    @State private var stockSearchQuery = ""
    @State private var stockSearchTask: Task<Void, Never>?
    @FocusState private var stockSearchFocused: Bool
    private let gainColor = Color(red: 1.0, green: 0.28, blue: 0.30)
    private let lossColor = Color(red: 0.20, green: 1.0, blue: 0.56)
    private let popoverBackground = Color(red: 0.035, green: 0.05, blue: 0.08)
    private let expandedWindowWidthKey = "stockPet.expandedWindow.width.v1"
    private let expandedWindowHeightKey = "stockPet.expandedWindow.height.v1"
    private let expandedWindowMinimumSize = NSSize(width: 340, height: 260)
    private let expandedWindowMaximumSize = NSSize(width: 1600, height: 1100)

    init(store: PetStore, debugState: PetDebugState, isDebugWindow: Bool = false) {
        self.store = store
        self.debugState = debugState
        self.isDebugWindow = isDebugWindow
    }

    private var displayReturn: Double {
        if debugState.isMockingReturn { return debugState.mockReturnRate }
        if debugState.overrideEnabled { return debugState.overrideValue }
        return store.totalReturn
    }

    private var selectedAppearance: PetAppearance {
        let selected = PetAppearance(rawValue: selectedAppearanceRaw) ?? .robot
        return PetAppearance.availableCases.contains(selected) ? selected : .robot
    }

    private var speedMultiplierBinding: Binding<Double> {
        Binding(
            get: { debugState.speedMultiplier },
            set: { debugState.speedMultiplier = $0 }
        )
    }

    private var mockReturnBinding: Binding<Double> {
        Binding(
            get: { debugState.mockReturnRate },
            set: {
                debugState.mockReturnRate = $0
                debugState.isMockingReturn = true
            }
        )
    }

    private var mood: PetMood {
        displayReturn >= 0 ? .bull : .bear
    }

    private var petScale: CGFloat {
        let clampedReturn = min(10, max(-10, displayReturn))
        if clampedReturn >= 0 {
            return CGFloat(1 + clampedReturn / 10)
        }
        return CGFloat(1 + clampedReturn / 20)
    }

    private var compactPetSide: CGFloat { 100 * petScale }

    private var compactWindowSize: NSSize {
        NSSize(width: compactPetSide + 50, height: compactPetSide + 65)
    }

    private var expandedWindowHeight: CGFloat {
        650
    }

    private var statusText: String {
        switch mood {
        case .bull:
            if displayReturn >= 5 { return "财迷小牛开心到冒金光了" }
            if displayReturn >= 2 { return "小牛开心得蹦起来了" }
            if displayReturn >= 1 { return "小牛开始微笑了" }
            return "小牛平静地陪着你"
        case .bear: return displayReturn < -3 ? "小熊需要你的安慰" : "小熊今天有点紧张"
        }
    }

    var body: some View {
        Group {
            if isDebugWindow {
                debugExpandedView
                    .frame(
                        minWidth: 420,
                        idealWidth: 440,
                        minHeight: 620,
                        idealHeight: 680
                    )
            } else if isExpanded {
                expandedView
                    .frame(
                        minWidth: expandedWindowMinimumSize.width,
                        minHeight: expandedWindowMinimumSize.height
                    )
                    .transition(.scale(scale: 0.82, anchor: .center).combined(with: .opacity))
            } else {
                compactPet
                    .frame(width: compactWindowSize.width, height: compactWindowSize.height)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .overlay {
            if !isDebugWindow && isExpanded {
                WindowResizeInteractionLayer(onResizeEnded: persistExpandedWindowSize)
                    .accessibilityHidden(true)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isExpanded)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: petScale)
        .fileImporter(isPresented: $importingScreenshot, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            store.screenshot = NSImage(contentsOf: url)
            store.showingEditor = true
        }
        .onChange(of: displayReturn) { _, _ in
            triggerPetMotion()
            if !isDebugWindow && !isExpanded {
                DispatchQueue.main.async {
                    resizeCompactWindowForReturn()
                }
            }
        }
        .onAppear {
            if !isDebugWindow {
                DispatchQueue.main.async {
                    resizeCompactWindowForReturn(animated: false)
                }
            }
        }
        .sheet(isPresented: $showingPetStore) {
            petStorePage
        }
        .sheet(isPresented: $store.showingEditor) {
            editor
                .frame(width: 680, height: 620)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.075, green: 0.08, blue: 0.12),
                            Color(red: 0.035, green: 0.04, blue: 0.065)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingShareCard) {
            shareCardPage
        }
        .onChange(of: debugState.actionToken) { _, _ in
            triggerPetMotion()
        }
        .onDisappear {
            if isDebugWindow { resetDebugState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if !isDebugWindow {
                store.save()
            }
        }
    }

    private var compactPet: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(compactWindowDragGesture)
                .allowsWindowActivationEvents()
            AnimatedStockPet(
                mood: mood,
                returnRate: displayReturn,
                isAlerting: alertPulse,
                isHovered: compactPetHovering,
                appearance: selectedAppearance
            )
            .frame(width: compactPetSide, height: compactPetSide)
            .overlay {
                CompactPetInteractionLayer {
                    toggleExpanded(true)
                }
            }
            Text(percent(displayReturn))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(mood.color.opacity(0.9), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18)))
                .offset(y: compactPetSide / 2 + 16)
                .allowsHitTesting(false)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        hoveringCompact = false
                        showingNews.toggle()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Circle()
                                .fill(.black.opacity(0.58))
                                .frame(width: 25, height: 25)
                                .overlay(Circle().stroke(.white.opacity(0.18)))
                            Image(systemName: "bell.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(width: 25, height: 25)
                            if !store.visibleNews.isEmpty {
                                Text("\(min(store.visibleNews.count, 9))")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 13, height: 13)
                                    .background(.red, in: Circle())
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .allowsWindowActivationEvents()
                    .help("热门资讯")
                    .popover(isPresented: $showingNews, arrowEdge: .trailing) {
                        compactNewsCard
                    }
                    .zIndex(10)
                }
                HStack {
                    Spacer()
                    Button {
                        hoveringCompact = false
                        openDebugPanel()
                    } label: {
                        Circle()
                            .fill(.black.opacity(0.62))
                            .frame(width: 25, height: 25)
                            .overlay(Circle().stroke(.white.opacity(0.20)))
                            .overlay(
                                Image(systemName: "ladybug.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                    .allowsWindowActivationEvents()
                    .accessibilityLabel("调试")
                    .help("调试当前宠物素材")
                    .zIndex(10)
                }
                Spacer()
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover {
            compactPetHovering = $0
            if !showingNews { hoveringCompact = $0 }
            if !$0 { hoveringCompact = false }
            if !draggingCompactWindow { NSCursor.arrow.set() }
        }
        .onChange(of: draggingCompactWindow) { _, dragging in
            if dragging {
                NSCursor.closedHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .popover(isPresented: $hoveringCompact, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            compactPositionsCard
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mood.accessibilityName)，总收益 \(percent(displayReturn))")
        .accessibilityAddTraits(.isButton)
        .help("单击查看持仓，按住拖动")
    }

    private var compactWindowDragGesture: some Gesture {
        WindowDragGesture()
            .updating($draggingCompactWindow) { _, state, _ in
                state = true
            }
    }

    private var compactNewsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("持仓热门资讯", systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if store.isLoadingNews {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await store.refreshNews() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("刷新")
                }
                Button {
                    store.hideAllNews()
                    showingNews = false
                } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.plain)
                .help("隐藏全部")
            }

            if store.visibleNews.isEmpty {
                Text(store.newsError ?? (store.isLoadingNews ? "正在获取最新资讯…" : "暂无新资讯"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 38)
            } else {
                ForEach(Array(store.visibleNews.prefix(4).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: 7) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text(item.stock)
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.orange)
                                Text(relativeTime(item.publishedAt))
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                            Button {
                                if let link = item.link { NSWorkspace.shared.open(link) }
                            } label: {
                                Text(item.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                            }
                            .buttonStyle(.plain)
                            if !item.source.isEmpty {
                                Text(item.source)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                        }
                        Spacer(minLength: 2)
                        Button { store.hideNews(item) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .help("隐藏此条")
                    }
                }
            }
        }
        .padding(11)
        .frame(width: 245)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(popoverBackground.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
        .preferredColorScheme(.dark)
    }

    private var compactPositionsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("核心仓位")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
            ForEach(store.topPositions) { item in
                let change = store.todayChange(for: item)
                HStack(spacing: 10) {
                    Text(item.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(percent(change))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(change >= 0 ? gainColor : lossColor)
                }
            }
        }
        .padding(12)
        .frame(width: 168)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(popoverBackground.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.58), radius: 18, y: 8)
        .preferredColorScheme(.dark)
    }

    private var debugExpandedView: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.17), Color(red: 0.045, green: 0.05, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(mood.color.opacity(0.14))
                .frame(width: 300, height: 300)
                .blur(radius: 55)
                .offset(y: -155)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(mood.color).frame(width: 7, height: 7).shadow(color: mood.color, radius: 5)
                    Text("宠物调试").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
                    Spacer()
                    Button { closeDebugPanel() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 25, height: 24).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("关闭调试")
                }
                .padding(.horizontal, 18)
                .frame(height: 44)

                ScrollView(showsIndicators: true) {
                    VStack(spacing: 0) {
                        debugPetStage
                        appearancePicker
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                        debugPanel
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.42), radius: 28, y: 14)
    }

    private var debugPetStage: some View {
        VStack(spacing: 5) {
            Spacer(minLength: 8)
            AnimatedStockPet(
                mood: mood,
                returnRate: displayReturn,
                isAlerting: alertPulse,
                isHovered: hoveringPet,
                appearance: selectedAppearance
            )
            .frame(width: 150, height: 150)
            .onHover { hoveringPet = $0 }
            Text(statusText).font(.system(size: 12)).foregroundStyle(.white.opacity(0.58))
            Text(percent(displayReturn))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(mood.color)
            Text("调节下方收益率，预览宠物状态和异动动作")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.32))
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, minHeight: 270)
    }

    private var expandedView: some View {
        GeometryReader { proxy in
            let usesPeekLayout = proxy.size.width < 660 || proxy.size.height < 500
            ZStack {
                LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.17), Color(red: 0.045, green: 0.05, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)

                VStack(spacing: 0) {
                    topBar(usesPeekLayout: usesPeekLayout)
                    if usesPeekLayout {
                        peekMarketDashboard
                    } else {
                        marketDashboard
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.42), radius: 28, y: 14)
    }

    private func topBar(usesPeekLayout: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(mood.color)
                .frame(width: 8, height: 8)
                .shadow(color: mood.color, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(usesPeekLayout ? "股票偷看" : "持仓行情")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                if !usesPeekLayout {
                    Text("\(store.positions.count) 只持仓 · 每 2 秒刷新")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.34))
                }
            }
            Spacer()
            if usesPeekLayout {
                toolbarIcon("plus", help: "添加股票", action: openPositionEditor)
                toolbarIcon("arrow.clockwise", help: "刷新行情") {
                    Task { await store.refreshMarketData() }
                }
            } else {
                Button(action: openPositionEditor) {
                    Label("添加股票", systemImage: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .foregroundStyle(.white)
                        .background(
                            LinearGradient(
                                colors: [gainColor, Color(red: 0.78, green: 0.08, blue: 0.13)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .shadow(color: gainColor.opacity(0.25), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                toolbarIcon("square.and.arrow.up", help: "晒收益", action: openShareCard)
                toolbarIcon("bag.fill", help: "宠物商城") { showingPetStore = true }
                toolbarIcon("ladybug.fill", help: "调试", action: openDebugPanel)
            }
            toolbarIcon("chevron.down", help: "收起") { toggleExpanded(false) }
            toolbarIcon("xmark", help: "收起到宠物", action: collapseToCompactPet)
        }
        .padding(.horizontal, usesPeekLayout ? 12 : 20)
        .frame(height: usesPeekLayout ? 46 : 54)
        .background(.black.opacity(0.08))
        .overlay(alignment: .bottom) {
            Divider().overlay(.white.opacity(0.055))
        }
    }

    private func toolbarIcon(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(.white.opacity(0.68))
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.055)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var displayedIndices: [MarketIndexSnapshot] {
        if !store.marketIndices.isEmpty { return store.marketIndices }
        return [
            MarketIndexSnapshot(id: "sh000001", name: "上证指数", price: 3955.58, change: 0, changePercent: 0),
            MarketIndexSnapshot(id: "sz399001", name: "深证成指", price: 14779.40, change: 0, changePercent: 0),
            MarketIndexSnapshot(id: "sz399006", name: "创业板指", price: 3804.70, change: 0, changePercent: 0),
            MarketIndexSnapshot(id: "sh000688", name: "科创50", price: 1924.27, change: 0, changePercent: 0),
            MarketIndexSnapshot(id: "sh000300", name: "沪深300", price: 4786.78, change: 0, changePercent: 0)
        ]
    }

    private var marketDashboard: some View {
        GeometryReader { proxy in
            let chartWidth = max(150, min(300, proxy.size.width * 0.28))
            let tableWidth = max(760, proxy.size.width)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("持仓总市值")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                        Text(currency(store.positions.reduce(0) { $0 + max(0, $1.value) }))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("今日收益率")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                        Text(percent(store.totalReturn))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(store.totalReturn >= 0 ? gainColor : lossColor)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(store.marketError ?? "主要指数与持仓分时")
                            .font(.system(size: 9))
                            .foregroundStyle(store.marketError == nil ? .white.opacity(0.36) : .orange.opacity(0.85))
                        Text(marketUpdateText)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    Button {
                        Task { await store.refreshMarketData() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isLoadingMarket)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(displayedIndices) { index in
                            indexCard(index)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(height: 92)

                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("名称 / 代码").frame(minWidth: 145, maxWidth: .infinity, alignment: .leading)
                            Text("最新价").frame(width: 84, alignment: .trailing)
                            Text("当日分时").frame(width: chartWidth, alignment: .leading)
                            Text("持仓市值").frame(width: 100, alignment: .trailing)
                            Text("当日涨跌").frame(width: 88, alignment: .trailing)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                        .padding(.horizontal, 20)
                        .frame(height: 36)
                        .background(.black.opacity(0.16))

                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(store.positions) { position in
                                    positionMarketRow(position, chartWidth: chartWidth)
                                    Divider().overlay(.white.opacity(0.06)).padding(.horizontal, 20)
                                }
                                if store.positions.isEmpty {
                                    VStack(spacing: 12) {
                                        Image(systemName: "chart.line.uptrend.xyaxis")
                                            .font(.system(size: 30, weight: .light))
                                            .foregroundStyle(gainColor.opacity(0.72))
                                        VStack(spacing: 4) {
                                            Text("还没有添加股票")
                                                .font(.system(size: 14, weight: .semibold))
                                    Text("搜索股票或 ETF 的名称、代码、拼音首字母")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.white.opacity(0.36))
                                        }
                                        Button(action: openPositionEditor) {
                                            Label("搜索股票", systemImage: "magnifyingglass")
                                                .font(.system(size: 10, weight: .semibold))
                                                .padding(.horizontal, 14)
                                                .frame(height: 30)
                                                .background(gainColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(gainColor.opacity(0.35)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 240)
                                }
                            }
                        }
                    }
                    .frame(width: tableWidth)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(.black.opacity(0.12))
    }

    private var peekMarketDashboard: some View {
        GeometryReader { proxy in
            let tableWidth = max(560, proxy.size.width)
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("持仓市值")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
                        Text(currency(store.positions.reduce(0) { $0 + max(0, $1.value) }))
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("今日收益")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
                        Text(percent(store.totalReturn))
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(store.totalReturn >= 0 ? gainColor : lossColor)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 66)
                .background(.black.opacity(0.08))

                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text("股票").frame(maxWidth: .infinity, alignment: .leading)
                            Text("分时").frame(width: 120, alignment: .leading)
                            Text("最新").frame(width: 68, alignment: .trailing)
                            Text("涨跌").frame(width: 68, alignment: .trailing)
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(.black.opacity(0.14))

                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(store.positions) { position in
                                    peekPositionRow(position, showsTrend: true)
                                    Divider().overlay(.white.opacity(0.055)).padding(.horizontal, 14)
                                }
                                if store.positions.isEmpty {
                                    Button(action: openPositionEditor) {
                                        Label("搜索并添加股票", systemImage: "magnifyingglass")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(gainColor)
                                            .frame(maxWidth: .infinity, minHeight: 92)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(width: tableWidth)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(.black.opacity(0.12))
    }

    private func peekPositionRow(_ position: Position, showsTrend: Bool) -> some View {
        let snapshot = store.positionMarkets[position.id]
        let change = snapshot?.changePercent ?? position.change
        let color = change >= 0 ? gainColor : lossColor
        let trend = snapshot?.trend ?? PetStore.fallbackTrend(seed: change)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(position.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(position.symbol?.uppercased() ?? "未设置代码")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsTrend {
                SparklineView(values: trend, color: color)
                    .frame(width: 120, height: 30)
            }

            Text(snapshot?.currentPrice.map(price) ?? "--")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .frame(width: 68, alignment: .trailing)

            Text(percent(change))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 68, height: 26)
                .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private func indexCard(_ index: MarketIndexSnapshot) -> some View {
        let color = index.changePercent >= 0 ? gainColor : lossColor
        return VStack(alignment: .leading, spacing: 5) {
            Text(index.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.62))
            Text(price(index.price)).font(.system(size: 16, weight: .bold, design: .rounded))
            Text("\(signedNumber(index.change))  \(percent(index.changePercent))")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(12)
        .frame(width: 150, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.2)))
    }

    private func positionMarketRow(_ position: Position, chartWidth: CGFloat) -> some View {
        let snapshot = store.positionMarkets[position.id]
        let change = snapshot?.changePercent ?? position.change
        let color = change >= 0 ? gainColor : lossColor
        let trend = snapshot?.trend ?? PetStore.fallbackTrend(seed: change)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(position.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(position.symbol?.uppercased() ?? "未设置代码")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.34))
                    Text(snapshot?.isLive == true ? "实时" : "回退")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(snapshot?.isLive == true ? .blue : .white.opacity(0.32))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.white.opacity(0.05), in: Capsule())
                }
            }
            .frame(minWidth: 145, maxWidth: .infinity, alignment: .leading)

            Text(snapshot?.currentPrice.map(price) ?? "--")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(width: 84, alignment: .trailing)

            SparklineView(values: trend, color: color)
                .frame(width: chartWidth, height: 54)

            Text(currency(position.value))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(width: 100, alignment: .trailing)

            Text(percent(change))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .padding(.horizontal, 9)
                .frame(width: 88, height: 30)
                .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 20)
        .frame(height: 82)
    }

    private var marketUpdateText: String {
        guard let date = store.marketUpdatedAt else { return store.isLoadingMarket ? "正在刷新…" : "等待行情" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss 更新"
        return formatter.string(from: date)
    }

    private func price(_ value: Double) -> String {
        value >= 10_000 ? String(format: "%.1f", value) : String(format: "%.2f", value)
    }

    private func signedNumber(_ value: Double) -> String {
        "\(value > 0 ? "+" : "")\(String(format: "%.2f", value))"
    }

    private func currency(_ value: Double) -> String {
        if value >= 100_000_000 { return String(format: "¥%.2f亿", value / 100_000_000) }
        if value >= 10_000 { return String(format: "¥%.2f万", value / 10_000) }
        return String(format: "¥%.0f", value)
    }

    private var petStage: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 5) {
                Spacer(minLength: 10)
                ZStack {
                    AnimatedStockPet(
                        mood: mood,
                        returnRate: displayReturn,
                        isAlerting: alertPulse,
                        isHovered: hoveringPet,
                        appearance: selectedAppearance
                    )
                    .frame(width: 150, height: 150)
                }
                .frame(width: 160, height: 150)
                .contentShape(Rectangle())
                .onHover { hoveringPet = $0 }

                Text(statusText).font(.system(size: 12)).foregroundStyle(.white.opacity(0.58))
                Text(percent(displayReturn))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(mood.color)
                if debugState.overrideEnabled {
                    Label("演示收益率锁定中", systemImage: "pin.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.14), in: Capsule())
                }
                Button {
                    openShareCard()
                } label: {
                    Label("晒收益", systemImage: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 5)
                        .background(mood.color.opacity(0.22), in: Capsule())
                        .overlay(Capsule().stroke(mood.color.opacity(0.55), lineWidth: 1))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("生成收益分享图")
                Text("把鼠标放到宠物身上看看")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.24))
                Spacer(minLength: 12)
            }

            if hoveringPet {
                positionsPopover
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(5)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 270)
        .animation(.easeOut(duration: 0.16), value: hoveringPet)
    }

    private var positionsPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("主要持仓").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("按市值排序").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
            }.padding(.bottom, 7)
            ForEach(Array(store.topPositions.enumerated()), id: \.element.id) { index, item in
                let change = store.todayChange(for: item)
                if index > 0 { Divider().overlay(.white.opacity(0.07)) }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 10, weight: .medium))
                        Text("市值 ¥\(Int(item.value))").font(.system(size: 8)).foregroundStyle(.white.opacity(0.32))
                    }
                    Spacer()
                    MiniBars(seed: change, color: change >= 0 ? gainColor : lossColor)
                        .frame(width: 66, height: 22)
                    Text(percent(change)).font(.system(size: 10, weight: .bold)).foregroundStyle(change >= 0 ? gainColor : lossColor).frame(width: 55, alignment: .trailing)
                }.padding(.vertical, 6)
            }
        }
        .padding(12)
        .background(popoverBackground.opacity(0.98), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.52), radius: 22, y: 10)
        .onHover { hoveringPet = $0 }
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            appearancePicker

            HStack(spacing: 9) {
                actionButton("▣  上传持仓截图") { importingScreenshot = true }
                actionButton("☷  编辑持仓") { store.showingEditor.toggle() }
            }

            if let image = store.screenshot {
                HStack(spacing: 9) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 42, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("截图已加载").font(.system(size: 10, weight: .semibold))
                        Text("当前版本请在下方确认数据").font(.system(size: 8)).foregroundStyle(.white.opacity(0.34))
                    }
                    Spacer()
                    Button("×") { store.screenshot = nil }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.35))
                }.padding(7).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }

            if store.showingEditor { editor }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("异动提醒").font(.system(size: 11, weight: .semibold))
                    Text("语音与系统弹窗").font(.system(size: 8)).foregroundStyle(.white.opacity(0.34))
                }
                Spacer()
                Toggle("", isOn: $store.notificationsEnabled).labelsHidden().toggleStyle(.switch).tint(.red)
            }.padding(.horizontal, 2)

            Button {
                store.testAlert(returnRate: displayReturn)
                triggerPetMotion()
            } label: {
                Text("模拟一次异动提醒").font(.system(size: 9)).foregroundStyle(.white.opacity(0.38)).frame(maxWidth: .infinity).padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [3])))
            }.buttonStyle(.plain)
        }
        .padding(14)
        .background(.black.opacity(0.18))
        .overlay(alignment: .top) { Divider().overlay(.white.opacity(0.07)) }
    }

    private var appearancePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("宠物外观").font(.system(size: 10, weight: .semibold))
                Spacer()
                Button("宠物商城") { showingPetStore = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(mood.color)
                Text(selectedAppearance.name).font(.system(size: 8)).foregroundStyle(.white.opacity(0.36))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(PetAppearance.availableCases) { appearance in
                        Button {
                            selectAppearance(appearance)
                        } label: {
                            VStack(spacing: 3) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(.white.opacity(selectedAppearance == appearance ? 0.12 : 0.045))
                                    appearanceThumbnail(appearance).padding(3)
                                }
                                .frame(height: 42)
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectedAppearance == appearance ? mood.color : .white.opacity(0.07), lineWidth: selectedAppearance == appearance ? 1.5 : 1))
                                Text(appearance.name)
                                    .font(.system(size: 8, weight: selectedAppearance == appearance ? .semibold : .regular))
                                    .foregroundStyle(selectedAppearance == appearance ? .white : .white.opacity(0.46))
                                    .lineLimit(1)
                            }
                            .frame(width: 54)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func appearanceThumbnail(_ appearance: PetAppearance) -> some View {
        if appearance == .robot {
            StockPetMascot(mood: .bull, returnRate: 2.2, blinking: false, actionActive: false)
        } else if let image = NSImage(named: NSImage.Name(appearance.previewName)) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        }
    }

    private var petStorePage: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("宠物商城").font(.system(size: 20, weight: .bold))
                    Text("挑一只喜欢的伙伴陪你看盘 · 当前全部免费").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingPetStore = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(20)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(PetAppearance.availableCases) { appearance in
                        VStack(spacing: 9) {
                            AnimatedStockPet(
                                mood: mood,
                                returnRate: displayReturn,
                                isAlerting: false,
                                isHovered: false,
                                appearance: appearance
                            )
                            .frame(height: 112)
                            Text(appearance.name).font(.system(size: 13, weight: .semibold))
                            Text(appearance.tagline).font(.system(size: 9)).foregroundStyle(.secondary)
                            Button(selectedAppearance == appearance ? "使用中" : "免费使用") {
                                selectAppearance(appearance)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(selectedAppearance == appearance ? .gray : mood.color)
                            .controlSize(.small)
                            .disabled(selectedAppearance == appearance)
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selectedAppearance == appearance ? mood.color.opacity(0.8) : .white.opacity(0.08)))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 440, height: 560)
        .background(Color(red: 0.045, green: 0.05, blue: 0.075))
        .preferredColorScheme(.dark)
    }

    private func selectAppearance(_ appearance: PetAppearance) {
        selectedAppearanceRaw = appearance.rawValue
        triggerPetMotion()
    }

    // MARK: - 晒收益分享卡

    private var shareCardPage: some View {
        VStack(spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("晒收益").font(.system(size: 20, weight: .bold))
                    Text("生成带宠物的收益卡片，复制后直接粘贴到微信、群聊").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingShareCard = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }

            shareCardContent
                .frame(width: 540, height: 660)
                .scaleEffect(0.52)
                .frame(width: 540 * 0.52, height: 660 * 0.52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.14)))

            Toggle(isOn: $shareIncludePositions) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("显示前三持仓").font(.system(size: 11, weight: .medium))
                    Text("默认隐私模式：只晒收益率，不晒持仓和金额").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(mood.color)

            HStack(spacing: 9) {
                Button {
                    copyShareCard()
                } label: {
                    Label("复制图片", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(mood.color)

                Button {
                    saveShareCard()
                } label: {
                    Label("保存 PNG", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }

            Text(shareFeedback.isEmpty ? " " : shareFeedback)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(mood.color)
        }
        .padding(18)
        .frame(width: 356)
        .background(Color(red: 0.045, green: 0.05, blue: 0.075))
        .preferredColorScheme(.dark)
    }

    private var shareCardContent: ShareCardView {
        ShareCardView(
            returnRate: displayReturn,
            mood: mood,
            appearance: selectedAppearance,
            positions: shareIncludePositions ? store.topPositions.map { position in
                var updated = position
                updated.change = store.todayChange(for: position)
                return updated
            } : [],
            date: Date()
        )
    }

    private func openShareCard() {
        shareFeedback = ""
        showingShareCard = true
    }

    @MainActor
    private func renderShareImage() -> NSImage? {
        let renderer = ImageRenderer(content: shareCardContent.frame(width: 540, height: 660))
        renderer.scale = 2
        return renderer.nsImage
    }

    @MainActor
    private func copyShareCard() {
        guard let image = renderShareImage() else {
            shareFeedback = "生成图片失败"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        shareFeedback = "已复制，去微信/群聊里直接粘贴吧"
    }

    @MainActor
    private func saveShareCard() {
        guard let image = renderShareImage(),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            shareFeedback = "生成图片失败"
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("持仓宠物-晒收益-\(formatter.string(from: Date())).png")
        do {
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            shareFeedback = "已保存到「下载」文件夹"
        } catch {
            shareFeedback = "保存失败：\(error.localizedDescription)"
        }
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("素材调试", systemImage: "ladybug.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(selectedAppearance.name)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.58))
            }

            Text("选择上方宠物素材后，在这里预览不同收益状态和动作。")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.52))

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("总收益率")
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    TextField("收益率", value: mockReturnBinding, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                    Text("%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Slider(value: mockReturnBinding, in: -10...10, step: 0.1)
                    .tint(mood.color)
                HStack(spacing: 5) {
                    ForEach([-10.0, -5.0, 0.0, 5.0, 10.0], id: \.self) { rate in
                        Button(percent(rate)) {
                            debugState.mockReturnRate = rate
                            debugState.isMockingReturn = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("动画播放速度")
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    Text("×\(String(format: "%.2f", debugState.speedMultiplier))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(debugState.speedMultiplier == 1.0 ? .secondary : Color.orange)
                }
                Slider(value: speedMultiplierBinding, in: 0.25...3.0, step: 0.05)
                    .tint(mood.color)
                HStack(spacing: 5) {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { multiplier in
                        Button("×\(multiplier == 1.0 ? "1" : String(format: "%.1f", multiplier))") {
                            debugState.speedMultiplier = multiplier
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                    Text("对所有卡通宠物生效，自动保存")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.38))
                }
            }

            Button {
                debugState.isMockingReturn = true
                store.testAlert(returnRate: debugState.mockReturnRate)
                debugState.actionToken = UUID()
                triggerPetMotion()
            } label: {
                Label("播放调试动作", systemImage: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(mood.color)

            Button {
                debugState.overrideValue = debugState.mockReturnRate
                debugState.overrideEnabled = true
            } label: {
                Label(
                    debugState.overrideEnabled
                        ? "已锁定 \(percent(debugState.overrideValue)) · 点击更新为当前值"
                        : "锁定当前收益率（覆盖真实数据）",
                    systemImage: debugState.overrideEnabled ? "pin.fill" : "pin"
                )
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(debugState.overrideEnabled ? .orange : mood.color)
            .help("锁定后关闭调试窗口、重启应用都会保持这个收益率，直到手动恢复")

            Button(debugState.overrideEnabled ? "解除锁定，恢复真实收益率" : "恢复真实收益率") {
                debugState.overrideEnabled = false
                debugState.isMockingReturn = false
                debugState.mockReturnRate = store.totalReturn
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(mood.color.opacity(0.48), lineWidth: 1)
        )
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(gainColor.opacity(0.16))
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(gainColor)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("管理持仓")
                        .font(.system(size: 16, weight: .bold))
                    Text("搜索股票或 ETF 并补充持仓市值，名称和证券代码会自动填写")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.38))
                }
                Spacer()
                Button {
                    store.showingEditor = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .frame(height: 66)

            Divider().overlay(.white.opacity(0.07))

            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(stockSearchFocused ? gainColor : .white.opacity(0.36))
                        TextField("搜索股票或 ETF，例如：纳指 / 513100 / ndq", text: $stockSearchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .focused($stockSearchFocused)
                            .onSubmit {
                                stockSearchTask?.cancel()
                                stockSearchTask = Task { await store.searchStocks(stockSearchQuery) }
                            }
                        if store.isSearchingStocks {
                            ProgressView().controlSize(.small)
                        } else if !stockSearchQuery.isEmpty {
                            Button {
                                stockSearchQuery = ""
                                store.clearStockSearch()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white.opacity(0.28))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(stockSearchFocused ? gainColor.opacity(0.55) : .white.opacity(0.08))
                    )

                    if !stockSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stockSearchResultsPanel
                            .padding(.top, 8)
                    }
                }

                HStack {
                    Text("当前持仓")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(store.positions.count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(gainColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(gainColor.opacity(0.13), in: Capsule())
                    Spacer()
                    Button {
                        store.addManualPosition()
                    } label: {
                        Label("手动添加", systemImage: "plus")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.46))
                    }
                    .buttonStyle(.plain)
                    .help("搜索不到时手动填写")
                }
                .frame(height: 24)

                HStack(spacing: 10) {
                    Text("股票 / 证券代码").frame(maxWidth: .infinity, alignment: .leading)
                    Text("持仓市值").frame(width: 105, alignment: .leading)
                    Text("备用收益率").frame(width: 90, alignment: .leading)
                    Color.clear.frame(width: 28)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
                .padding(.horizontal, 10)
                .frame(height: 18)

                GeometryReader { listGeometry in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach($store.positions) { $item in
                                HStack(spacing: 10) {
                                    VStack(spacing: 5) {
                                        TextField("股票名称", text: $item.name)
                                            .textFieldStyle(PetField())
                                        TextField("如 sh600519", text: Binding(
                                            get: { item.symbol ?? "" },
                                            set: { item.symbol = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                        ))
                                        .textFieldStyle(PetField())
                                        .font(.system(size: 9, design: .monospaced))
                                    }
                                    .frame(maxWidth: .infinity)

                                    TextField("市值", value: $item.value, format: .number)
                                        .textFieldStyle(PetField())
                                        .frame(width: 105)
                                    TextField("收益%", value: $item.change, format: .number.precision(.fractionLength(0...2)))
                                        .textFieldStyle(PetField())
                                        .frame(width: 90)
                                    Button {
                                        withAnimation(.easeOut(duration: 0.18)) {
                                            store.removePosition(id: item.id)
                                        }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.28))
                                            .frame(width: 28, height: 28)
                                            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                                    }
                                    .buttonStyle(.plain)
                                    .help("删除持仓")
                                }
                                .padding(10)
                                .background(.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.055)))
                            }

                            if store.positions.isEmpty {
                                VStack(spacing: 6) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.white.opacity(0.2))
                                    Text("从上方搜索并添加第一只股票")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.34))
                                }
                                .frame(maxWidth: .infinity, minHeight: 120)
                            }
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: listGeometry.size.height,
                            alignment: .top
                        )
                        .padding(.vertical, 1)
                    }
                }
                .frame(
                    height: stockSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? 285
                        : 158,
                    alignment: .top
                )

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider().overlay(.white.opacity(0.07))

            HStack {
                Label("搜索结果来自公开行情服务，数据仅保存在本机", systemImage: "lock")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.28))
                Spacer()
                Button {
                    store.save()
                    store.showingEditor = false
                    Task { await store.refreshMarketData() }
                } label: {
                    Label("保存并刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 15)
                        .frame(height: 32)
                        .background(gainColor.opacity(0.88), in: RoundedRectangle(cornerRadius: 9))
                        .shadow(color: gainColor.opacity(0.2), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
        }
        .onAppear {
            stockSearchQuery = ""
            store.clearStockSearch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                stockSearchFocused = true
            }
        }
        .onChange(of: stockSearchQuery) { _, newValue in
            scheduleStockSearch(newValue)
        }
        .onDisappear {
            stockSearchTask?.cancel()
            stockSearchTask = nil
            store.clearStockSearch()
            store.save()
        }
    }

    private var stockSearchResultsPanel: some View {
        VStack(spacing: 0) {
            if let error = store.stockSearchError, store.stockSearchResults.isEmpty, !store.isSearchingStocks {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error)
                    Spacer()
                }
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.82))
                .padding(12)
            } else if store.isSearchingStocks && store.stockSearchResults.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在查找匹配股票…")
                    Spacer()
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.42))
                .padding(12)
            } else if store.stockSearchResults.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("没有找到匹配的股票或 ETF，试试证券代码或拼音首字母")
                    Spacer()
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.38))
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.stockSearchResults.enumerated()), id: \.element.id) { index, result in
                            stockSearchResultRow(result)
                            if index < store.stockSearchResults.count - 1 {
                                Divider().overlay(.white.opacity(0.055)).padding(.horizontal, 10)
                            }
                        }
                    }
                }
                .frame(maxHeight: 132)
            }
        }
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.07)))
    }

    private func stockSearchResultRow(_ result: StockSearchResult) -> some View {
        let isAdded = store.positions.contains { $0.symbol?.lowercased() == result.symbol.lowercased() }
        return Button {
            guard !isAdded else { return }
            store.addStock(result)
            stockSearchQuery = ""
            store.clearStockSearch()
            stockSearchFocused = true
        } label: {
            HStack(spacing: 10) {
                Text(result.instrumentName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(gainColor)
                    .frame(width: 36, height: 22)
                    .background(gainColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    Text("\(result.symbol.uppercased()) · \(result.marketName)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                }
                Spacer()
                Label(isAdded ? "已添加" : "加入持仓", systemImage: isAdded ? "checkmark" : "plus")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isAdded ? .white.opacity(0.28) : gainColor)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
    }

    private func openPositionEditor() {
        stockSearchQuery = ""
        store.clearStockSearch()
        store.showingEditor = true
    }

    private func scheduleStockSearch(_ query: String) {
        stockSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            store.clearStockSearch()
            return
        }
        stockSearchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 280_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await store.searchStocks(trimmed)
        }
    }

    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10)).frame(maxWidth: .infinity).frame(height: 34).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }

    private func percent(_ value: Double) -> String {
        "\(value > 0 ? "+" : "")\(String(format: "%.2f", value))%"
    }

    private func relativeTime(_ date: Date) -> String {
        guard date != .distantPast else { return "刚刚" }
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60)))分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))小时前" }
        return "\(Int(seconds / 86_400))天前"
    }

    private func triggerPetMotion() {
        let token = UUID()
        motionToken = token
        alertPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            guard motionToken == token else { return }
            alertPulse = false
        }
    }

    private func openDebugPanel() {
        if !debugState.isMockingReturn {
            debugState.mockReturnRate = store.totalReturn
            debugState.isMockingReturn = true
        }
        openWindow(id: "pet-debug")
    }

    private func closeDebugPanel() {
        resetDebugState()
        dismissWindow(id: "pet-debug")
    }

    private func resetDebugState() {
        debugState.isMockingReturn = false
        debugState.mockReturnRate = store.totalReturn
    }

    private func resizeCompactWindowForReturn(animated: Bool = true) {
        guard !isExpanded,
              let window = mainPetWindow else { return }

        let oldFrame = window.frame
        let newSize = compactWindowSize
        let visible = visibleFrame(for: window, fallback: oldFrame)
        let target = clampedFrame(size: newSize, centeredAt: NSPoint(x: oldFrame.midX, y: oldFrame.midY), in: visible)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(target, display: true)
            }
        } else {
            window.setFrame(target, display: true)
        }
    }

    private func toggleExpanded(_ expanded: Bool) {
        guard let window = mainPetWindow else {
            isExpanded = expanded
            return
        }

        let oldFrame = window.frame
        var newSize: NSSize
        var target: NSRect
        if expanded {
            compactWindowFrameBeforeExpansion = oldFrame
            newSize = savedExpandedWindowSize
            let visible = visibleFrame(for: window, fallback: oldFrame)
            newSize.width = min(newSize.width, visible.width)
            newSize.height = min(newSize.height, visible.height)
            target = centeredFrame(size: newSize, in: visible)
        } else {
            persistExpandedWindowSize()
            newSize = compactWindowSize
            let restoreFrame = compactWindowFrameBeforeExpansion ?? oldFrame
            let visible = visibleFrame(for: window, fallback: restoreFrame)
            target = clampedFrame(
                size: newSize,
                centeredAt: NSPoint(x: restoreFrame.midX, y: restoreFrame.midY),
                in: visible
            )
            compactWindowFrameBeforeExpansion = nil
        }

        isExpanded = expanded
        window.hasShadow = expanded
        window.styleMask.remove(.resizable)
        if expanded {
            window.contentMinSize = expandedWindowMinimumSize
            window.contentMaxSize = expandedWindowMaximumSize
        } else {
            window.contentMinSize = newSize
            window.contentMaxSize = newSize
        }
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = expanded ? 22 : 0
        window.contentView?.layer?.masksToBounds = expanded
        // 重新确认悬浮层级和跨桌面展示（SwiftUI 有时会把窗口配置重置回普通层级）。
        configureMainPetWindowPresentation(window)
        if expanded {
            window.orderFrontRegardless()
            NSApp.activate()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        }
    }

    private func visibleFrame(for window: NSWindow, fallback: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? fallback
    }

    private func centeredFrame(size: NSSize, in visible: NSRect) -> NSRect {
        clampedFrame(
            size: size,
            centeredAt: NSPoint(x: visible.midX, y: visible.midY),
            in: visible
        )
    }

    private func clampedFrame(size: NSSize, centeredAt center: NSPoint, in visible: NSRect) -> NSRect {
        var origin = NSPoint(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2
        )
        origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
        origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    private var savedExpandedWindowSize: NSSize {
        let defaults = UserDefaults.standard
        let savedWidth = defaults.double(forKey: expandedWindowWidthKey)
        let savedHeight = defaults.double(forKey: expandedWindowHeightKey)
        let width = savedWidth > 0 ? savedWidth : 980
        let height = savedHeight > 0 ? savedHeight : 700
        return NSSize(
            width: min(max(width, expandedWindowMinimumSize.width), expandedWindowMaximumSize.width),
            height: min(max(height, expandedWindowMinimumSize.height), expandedWindowMaximumSize.height)
        )
    }

    private func persistExpandedWindowSize() {
        guard isExpanded, let window = mainPetWindow else { return }
        let size = window.frame.size
        guard size.width >= expandedWindowMinimumSize.width,
              size.height >= expandedWindowMinimumSize.height else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(size.width), forKey: expandedWindowWidthKey)
        defaults.set(Double(size.height), forKey: expandedWindowHeightKey)
    }

    private func collapseToCompactPet() {
        toggleExpanded(false)
    }

    private var mainPetWindow: NSWindow? {
        NSApplication.shared.windows.first(where: { $0.title == mainPetWindowTitle })
    }
}

struct PetField: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 9))
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.07)))
    }
}

struct SparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let points = normalizedPoints(in: proxy.size)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
                }
                .stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))

                if let last = points.last {
                    Circle().fill(color).frame(width: 5, height: 5).position(last)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1,
              let minimum = values.min(), let maximum = values.max() else { return [] }
        let span = max(0.0001, maximum - minimum)
        return values.enumerated().map { index, value in
            let x = CGFloat(index) / CGFloat(values.count - 1) * size.width
            let y = size.height - CGFloat((value - minimum) / span) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}

struct MiniBars: View {
    let seed: Double
    let color: Color

    var values: [CGFloat] {
        (0..<12).map { index in CGFloat(5 + (abs(Int(seed * 17)) * 13 + index * 7 + index * index) % 17) }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 1).fill(color.opacity(0.72)).frame(height: value)
            }
        }
    }
}

enum BullHappiness: Int, Equatable {
    case normal, smiling, happy, ecstatic

    init(returnRate: Double) {
        if returnRate >= 5 { self = .ecstatic }
        else if returnRate >= 2 { self = .happy }
        else if returnRate >= 1 { self = .smiling }
        else { self = .normal }
    }
}

struct AnimatedStockPet: View {
    let mood: PetMood
    let returnRate: Double
    let isAlerting: Bool
    let isHovered: Bool
    let appearance: PetAppearance

    @State private var hoverStartedAt = Date.distantPast
    @State private var alertStartedAt = Date.distantPast

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let side = min(proxy.size.width, proxy.size.height)
                let positiveReturn = max(0, returnRate)
                let happinessStrength = min(1, positiveReturn / 5)

                let hoverElapsed = time - hoverStartedAt.timeIntervalSinceReferenceDate
                let hoverDuration = 0.82
                let hoverActive = mood == .bull && hoverElapsed >= 0 && hoverElapsed <= hoverDuration
                let hoverProgress = min(1, max(0, hoverElapsed / hoverDuration))
                let hoverHeight = hoverActive
                    ? CGFloat(sin(hoverProgress * .pi)) * side * CGFloat(0.08 + happinessStrength * 0.15)
                    : 0

                let alertElapsed = time - alertStartedAt.timeIntervalSinceReferenceDate
                let alertDuration = 0.95
                let alertActive = mood == .bull && isAlerting && alertElapsed >= 0 && alertElapsed <= alertDuration
                let alertProgress = min(1, max(0, alertElapsed / alertDuration))
                let alertHeight = alertActive
                    ? CGFloat(sin(alertProgress * .pi)) * side * CGFloat(0.10 + happinessStrength * 0.14)
                    : 0

                let repeatInterval = max(7.0, 12.6 - happinessStrength * 5.4)
                let automaticElapsed = time.truncatingRemainder(dividingBy: repeatInterval)
                let automaticDuration = 0.72
                let automaticActive = mood == .bull && positiveReturn >= 2 && automaticElapsed < automaticDuration
                let automaticProgress = min(1, automaticElapsed / automaticDuration)
                let automaticHeight = automaticActive
                    ? CGFloat(sin(automaticProgress * .pi)) * side * CGFloat(0.025 + happinessStrength * 0.07)
                    : 0

                let jumpHeight = max(hoverHeight, alertHeight, automaticHeight)
                let floatFrequency = 0.8 + happinessStrength * 0.4
                let floatAmplitude = side * CGFloat(0.006 + happinessStrength * 0.024)
                let idleLift = CGFloat(sin(time * floatFrequency)) * floatAmplitude
                let bullActionActive = hoverActive || alertActive || automaticActive

                let bearActionWindow = time.truncatingRemainder(dividingBy: 3.2) < 1.05
                let bearActionActive = mood == .bear && (isAlerting || returnRate <= -3) && bearActionWindow
                let shake = bearActionActive ? CGFloat(sin(time * 10)) * side * 0.014 : 0

                let breathAmount = mood == .bull
                    ? 0.008 + happinessStrength * 0.018
                    : 0.012
                let breath = 1 + CGFloat(sin(time * floatFrequency)) * CGFloat(breathAmount)
                ZStack {
                    Ellipse()
                        .fill(.black.opacity(0.26 - min(0.13, Double(jumpHeight / max(1, side)))))
                        .frame(width: side * (0.55 - jumpHeight / max(1, side) * 0.5), height: side * 0.11)
                        .blur(radius: side * 0.025)
                        .offset(y: side * 0.405)

                    Group {
                        if appearance == .robot {
                            StockPetMascot(
                                mood: mood,
                                returnRate: returnRate,
                                blinking: time.truncatingRemainder(dividingBy: 4.1) > 3.88,
                                actionActive: bullActionActive || bearActionActive
                            )
                        } else {
                            OpenPetsMascot(
                                mood: mood,
                                returnRate: returnRate,
                                time: time,
                                actionActive: bullActionActive || bearActionActive,
                                appearance: appearance
                            )
                        }
                    }
                    .scaleEffect(x: breath, y: 2 - breath, anchor: .bottom)
                    .offset(x: shake, y: idleLift - jumpHeight)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .onChange(of: isHovered) { wasHovered, hovering in
            guard hovering && !wasHovered else { return }
            hoverStartedAt = Date()
        }
        .onChange(of: isAlerting) { wasAlerting, alerting in
            guard alerting && !wasAlerting else { return }
            alertStartedAt = Date()
        }
        .accessibilityHidden(true)
    }
}

struct OpenPetsMascot: View {
    let mood: PetMood
    let returnRate: Double
    let time: TimeInterval
    let actionActive: Bool
    let appearance: PetAppearance

    private func frameIndex(count: Int, speed rawSpeed: Double, pingPong: Bool = false) -> Int {
        let speed = rawSpeed * PetAnimTuning.speedMultiplier
        guard count > 1 else { return 0 }
        let tick = max(0, Int(time * speed))
        guard pingPong else { return tick % count }
        let cycle = (count - 1) * 2
        let position = tick % cycle
        return position < count ? position : cycle - position
    }

    private func skinFrame(
        _ skin: String,
        state: String,
        count: Int,
        speed: Double,
        pingPong: Bool = false
    ) -> String {
        "skin_\(skin)_\(state)_\(frameIndex(count: count, speed: speed, pingPong: pingPong))"
    }

    private var mechFrameName: String {
        if actionActive {
            return mood == .bull
                ? skinFrame("mech", state: "attack", count: 8, speed: 4.0, pingPong: true)
                : skinFrame("mech", state: "crash", count: 10, speed: 3.3, pingPong: true)
        }
        if returnRate >= 5 {
            return skinFrame("mech", state: "shoot", count: 4, speed: 3.0, pingPong: true)
        }
        if returnRate >= 2 {
            return skinFrame("mech", state: "happy", count: 10, speed: 3.3, pingPong: true)
        }
        if returnRate >= 0.5 {
            return skinFrame("mech", state: "run", count: 8, speed: 4.0)
        }
        if returnRate >= -0.5 {
            return skinFrame("mech", state: "idle", count: 10, speed: 2.3)
        }
        if returnRate >= -2 {
            return skinFrame("mech", state: "sad", count: 10, speed: 3.0, pingPong: true)
        }
        return skinFrame("mech", state: "crash", count: 10, speed: 2.7, pingPong: true)
    }

    private var polarFrameName: String {
        if actionActive {
            return mood == .bull
                ? skinFrame("polar", state: "attack", count: 8, speed: 3.7, pingPong: true)
                : skinFrame("polar", state: "hurt", count: 6, speed: 3.7, pingPong: true)
        }
        if returnRate >= 5 {
            return skinFrame("polar", state: "jump", count: 10, speed: 3.3)
        }
        if returnRate >= 2 {
            return skinFrame("polar", state: "run", count: 10, speed: 4.0)
        }
        if returnRate >= 0.5 {
            return skinFrame("polar", state: "happy", count: 12, speed: 3.3)
        }
        if returnRate >= -0.5 {
            return skinFrame("polar", state: "idle", count: 12, speed: 2.3)
        }
        if returnRate >= -1.5 {
            return skinFrame("polar", state: "hurt", count: 6, speed: 3.0, pingPong: true)
        }
        if returnRate >= -4 {
            return skinFrame("polar", state: "sad", count: 10, speed: 3.0)
        }
        return skinFrame("polar", state: "crash", count: 10, speed: 2.3, pingPong: true)
    }

    private var frameName: String {
        let isBull = mood == .bull
        let isExpressive = isBull
            ? (actionActive || returnRate >= 1)
            : (actionActive || returnRate <= -0.5)
        // 舒缓节奏：整体放慢 3 倍；可在调试面板全局调速
        let speed = (actionActive ? 3.4 : 2.4) * PetAnimTuning.speedMultiplier

        if appearance == .mech { return mechFrameName }
        if appearance == .polar { return polarFrameName }

        if let spec = appearance.skinSpec {
            let state = isBull
                ? (isExpressive ? "happy" : "idle")
                : (isExpressive ? "sad" : "idle")
            let count: Int
            switch state {
            case "happy": count = spec.happyFrames
            case "sad": count = spec.sadFrames
            default: count = spec.idleFrames
            }
            return "skin_\(appearance.rawValue)_\(state)_\(Int(time * speed) % max(1, count))"
        }

        let frame = Int(time * speed) % 4
        if isBull {
            return "cow_\(isExpressive ? "happy" : "idle")_\(frame)"
        }
        return "bear_\(isExpressive ? "sad" : "idle")_\(frame)"
    }

    /// 皮肤当前帧：情绪表情与自然(idle)表情交替，逐帧硬切。
    /// 涨时 happy→idle→happy… 、跌时 sad→idle→sad… 循环；每个情绪片段只播一遍。
    /// 不做交叉淡入——卡通逐帧素材本来就该硬切，混合会拖影显得不自然。
    private var currentSkinFrame: String? {
        guard appearance != .mech, appearance != .polar, let spec = appearance.skinSpec else { return nil }
        let isBull = mood == .bull
        let isExpressive = isBull
            ? (actionActive || returnRate >= 1)
            : (actionActive || returnRate <= -0.5)
        // 贴近作者调好的节奏：约 4fps，异动时略快
        let fps = (actionActive ? 5.5 : 4.0) * PetAnimTuning.speedMultiplier

        let sequence: [String]
        if !isExpressive {
            sequence = ["idle"]
        } else if isBull {
            sequence = ["happy", "idle"]
        } else {
            sequence = ["sad", "idle"]
        }

        func frames(_ state: String) -> Int {
            switch state {
            case "happy": return spec.happyFrames
            case "sad": return spec.sadFrames
            default: return spec.idleFrames
            }
        }
        let counts = sequence.map(frames)
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }

        let tick = Int(time * fps) % total
        var acc = 0, seg = 0, local = tick
        for (i, c) in counts.enumerated() {
            if tick < acc + c { seg = i; local = tick - acc; break }
            acc += c
        }
        return "skin_\(appearance.rawValue)_\(sequence[seg])_\(local)"
    }

    var body: some View {
        Group {
            if let frame = currentSkinFrame,
               let image = NSImage(named: NSImage.Name(frame)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if let assetName = appearance.assetName,
               let image = NSImage(named: NSImage.Name(assetName)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if let image = NSImage(named: NSImage.Name(frameName)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: mood == .bull ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(mood.color)
                    .padding(22)
            }
        }
        .scaleEffect(actionActive ? 1.035 : 1)
        .shadow(color: .black.opacity(0.13), radius: 3, y: 2)
    }
}

struct StockPetMascot: View {
    let mood: PetMood
    let returnRate: Double
    let blinking: Bool
    let actionActive: Bool

    private var baseColor: Color { mood.color }
    private var darkColor: Color {
        mood == .bull
            ? Color(red: 0.56, green: 0.035, blue: 0.06)
            : Color(red: 0.025, green: 0.35, blue: 0.19)
    }
    private let outline = Color(red: 0.035, green: 0.06, blue: 0.13)
    private let face = Color(red: 0.025, green: 0.10, blue: 0.16)
    private let glow = Color(red: 0.42, green: 0.96, blue: 1.0)
    private var bullHappiness: BullHappiness { BullHappiness(returnRate: returnRate) }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let line = max(2, side * 0.025)

            ZStack {
                mascotBody(side: side, line: line)
                mascotHead(side: side, line: line)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func mascotBody(side: CGFloat, line: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.09, style: .continuous)
                .fill(LinearGradient(colors: [baseColor, darkColor], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: side * 0.09).stroke(outline, lineWidth: line))
                .frame(width: side * 0.43, height: side * 0.34)
                .offset(y: side * 0.245)

            ForEach([-1.0, 1.0], id: \.self) { direction in
                Capsule()
                    .fill(baseColor)
                    .overlay(Capsule().stroke(outline, lineWidth: line))
                    .frame(width: side * 0.13, height: side * 0.27)
                    .rotationEffect(.degrees(direction * (mood == .bull && actionActive ? 42 : 15)))
                    .offset(x: CGFloat(direction) * side * 0.255, y: side * (mood == .bull && actionActive ? 0.11 : 0.20))

                RoundedRectangle(cornerRadius: side * 0.04)
                    .fill(darkColor)
                    .overlay(RoundedRectangle(cornerRadius: side * 0.04).stroke(outline, lineWidth: line))
                    .frame(width: side * 0.14, height: side * 0.17)
                    .offset(x: CGFloat(direction) * side * 0.115, y: side * 0.395)
            }

            Image(systemName: mood == .bull ? "arrow.up" : "arrow.down")
                .font(.system(size: side * 0.17, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: glow.opacity(0.8), radius: side * 0.025)
                .offset(y: side * 0.245)
        }
    }

    @ViewBuilder
    private func mascotHead(side: CGFloat, line: CGFloat) -> some View {
        ZStack {
            if mood == .bull {
                ForEach([-1.0, 1.0], id: \.self) { direction in
                    Capsule()
                        .fill(Color(red: 1.0, green: 0.83, blue: 0.52))
                        .overlay(Capsule().stroke(outline, lineWidth: line))
                        .frame(width: side * 0.115, height: side * 0.24)
                        .rotationEffect(.degrees(direction * 24))
                        .offset(x: CGFloat(direction) * side * 0.255, y: -side * 0.31)
                }
            } else {
                ForEach([-1.0, 1.0], id: \.self) { direction in
                    Circle()
                        .fill(baseColor)
                        .overlay(Circle().stroke(outline, lineWidth: line))
                        .overlay(Circle().fill(darkColor).padding(side * 0.045))
                        .frame(width: side * 0.25, height: side * 0.25)
                        .offset(x: CGFloat(direction) * side * 0.285, y: -side * 0.265)
                }
            }

            RoundedRectangle(cornerRadius: side * 0.17, style: .continuous)
                .fill(LinearGradient(colors: [baseColor.opacity(0.98), darkColor], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: side * 0.17).stroke(outline, lineWidth: line))
                .frame(width: side * 0.72, height: side * 0.53)
                .offset(y: -side * 0.07)

            RoundedRectangle(cornerRadius: side * 0.105, style: .continuous)
                .fill(face)
                .overlay(RoundedRectangle(cornerRadius: side * 0.105).stroke(outline.opacity(0.9), lineWidth: line))
                .frame(width: side * 0.53, height: side * 0.32)
                .offset(y: -side * 0.055)

            petFace(side: side)

            if mood == .bull && bullHappiness.rawValue >= BullHappiness.happy.rawValue {
                ForEach([-1.0, 1.0], id: \.self) { direction in
                    Image(systemName: bullHappiness == .ecstatic ? "sparkles" : "sparkle")
                        .font(.system(size: side * (bullHappiness == .ecstatic ? 0.105 : 0.075), weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.22))
                        .shadow(color: .orange.opacity(0.7), radius: side * 0.025)
                        .rotationEffect(.degrees(direction * 12))
                        .offset(x: CGFloat(direction) * side * 0.405, y: -side * 0.10)
                }
            }
        }
    }

    @ViewBuilder
    private func petFace(side: CGFloat) -> some View {
        if mood == .bull {
            bullFace(side: side)
        } else {
            bearFace(side: side)
        }
    }

    @ViewBuilder
    private func bullFace(side: CGFloat) -> some View {
        ZStack {
            if blinking {
                HStack(spacing: side * 0.12) {
                    Capsule().fill(glow).frame(width: side * 0.085, height: side * 0.022)
                    Capsule().fill(glow).frame(width: side * 0.085, height: side * 0.022)
                }
                .offset(y: -side * 0.095)
            } else {
                switch bullHappiness {
                case .normal:
                    HStack(spacing: side * 0.14) {
                        Circle().fill(glow).frame(width: side * 0.055, height: side * 0.055)
                        Circle().fill(glow).frame(width: side * 0.055, height: side * 0.055)
                    }
                    .offset(y: -side * 0.095)
                case .smiling:
                    HStack(spacing: side * 0.13) {
                        Capsule().fill(glow).frame(width: side * 0.045, height: side * 0.075).rotationEffect(.degrees(-8))
                        Capsule().fill(glow).frame(width: side * 0.045, height: side * 0.075).rotationEffect(.degrees(8))
                    }
                    .offset(y: -side * 0.095)
                case .happy:
                    HStack(spacing: side * 0.085) {
                        Image(systemName: "chevron.up")
                        Image(systemName: "chevron.up")
                    }
                    .font(.system(size: side * 0.115, weight: .black))
                    .foregroundStyle(glow)
                    .offset(y: -side * 0.10)
                case .ecstatic:
                    HStack(spacing: side * 0.075) {
                        Text("$")
                        Text("$")
                    }
                    .font(.system(size: side * 0.13, weight: .black, design: .monospaced))
                    .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.20))
                    .shadow(color: .orange.opacity(0.9), radius: side * 0.025)
                    .offset(y: -side * 0.10)
                }
            }

            bullMuzzle(side: side)

            switch bullHappiness {
            case .normal:
                EmptyView()
            case .smiling:
                SmileArc()
                    .stroke(glow, style: StrokeStyle(lineWidth: max(2, side * 0.018), lineCap: .round))
                    .frame(width: side * 0.10, height: side * 0.045)
                    .offset(y: side * 0.085)
            case .happy:
                Capsule()
                    .fill(Color(red: 1.0, green: 0.43, blue: 0.50))
                    .frame(width: side * 0.11, height: side * 0.035)
                    .offset(y: side * 0.088)
            case .ecstatic:
                RoundedRectangle(cornerRadius: side * 0.025)
                    .fill(Color(red: 0.56, green: 0.02, blue: 0.10))
                    .frame(width: side * 0.15, height: side * 0.06)
                    .overlay(
                        Capsule()
                            .fill(Color(red: 1.0, green: 0.42, blue: 0.50))
                            .frame(width: side * 0.085, height: side * 0.022)
                            .offset(y: side * 0.012)
                    )
                    .offset(y: side * 0.088)
            }
        }
    }

    private func bullMuzzle(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: side * 0.035)
            .fill(Color(red: 1.0, green: 0.72, blue: 0.29))
            .frame(width: side * 0.18, height: side * 0.078)
            .overlay(HStack(spacing: side * 0.055) {
                Circle().fill(darkColor).frame(width: side * 0.022)
                Circle().fill(darkColor).frame(width: side * 0.022)
            })
            .offset(y: side * 0.018)
    }

    @ViewBuilder
    private func bearFace(side: CGFloat) -> some View {
        if blinking {
            HStack(spacing: side * 0.12) {
                Capsule().fill(glow).frame(width: side * 0.105, height: side * 0.025)
                Capsule().fill(glow).frame(width: side * 0.105, height: side * 0.025)
            }
            .offset(y: -side * 0.08)
        } else {
            HStack(spacing: side * 0.13) {
                Capsule().fill(glow).frame(width: side * 0.06, height: side * 0.10).rotationEffect(.degrees(-12))
                Capsule().fill(glow).frame(width: side * 0.06, height: side * 0.10).rotationEffect(.degrees(12))
            }
            .offset(y: -side * 0.085)

            Image(systemName: "chevron.up")
                .font(.system(size: side * 0.07, weight: .black))
                .foregroundStyle(glow)
                .offset(y: side * 0.04)

            Image(systemName: "drop.fill")
                .font(.system(size: side * 0.105, weight: .bold))
                .foregroundStyle(glow)
                .offset(x: side * 0.275, y: -side * 0.155)
        }
    }
}

struct ShareCardView: View {
    let returnRate: Double
    let mood: PetMood
    let appearance: PetAppearance
    let positions: [Position]
    let date: Date

    private let gainColor = Color(red: 1.0, green: 0.30, blue: 0.32)
    private let lossColor = Color(red: 0.22, green: 0.94, blue: 0.55)

    private var slogan: String {
        if returnRate >= 5 { return "红牛出栏，今天吃大肉" }
        if returnRate >= 2 { return "小赚一笔，\(appearance.name)已经开始蹦迪" }
        if returnRate >= 0 { return "稳稳的幸福，\(appearance.name)陪我拿住" }
        if returnRate >= -3 { return "小亏当学费，\(appearance.name)有点紧张" }
        return "绿熊冬眠中，来日方长"
    }

    private var petFrameName: String {
        if appearance.skinSpec != nil {
            return "skin_\(appearance.rawValue)_\(mood == .bull ? "happy" : "sad")_0"
        }
        return appearance.previewName
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.MM.dd EEEE"
        return formatter.string(from: date)
    }

    private func percent(_ value: Double) -> String {
        "\(value > 0 ? "+" : "")\(String(format: "%.2f", value))%"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.14, blue: 0.19), Color(red: 0.04, green: 0.045, blue: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(mood.color.opacity(0.20))
                .frame(width: 420, height: 420)
                .blur(radius: 70)
                .offset(y: -140)

            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 7) {
                        Circle().fill(mood.color).frame(width: 9, height: 9).shadow(color: mood.color, radius: 6)
                        Text("持仓宠物").font(.system(size: 17, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                    Text(dateText).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 34)
                .padding(.top, 30)

                Spacer(minLength: 10)

                Group {
                    if appearance == .robot {
                        StockPetMascot(mood: mood, returnRate: returnRate, blinking: false, actionActive: true)
                    } else if let image = NSImage(named: NSImage.Name(petFrameName)) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    }
                }
                .frame(width: 215, height: 215)
                .shadow(color: mood.color.opacity(0.35), radius: 26, y: 10)

                Text(slogan)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .padding(.top, 14)

                Text(percent(returnRate))
                    .font(.system(size: 66, weight: .heavy, design: .rounded))
                    .foregroundStyle(mood.color)
                    .shadow(color: mood.color.opacity(0.45), radius: 18)
                    .padding(.top, 2)

                Text("今日总仓位收益率")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.top, 2)

                if !positions.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(positions) { item in
                            HStack {
                                Text(item.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.82))
                                Spacer()
                                Text(percent(item.change))
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(item.change >= 0 ? gainColor : lossColor)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.09)))
                    .padding(.horizontal, 44)
                    .padding(.top, 16)
                }

                Spacer(minLength: 12)

                VStack(spacing: 5) {
                    Divider().overlay(.white.opacity(0.1)).padding(.horizontal, 34)
                    Text("我的桌面宠物替我盯盘 · 仅供炫耀，不构成投资建议")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.34))
                        .padding(.vertical, 9)
                }
            }
        }
        .frame(width: 540, height: 660)
        .preferredColorScheme(.dark)
    }
}

struct SmileArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return path
    }
}
