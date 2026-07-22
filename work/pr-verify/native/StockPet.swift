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
    @Published var positions: [Position] = []
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

    private let key = "stockPet.positions.v1"
    private let hiddenNewsKey = "stockPet.hiddenNews.v1"
    private let speaker = AVSpeechSynthesizer()
    private var hasLoadedNews = false
    private var newsPollingTask: Task<Void, Never>?
    private var marketPollingTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Position].self, from: data), !saved.isEmpty {
            positions = saved.map { position in
                var position = position
                if position.symbol?.isEmpty != false {
                    position.symbol = Self.defaultSymbol(for: position.name)
                }
                return position
            }
        } else {
            positions = [
                Position(name: "贵州茅台", value: 52_000, change: 2.35, symbol: "sh600519"),
                Position(name: "宁德时代", value: 38_000, change: 0.42, symbol: "sz300750"),
                Position(name: "腾讯控股", value: 26_000, change: -1.15, symbol: "hk00700")
            ]
        }
        hiddenNewsIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenNewsKey) ?? [])
        startNewsPolling()
        startMarketPolling()
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
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshMarketData()
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func refreshMarketData() async {
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
                let liveTrend = symbol.isEmpty ? nil : try? await fetchMinuteTrend(symbol)
                let changePercent = quote?.percent ?? position.change
                snapshots[position.id] = PositionMarketSnapshot(
                    currentPrice: quote?.price,
                    changeAmount: quote?.change ?? 0,
                    changePercent: changePercent,
                    trend: liveTrend?.isEmpty == false ? liveTrend! : Self.fallbackTrend(seed: changePercent),
                    isLive: quote != nil && liveTrend?.isEmpty == false
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

    var totalReturn: Double {
        let total = positions.reduce(0) { $0 + max(0, $1.value) }
        guard total > 0 else { return 0 }
        return positions.reduce(0) { result, position in
            let change = positionMarkets[position.id]?.changePercent ?? position.change
            return result + max(0, position.value) * change
        } / total
    }

    var topPositions: [Position] {
        Array(positions.sorted { $0.value > $1.value }.prefix(3))
    }

    var visibleNews: [StockNews] {
        newsItems.filter { !hiddenNewsIDs.contains($0.id) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(positions) {
            UserDefaults.standard.set(data, forKey: key)
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

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "StockPet", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let window = NSApplication.shared.windows.first else { return }
            window.level = .floating
            window.isMovableByWindowBackground = true
            window.styleMask = [.borderless, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.setContentSize(NSSize(width: 150, height: 165))
            window.center()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
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

@main
struct StockPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = PetStore()

    var body: some Scene {
        WindowGroup("持仓宠物") {
            ContentView(store: store)
        }
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
    case market, robot, mech, polar, pbull, ox, minicow, bubu, jokebear, obear

    var id: String { rawValue }

    var name: String {
        switch self {
        case .market: return "行情牛熊"
        case .robot: return "行情机器人"
        case .mech: return "涨跌机甲"
        case .polar: return "红绿北极熊"
        case .pbull: return "横冲牛牛"
        case .ox: return "原野公牛"
        case .minicow: return "迷你奶牛"
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
        case .pbull:
            return PetSkinSpec(idleFrames: 4, happyFrames: 4, sadFrames: 4)
        case .ox:
            return PetSkinSpec(idleFrames: 5, happyFrames: 3, sadFrames: 6)
        case .minicow:
            return PetSkinSpec(idleFrames: 6, happyFrames: 6, sadFrames: 6)
        case .bubu, .jokebear, .obear:
            return PetSkinSpec(idleFrames: 6, happyFrames: 4, sadFrames: 4)
        default:
            return nil
        }
    }

    var previewName: String {
        switch self {
        case .market: return "skin_rbull_idle_0"
        case .robot: return ""
        case .mech, .polar, .pbull, .ox, .minicow, .bubu, .jokebear, .obear: return "skin_\(rawValue)_idle_0"
        }
    }

    var assetName: String? {
        nil
    }

    var tagline: String {
        switch self {
        case .market: return "随涨跌切换牛熊形态"
        case .robot: return "经典动态行情机器人"
        case .mech: return "上涨起跳，下跌滑倒，十帧机甲动画"
        case .polar: return "红绿战衣，涨时欢跑，跌时眩晕"
        case .pbull: return "横冲直撞小棕牛，涨了哞哞叫"
        case .ox: return "原野公牛本色出演，困了就躺平"
        case .minicow: return "口袋小奶牛，蹄子迈不停"
        case .bubu: return "软乎乎布布，跌了也抱抱你"
        case .jokebear: return "淡定白熊，涨跌都好笑"
        case .obear: return "红围巾棕熊，暖暖守护仓位"
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: PetStore
    @AppStorage("stockPet.appearance.v1") private var selectedAppearanceRaw = PetAppearance.market.rawValue
    @State private var isExpanded = false
    @State private var showingNews = false
    @State private var hoveringCompact = false
    @State private var compactPetHovering = false
    @GestureState private var draggingCompactWindow = false
    @State private var hoveringPet = false
    @State private var importingScreenshot = false
    @State private var alertPulse = false
    @State private var motionToken = UUID()
    @State private var showingDebugPanel = false
    @State private var debugReturnsToMainPage = false
    @State private var showingPetStore = false
    @State private var showingShareCard = false
    @State private var shareIncludePositions = false
    @State private var shareFeedback = ""
    @State private var mockReturnRate = 0.0
    @State private var isMockingReturn = false
    private let gainColor = Color(red: 1.0, green: 0.28, blue: 0.30)
    private let lossColor = Color(red: 0.20, green: 1.0, blue: 0.56)
    private let popoverBackground = Color(red: 0.035, green: 0.05, blue: 0.08)

    private var displayReturn: Double {
        isMockingReturn ? mockReturnRate : store.totalReturn
    }

    private var selectedAppearance: PetAppearance {
        PetAppearance(rawValue: selectedAppearanceRaw) ?? .market
    }

    private var mockReturnBinding: Binding<Double> {
        Binding(
            get: { mockReturnRate },
            set: {
                mockReturnRate = $0
                isMockingReturn = true
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
            if showingDebugPanel {
                debugExpandedView
                    .frame(minWidth: 390, minHeight: 560)
                    .transition(.scale(scale: 0.82, anchor: .topLeading).combined(with: .opacity))
            } else if isExpanded {
                expandedView
                    .frame(minWidth: 760, minHeight: 560)
                    .transition(.scale(scale: 0.82, anchor: .topLeading).combined(with: .opacity))
            } else {
                compactPet
                    .frame(width: compactWindowSize.width, height: compactWindowSize.height)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
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
            if !isExpanded {
                DispatchQueue.main.async {
                    resizeCompactWindowForReturn()
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                resizeCompactWindowForReturn(animated: false)
            }
        }
        .sheet(isPresented: $showingPetStore) {
            petStorePage
        }
        .sheet(isPresented: $store.showingEditor) {
            editor
                .padding(20)
                .frame(width: 560)
                .background(Color(red: 0.045, green: 0.05, blue: 0.075))
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingShareCard) {
            shareCardPage
        }
        .onChange(of: showingDebugPanel) { wasShowing, isShowing in
            if wasShowing && !isShowing { resetDebugState() }
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
                HStack(spacing: 10) {
                    Text(item.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(percent(item.change))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(item.change >= 0 ? gainColor : lossColor)
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

                debugPetStage
                appearancePicker
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                debugPanel
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                Spacer(minLength: 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.09)))
        .overlay(alignment: .bottomTrailing) { resizeGrip }
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
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.17), Color(red: 0.045, green: 0.05, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(spacing: 0) {
                topBar
                marketDashboard
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.09)))
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .shadow(color: .black.opacity(0.42), radius: 28, y: 14)
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.28))
            .padding(9)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle().fill(mood.color).frame(width: 7, height: 7).shadow(color: mood.color, radius: 5)
            Text("持仓行情").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
            Spacer()
            Button {
                store.showingEditor = true
            } label: {
                Image(systemName: "pencil.line").font(.system(size: 10, weight: .semibold)).frame(width: 25, height: 24).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("编辑持仓")
            Button {
                openShareCard()
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 10, weight: .semibold)).frame(width: 25, height: 24).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("晒收益")
            Button {
                showingPetStore = true
            } label: {
                Image(systemName: "bag.fill").font(.system(size: 10, weight: .semibold)).frame(width: 25, height: 24).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("宠物商城")
            Button {
                openDebugPanel()
            } label: {
                Image(systemName: "ladybug.fill").font(.system(size: 10, weight: .semibold)).frame(width: 25, height: 24).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("调试")
            Button {
                toggleExpanded(false)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 25, height: 24).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("收起")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 25, height: 24).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("退出")
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
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

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.positions) { position in
                            positionMarketRow(position, chartWidth: chartWidth)
                            Divider().overlay(.white.opacity(0.06)).padding(.horizontal, 20)
                        }
                        if store.positions.isEmpty {
                            ContentUnavailableView("暂无持仓", systemImage: "chart.line.uptrend.xyaxis", description: Text("点击右上角编辑按钮添加持仓和证券代码"))
                                .frame(minHeight: 220)
                        }
                    }
                }
            }
        }
        .background(.black.opacity(0.12))
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
                if index > 0 { Divider().overlay(.white.opacity(0.07)) }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 10, weight: .medium))
                        Text("市值 ¥\(Int(item.value))").font(.system(size: 8)).foregroundStyle(.white.opacity(0.32))
                    }
                    Spacer()
                    MiniBars(seed: item.change, color: item.change >= 0 ? gainColor : lossColor)
                        .frame(width: 66, height: 22)
                    Text(percent(item.change)).font(.system(size: 10, weight: .bold)).foregroundStyle(item.change >= 0 ? gainColor : lossColor).frame(width: 55, alignment: .trailing)
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
                    ForEach(PetAppearance.allCases) { appearance in
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
                    ForEach(PetAppearance.allCases) { appearance in
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
            positions: shareIncludePositions ? store.topPositions : [],
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
                            mockReturnRate = rate
                            isMockingReturn = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Button {
                isMockingReturn = true
                store.testAlert(returnRate: mockReturnRate)
                triggerPetMotion()
            } label: {
                Label("播放调试动作", systemImage: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(mood.color)

            Button("恢复真实收益率") {
                isMockingReturn = false
                mockReturnRate = store.totalReturn
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
        VStack(spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("持仓数据").font(.system(size: 10, weight: .semibold))
                    Text("名称 / 证券代码 / 市值 / 备用收益率 %").font(.system(size: 8)).foregroundStyle(.white.opacity(0.3))
                }
                Spacer()
                Button("＋ 添加") { store.positions.append(Position(name: "新持仓", value: 0, change: 0, symbol: "")) }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.red.opacity(0.85))
            }
            ForEach($store.positions) { $item in
                HStack(spacing: 5) {
                    TextField("股票名称", text: $item.name).textFieldStyle(PetField()).frame(maxWidth: .infinity)
                    TextField("如 sh600519", text: Binding(
                        get: { item.symbol ?? "" },
                        set: { item.symbol = $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                    )).textFieldStyle(PetField()).frame(width: 96)
                    TextField("市值", value: $item.value, format: .number).textFieldStyle(PetField()).frame(width: 74)
                    TextField("收益%", value: $item.change, format: .number.precision(.fractionLength(0...2))).textFieldStyle(PetField()).frame(width: 62)
                    Button("×") { store.positions.removeAll { $0.id == item.id } }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.3))
                }
            }
            Button {
                store.save()
                store.showingEditor = false
                Task { await store.refreshMarketData() }
            } label: {
                Text("保存并刷新行情").font(.system(size: 10, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8).background(.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
        }
        .padding(.top, 9)
        .overlay(alignment: .top) { Divider().overlay(.white.opacity(0.07)) }
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
        debugReturnsToMainPage = isExpanded
        if !isMockingReturn {
            mockReturnRate = store.totalReturn
            isMockingReturn = true
        }
        showingDebugPanel = true
        toggleExpanded(true)
    }

    private func closeDebugPanel() {
        let returnToMainPage = debugReturnsToMainPage
        showingDebugPanel = false
        resetDebugState()
        toggleExpanded(returnToMainPage)
    }

    private func resetDebugState() {
        isMockingReturn = false
        mockReturnRate = store.totalReturn
    }

    private func resizeCompactWindowForReturn(animated: Bool = true) {
        guard !isExpanded,
              let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else { return }

        let oldFrame = window.frame
        let newSize = compactWindowSize
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? oldFrame
        var origin = NSPoint(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.midY - newSize.height / 2
        )
        origin.x = min(max(visible.minX, origin.x), visible.maxX - newSize.width)
        origin.y = min(max(visible.minY, origin.y), visible.maxY - newSize.height)
        let target = NSRect(origin: origin, size: newSize)

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
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else {
            isExpanded = expanded
            return
        }

        let oldFrame = window.frame
        let isMainDashboard = expanded && !showingDebugPanel
        let newSize: NSSize
        if isMainDashboard {
            newSize = NSSize(width: 980, height: 700)
        } else if expanded {
            newSize = NSSize(width: 390, height: expandedWindowHeight)
        } else {
            newSize = compactWindowSize
        }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? oldFrame
        var origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - newSize.height)
        origin.x = min(max(visible.minX, origin.x), visible.maxX - newSize.width)
        origin.y = min(max(visible.minY, origin.y), visible.maxY - newSize.height)
        let target = NSRect(origin: origin, size: newSize)

        isExpanded = expanded
        window.hasShadow = expanded
        if expanded {
            window.styleMask.insert(.resizable)
            window.contentMinSize = isMainDashboard
                ? NSSize(width: 760, height: 560)
                : NSSize(width: 390, height: 560)
            window.contentMaxSize = NSSize(width: 1600, height: 1100)
        } else {
            window.styleMask.remove(.resizable)
            window.contentMinSize = newSize
            window.contentMaxSize = newSize
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        }
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
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
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

                let repeatInterval = max(2.35, 4.2 - happinessStrength * 1.8)
                let automaticElapsed = time.truncatingRemainder(dividingBy: repeatInterval)
                let automaticDuration = 0.72
                let automaticActive = mood == .bull && positiveReturn >= 2 && automaticElapsed < automaticDuration
                let automaticProgress = min(1, automaticElapsed / automaticDuration)
                let automaticHeight = automaticActive
                    ? CGFloat(sin(automaticProgress * .pi)) * side * CGFloat(0.025 + happinessStrength * 0.07)
                    : 0

                let jumpHeight = max(hoverHeight, alertHeight, automaticHeight)
                let floatFrequency = 2.35 + happinessStrength * 1.15
                let floatAmplitude = side * CGFloat(0.006 + happinessStrength * 0.024)
                let idleLift = CGFloat(sin(time * floatFrequency)) * floatAmplitude
                let bullActionActive = hoverActive || alertActive || automaticActive

                let bearActionWindow = time.truncatingRemainder(dividingBy: 3.2) < 1.05
                let bearActionActive = mood == .bear && (isAlerting || returnRate <= -3) && bearActionWindow
                let shake = bearActionActive ? CGFloat(sin(time * 30)) * side * 0.024 : 0

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

    private var frameName: String {
        let isBull = mood == .bull
        let isExpressive = isBull
            ? (actionActive || returnRate >= 1)
            : (actionActive || returnRate <= -0.5)
        // 更高帧率，动画更流畅；睡觉时放慢
        let speed = actionActive ? 10.0 : 7.0

        if appearance == .market {
            // 行情牛熊：红牛 / 绿熊，接近平盘时红牛打盹
            if isBull {
                if returnRate < 0.3 && !actionActive {
                    return "skin_rbull_sleep_\(Int(time * 4.5) % 6)"
                }
                let state = isExpressive ? "happy" : "idle"
                let count = state == "happy" ? 3 : 5
                return "skin_rbull_\(state)_\(Int(time * speed) % count)"
            }
            let state = isExpressive ? "sad" : "idle"
            let count = state == "sad" ? 4 : 6
            return "skin_gbear_\(state)_\(Int(time * speed) % count)"
        }

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

    var body: some View {
        Group {
            if let assetName = appearance.assetName,
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
        if appearance == .market || appearance == .robot {
            return mood == .bull ? "skin_rbull_happy_0" : "skin_gbear_sad_0"
        }
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
