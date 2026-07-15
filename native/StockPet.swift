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

    private let key = "stockPet.positions.v1"
    private let hiddenNewsKey = "stockPet.hiddenNews.v1"
    private let speaker = AVSpeechSynthesizer()
    private var hasLoadedNews = false

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Position].self, from: data), !saved.isEmpty {
            positions = saved
        } else {
            positions = [
                Position(name: "贵州茅台", value: 52_000, change: 2.35),
                Position(name: "宁德时代", value: 38_000, change: 0.42),
                Position(name: "腾讯控股", value: 26_000, change: -1.15)
            ]
        }
        hiddenNewsIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenNewsKey) ?? [])
    }

    var totalReturn: Double {
        let total = positions.reduce(0) { $0 + max(0, $1.value) }
        guard total > 0 else { return 0 }
        return positions.reduce(0) { $0 + max(0, $1.value) * $1.change } / total
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

    func testAlert() {
        guard notificationsEnabled else { return }
        let direction = totalReturn >= 0 ? "上涨" : "下跌"
        let ending = totalReturn >= 0 ? "牛宠物正在庆祝。" : "熊宠物上线了。"
        let message = "你的总仓位当前\(direction) \(String(format: "%.2f", abs(totalReturn)))%，\(ending)"

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
            window.setContentSize(NSSize(width: 118, height: 132))
            window.center()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
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
        .windowResizability(.contentSize)
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

struct ContentView: View {
    @ObservedObject var store: PetStore
    @State private var isExpanded = false
    @State private var showingNews = false
    @State private var hoveringCompact = false
    @State private var compactDragOrigin: NSPoint?
    @State private var hoveringPet = false
    @State private var importingScreenshot = false
    @State private var alertPulse = false
    @State private var motionToken = UUID()
    private let newsTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    private var mood: PetMood {
        store.totalReturn >= 0 ? .bull : .bear
    }

    private var statusText: String {
        switch mood {
        case .bull: store.totalReturn > 3 ? "小牛已经兴奋起来了" : "小牛今天心情不错"
        case .bear: store.totalReturn < -3 ? "小熊需要你的安慰" : "小熊今天有点紧张"
        }
    }

    var body: some View {
        Group {
            if isExpanded {
                expandedView
                    .frame(width: 390, height: 650)
                    .transition(.scale(scale: 0.82, anchor: .topLeading).combined(with: .opacity))
            } else {
                compactPet
                    .frame(width: 118, height: 132)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isExpanded)
        .fileImporter(isPresented: $importingScreenshot, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            store.screenshot = NSImage(contentsOf: url)
            store.showingEditor = true
        }
        .onChange(of: store.totalReturn) { _, _ in
            triggerPetMotion()
        }
        .task { await store.refreshNews() }
        .onReceive(newsTimer) { _ in
            Task { await store.refreshNews() }
        }
    }

    private var compactPet: some View {
        ZStack {
            Button {
                toggleExpanded(true)
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            AnimatedStockPet(
                mood: mood,
                returnRate: store.totalReturn,
                isAlerting: alertPulse
            )
            .frame(width: 100, height: 100)
            .allowsHitTesting(false)
            Text(percent(store.totalReturn))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(mood.color.opacity(0.9), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18)))
                .offset(y: 48)
                .allowsHitTesting(false)
            VStack {
                HStack {
                    Button {
                        hoveringCompact = false
                        showingNews.toggle()
                        if showingNews { Task { await store.refreshNews() } }
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
                    .help("热门资讯")
                    .popover(isPresented: $showingNews, arrowEdge: .leading) {
                        compactNewsCard
                    }
                    .zIndex(10)
                    Spacer()
                }
                Spacer()
            }
            .padding(5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged(moveCompactWindow)
                .onEnded { _ in compactDragOrigin = nil }
        )
        .onHover {
            if !showingNews { hoveringCompact = $0 }
        }
        .popover(isPresented: $hoveringCompact, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            compactPositionsCard
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mood.accessibilityName)，总收益 \(percent(store.totalReturn))")
        .accessibilityAddTraits(.isButton)
        .help("点击查看持仓")
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
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
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
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
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
        .preferredColorScheme(.dark)
    }

    private var compactPositionsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("核心仓位")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(store.topPositions) { item in
                HStack(spacing: 10) {
                    Text(item.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(percent(item.change))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(item.change >= 0 ? .red : Color(red: 0.20, green: 0.79, blue: 0.50))
                }
            }
        }
        .padding(10)
        .frame(width: 150)
        .preferredColorScheme(.dark)
    }

    private var expandedView: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.17), Color(red: 0.045, green: 0.05, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(mood.color.opacity(0.14))
                .frame(width: 300, height: 300)
                .blur(radius: 55)
                .offset(y: -155)

            VStack(spacing: 0) {
                topBar
                petStage
                controlPanel
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.42), radius: 28, y: 14)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle().fill(mood.color).frame(width: 7, height: 7).shadow(color: mood.color, radius: 5)
            Text("持仓宠物").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
            Spacer()
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

    private var petStage: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 5) {
                Spacer(minLength: 10)
                ZStack {
                    AnimatedStockPet(
                        mood: mood,
                        returnRate: store.totalReturn,
                        isAlerting: alertPulse
                    )
                    .frame(width: 150, height: 150)
                }
                .frame(width: 160, height: 150)
                .contentShape(Rectangle())
                .onHover { hoveringPet = $0 }

                Text(statusText).font(.system(size: 12)).foregroundStyle(.white.opacity(0.58))
                Text(percent(store.totalReturn))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(mood.color)
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
                    MiniBars(seed: item.change, color: item.change >= 0 ? .red : Color(red: 0.20, green: 0.79, blue: 0.50))
                        .frame(width: 66, height: 22)
                    Text(percent(item.change)).font(.system(size: 10, weight: .bold)).foregroundStyle(item.change >= 0 ? .red : Color(red: 0.20, green: 0.79, blue: 0.50)).frame(width: 55, alignment: .trailing)
                }.padding(.vertical, 6)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        .onHover { hoveringPet = $0 }
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
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
                store.testAlert()
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

    private var editor: some View {
        VStack(spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("持仓数据").font(.system(size: 10, weight: .semibold))
                    Text("名称 / 市值 / 收益率 %").font(.system(size: 8)).foregroundStyle(.white.opacity(0.3))
                }
                Spacer()
                Button("＋ 添加") { store.positions.append(Position(name: "新持仓", value: 0, change: 0)) }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.red.opacity(0.85))
            }
            ForEach($store.positions) { $item in
                HStack(spacing: 5) {
                    TextField("股票名称", text: $item.name).textFieldStyle(PetField()).frame(maxWidth: .infinity)
                    TextField("市值", value: $item.value, format: .number).textFieldStyle(PetField()).frame(width: 74)
                    TextField("收益%", value: $item.change, format: .number.precision(.fractionLength(0...2))).textFieldStyle(PetField()).frame(width: 62)
                    Button("×") { store.positions.removeAll { $0.id == item.id } }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.3))
                }
            }
            Button {
                store.save()
                store.showingEditor = false
            } label: {
                Text("保存并更新宠物").font(.system(size: 10, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8).background(.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
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

    private func moveCompactWindow(_ value: DragGesture.Value) {
        guard !isExpanded,
              let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else { return }
        if compactDragOrigin == nil { compactDragOrigin = window.frame.origin }
        guard let start = compactDragOrigin else { return }

        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let x = min(max(visible.minX, start.x + value.translation.width), visible.maxX - window.frame.width)
        let y = min(max(visible.minY, start.y - value.translation.height), visible.maxY - window.frame.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func toggleExpanded(_ expanded: Bool) {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else {
            isExpanded = expanded
            return
        }

        let oldFrame = window.frame
        let newSize = expanded ? NSSize(width: 390, height: 650) : NSSize(width: 118, height: 132)
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? oldFrame
        var origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - newSize.height)
        origin.x = min(max(visible.minX, origin.x), visible.maxX - newSize.width)
        origin.y = min(max(visible.minY, origin.y), visible.maxY - newSize.height)
        let target = NSRect(origin: origin, size: newSize)

        isExpanded = expanded
        window.hasShadow = expanded
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

struct AnimatedStockPet: View {
    let mood: PetMood
    let returnRate: Double
    let isAlerting: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let strongMove = abs(returnRate) >= 3 || isAlerting
            let actionWindow = time.truncatingRemainder(dividingBy: 3.2) < 1.05
            let actionActive = isAlerting || (strongMove && actionWindow)
            let idleLift = CGFloat(sin(time * 3.1)) * 1.5
            let jump = mood == .bull && actionActive
                ? -abs(CGFloat(sin(time * 6.2))) * 11
                : idleLift
            let shake = mood == .bear && actionActive
                ? CGFloat(sin(time * 30)) * 2.4
                : 0
            let breath = 1 + CGFloat(sin(time * 3.1)) * 0.012
            let blink = time.truncatingRemainder(dividingBy: 4.1) > 3.88

            StockPetMascot(mood: mood, blinking: blink, actionActive: actionActive)
                .scaleEffect(x: breath, y: 2 - breath, anchor: .bottom)
                .offset(x: shake, y: jump)
        }
        .accessibilityHidden(true)
    }
}

struct StockPetMascot: View {
    let mood: PetMood
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

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let line = max(2, side * 0.025)

            ZStack {
                Ellipse()
                    .fill(.black.opacity(0.26))
                    .frame(width: side * 0.55, height: side * 0.11)
                    .blur(radius: side * 0.025)
                    .offset(y: side * 0.405)

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
                .frame(width: side * 0.53, height: side * 0.285)
                .offset(y: -side * 0.055)

            petFace(side: side)
        }
    }

    @ViewBuilder
    private func petFace(side: CGFloat) -> some View {
        if blinking {
            HStack(spacing: side * 0.12) {
                Capsule().fill(glow).frame(width: side * 0.105, height: side * 0.025)
                Capsule().fill(glow).frame(width: side * 0.105, height: side * 0.025)
            }
            .offset(y: -side * 0.08)
        } else if mood == .bull {
            HStack(spacing: side * 0.085) {
                Image(systemName: "chevron.up")
                Image(systemName: "chevron.up")
            }
            .font(.system(size: side * 0.12, weight: .black))
            .foregroundStyle(glow)
            .offset(y: -side * 0.085)

            RoundedRectangle(cornerRadius: side * 0.035)
                .fill(Color(red: 1.0, green: 0.72, blue: 0.29))
                .frame(width: side * 0.18, height: side * 0.085)
                .overlay(HStack(spacing: side * 0.055) {
                    Circle().fill(darkColor).frame(width: side * 0.022)
                    Circle().fill(darkColor).frame(width: side * 0.022)
                })
                .offset(y: side * 0.04)
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
