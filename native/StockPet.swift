import SwiftUI
import Foundation
import AppKit
import AVFoundation
import UserNotifications
import Security
import Vision
import UniformTypeIdentifiers

private enum StockPetKeychain {
    private static let service = "com.stockpet.market-data"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var newItem = query
        newItem[kSecValueData as String] = data
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

struct Position: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var value: Double
    var change: Double
    var symbol: String? = nil
}

private enum PositionScreenshotOCR {
    private struct Fragment {
        let text: String
        let box: CGRect

        var centerY: CGFloat { box.midY }
    }

    private struct VisualLine {
        var fragments: [Fragment]
        var centerY: CGFloat

        var text: String {
            fragments
                .sorted { $0.box.minX < $1.box.minX }
                .map(\.text)
                .joined(separator: " ")
        }
    }

    static func recognizePositions(in image: NSImage) throws -> [Position] {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return []
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

        let fragments = (request.results ?? []).compactMap { observation -> Fragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Fragment(text: text, box: observation.boundingBox)
        }
        return parsePositions(from: makeLines(fragments))
    }

    private static func makeLines(_ fragments: [Fragment]) -> [VisualLine] {
        var lines: [VisualLine] = []
        for fragment in fragments.sorted(by: { $0.centerY > $1.centerY }) {
            if let index = lines.indices.last,
               abs(lines[index].centerY - fragment.centerY) < 0.014 {
                lines[index].fragments.append(fragment)
                let count = CGFloat(lines[index].fragments.count)
                lines[index].centerY = ((lines[index].centerY * (count - 1)) + fragment.centerY) / count
            } else {
                lines.append(VisualLine(fragments: [fragment], centerY: fragment.centerY))
            }
        }
        return lines
    }

    private static func parsePositions(from lines: [VisualLine]) -> [Position] {
        let candidates = lines.indices.compactMap { index -> (Int, String)? in
            let leftText = lines[index].fragments
                .filter { $0.box.minX < 0.42 }
                .sorted { $0.box.minX < $1.box.minX }
                .map(\.text)
                .joined(separator: " ")
            let name = cleanSecurityName(leftText)
            return isSecurityName(name) ? (index, name) : nil
        }

        var parsed: [Position] = []
        for (offset, candidate) in candidates.enumerated() {
            let nextIndex = offset + 1 < candidates.count ? candidates[offset + 1].0 : lines.count
            var value: Double?
            var change: Double?
            for line in lines[candidate.0..<nextIndex] {
                guard let percentMatch = firstMatch(in: line.text, pattern: #"[+\-−—–]?\d+(?:\.\d+)?\s*%"#) else {
                    continue
                }
                change = marketNumber(percentMatch.value.replacingOccurrences(of: "%", with: ""))
                let prefix = String(line.text[..<percentMatch.range.lowerBound])
                let numbers = allMatches(in: prefix, pattern: #"[+\-−—–]?\d[\d,]*(?:\.\d+)?"#)
                    .compactMap(marketNumber)
                value = numbers.first
                if value != nil, change != nil { break }
            }
            guard let value, let change else { continue }
            parsed.append(Position(name: candidate.1, value: value, change: change, symbol: nil))
        }

        var seenNames = Set<String>()
        return parsed.filter { seenNames.insert($0.name).inserted }
    }

    private static func cleanSecurityName(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+[+\-−—–]?\d[\d,.]*(?:\s.*)?$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func isSecurityName(_ value: String) -> Bool {
        guard value.count >= 2,
              value.range(of: #"[\p{Han}A-Za-z]"#, options: .regularExpression) != nil else { return false }
        let excluded = [
            "同花顺", "证券", "人民币账户", "总资产", "总盈亏", "当日参考盈亏", "总市值", "可用", "可取",
            "持仓股", "市值", "盈亏", "持仓/可用", "成本/现价", "查看已清仓", "持仓管理", "批量买入", "批量卖出",
            "止盈止损", "持仓资讯", "资产分析", "买入", "卖出", "撤单", "持仓", "查询", "首页", "行情", "自选", "交易", "资讯", "理财"
        ]
        return !excluded.contains { value.contains($0) }
    }

    private static func marketNumber(_ value: String) -> Double? {
        Double(value
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func firstMatch(in text: String, pattern: String) -> (value: String, range: Range<String.Index>)? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return (String(text[range]), range)
    }

    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
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

/// 顶部指数栏里的一项（可自定义），symbol 直接用行情源代码，如 sh000001 / usIXIC / hkHSI。
struct WatchIndex: Identifiable, Codable, Equatable {
    var symbol: String
    var name: String
    var id: String { symbol }
}

struct IndexGroup: Identifiable {
    let title: String
    let items: [WatchIndex]
    var id: String { title }
}

/// 预置指数目录（symbol 均已联网核对可取到行情）。
enum IndexCatalog {
    static let groups: [IndexGroup] = [
        IndexGroup(title: "A股指数", items: [
            WatchIndex(symbol: "sh000001", name: "上证指数"),
            WatchIndex(symbol: "sz399001", name: "深证成指"),
            WatchIndex(symbol: "sz399006", name: "创业板指"),
            WatchIndex(symbol: "sh000688", name: "科创50"),
            WatchIndex(symbol: "sh000300", name: "沪深300"),
            WatchIndex(symbol: "sh000905", name: "中证500")
        ]),
        IndexGroup(title: "美股", items: [
            WatchIndex(symbol: "usDJI", name: "道琼斯"),
            WatchIndex(symbol: "usIXIC", name: "纳斯达克"),
            WatchIndex(symbol: "usINX", name: "标普500"),
            WatchIndex(symbol: "usQQQ", name: "纳指100 QQQ")
        ]),
        IndexGroup(title: "港股", items: [
            WatchIndex(symbol: "hkHSI", name: "恒生指数"),
            WatchIndex(symbol: "hkHSTECH", name: "恒生科技")
        ]),
        IndexGroup(title: "日经", items: [
            WatchIndex(symbol: "sh513880", name: "日经225(ETF)")
        ])
    ]
    static let all: [WatchIndex] = groups.flatMap { $0.items }
    /// 默认仍是原来那几个 A 股指数
    static let defaults: [WatchIndex] = Array(groups[0].items.prefix(5))
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

private enum MarketRegion {
    case mainlandChina
    case hongKong
    case unitedStates
    case unknown
}

private enum MarketSessionPhase: Equatable {
    case preMarket
    case regular
    case middayBreak
    case afterHours
    case overnight
    case closed
    case unknown

    var label: String {
        switch self {
        case .preMarket: return "盘前交易"
        case .regular: return "已开市"
        case .middayBreak: return "午间休市"
        case .afterHours: return "盘后交易"
        case .overnight: return "隔夜交易"
        case .closed: return "休市"
        case .unknown: return "未设置"
        }
    }

    var color: Color {
        switch self {
        case .preMarket: return Color(red: 1.0, green: 0.70, blue: 0.16)
        case .regular: return Color(red: 0.24, green: 0.78, blue: 0.28)
        case .middayBreak: return Color(red: 0.78, green: 0.66, blue: 0.34)
        case .afterHours: return Color(red: 0.57, green: 0.32, blue: 1.0)
        case .overnight: return Color(red: 0.21, green: 0.54, blue: 1.0)
        case .closed, .unknown: return Color.white.opacity(0.36)
        }
    }

    var shouldRefreshLatestPrice: Bool {
        switch self {
        case .preMarket, .regular, .afterHours, .overnight:
            // 隔夜时段也刷新：新浪 gb_ 会给出最新的盘后收盘价，而不是停在 0.00%
            return true
        case .middayBreak, .closed, .unknown:
            return false
        }
    }
}

private struct MarketSessionBadge {
    let phase: MarketSessionPhase
    let marketName: String
    let detail: String

    var label: String { phase.label }
    var color: Color { phase.color }
}

private enum USMarketClockMode {
    case daylightSaving
    case standard

    var timeZone: TimeZone {
        switch self {
        case .daylightSaving:
            return TimeZone(secondsFromGMT: -4 * 60 * 60)!
        case .standard:
            return TimeZone(secondsFromGMT: -5 * 60 * 60)!
        }
    }
}

private enum MarketSessionResolver {
    private static let utcPlus8 = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    private static let newYork = TimeZone(identifier: "America/New_York")!

    private struct USMarketClock {
        let mode: USMarketClockMode

        var calendar: Calendar {
            MarketSessionResolver.calendar(in: mode.timeZone)
        }
    }

    private static let mainlandHolidays2026: Set<String> = [
        "2026-01-01", "2026-01-02", "2026-01-03",
        "2026-02-15", "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19",
        "2026-02-20", "2026-02-21", "2026-02-22", "2026-02-23",
        "2026-04-04", "2026-04-05", "2026-04-06",
        "2026-05-01", "2026-05-02", "2026-05-03", "2026-05-04", "2026-05-05",
        "2026-06-19", "2026-06-20", "2026-06-21",
        "2026-09-25", "2026-09-26", "2026-09-27",
        "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04",
        "2026-10-05", "2026-10-06", "2026-10-07"
    ]

    private static let hongKongHolidays2026: Set<String> = [
        "2026-01-01",
        "2026-02-17", "2026-02-18", "2026-02-19",
        "2026-04-03", "2026-04-04", "2026-04-06", "2026-04-07",
        "2026-05-01", "2026-05-25",
        "2026-06-19",
        "2026-07-01",
        "2026-09-26",
        "2026-10-01", "2026-10-19",
        "2026-12-25", "2026-12-26"
    ]

    private static let hongKongHalfDays2026: Set<String> = [
        "2026-02-16",
        "2026-12-24",
        "2026-12-31"
    ]

    private static let usHolidays2026: Set<String> = [
        "2026-01-01",
        "2026-01-19",
        "2026-02-16",
        "2026-04-03",
        "2026-05-25",
        "2026-06-19",
        "2026-07-03",
        "2026-09-07",
        "2026-11-26",
        "2026-12-25"
    ]

    private static let usEarlyCloseDays2026: Set<String> = [
        "2026-11-27",
        "2026-12-24"
    ]

    static func session(for symbol: String?, at date: Date = Date()) -> MarketSessionBadge {
        let region = region(for: symbol)
        switch region {
        case .mainlandChina:
            return mainlandSession(at: date)
        case .hongKong:
            return hongKongSession(at: date)
        case .unitedStates:
            return usSession(at: date)
        case .unknown:
            return MarketSessionBadge(phase: .unknown, marketName: "未知市场", detail: "请先设置股票代码")
        }
    }

    private static func region(for symbol: String?) -> MarketRegion {
        let normalized = (symbol ?? "").lowercased()
        if normalized.hasPrefix("sh") || normalized.hasPrefix("sz") { return .mainlandChina }
        if normalized.hasPrefix("hk") { return .hongKong }
        if normalized.hasPrefix("us") { return .unitedStates }
        return .unknown
    }

    private static func mainlandSession(at date: Date) -> MarketSessionBadge {
        let calendar = calendar(in: utcPlus8)
        let key = dateKey(for: date, calendar: calendar)
        guard isTradingDay(date, calendar: calendar, holidays: mainlandHolidays2026) else {
            return MarketSessionBadge(phase: .closed, marketName: "A股", detail: "A股今日休市")
        }

        let minute = minuteOfDay(for: date, calendar: calendar)
        let phase: MarketSessionPhase
        switch minute {
        case ..<minutes(9, 15):
            phase = .closed
        case minutes(9, 15)..<minutes(9, 30):
            phase = .preMarket
        case minutes(9, 30)..<minutes(11, 30):
            phase = .regular
        case minutes(11, 30)..<minutes(13, 0):
            phase = .middayBreak
        case minutes(13, 0)..<minutes(15, 0):
            phase = .regular
        case minutes(15, 0)..<minutes(15, 30):
            phase = .afterHours
        default:
            phase = .closed
        }
        return MarketSessionBadge(phase: phase, marketName: "A股", detail: "A股交易日 \(key) · UTC+8")
    }

    private static func hongKongSession(at date: Date) -> MarketSessionBadge {
        let calendar = calendar(in: utcPlus8)
        let key = dateKey(for: date, calendar: calendar)
        guard isTradingDay(date, calendar: calendar, holidays: hongKongHolidays2026) else {
            return MarketSessionBadge(phase: .closed, marketName: "港股", detail: "港股今日休市")
        }

        let minute = minuteOfDay(for: date, calendar: calendar)
        let isHalfDay = hongKongHalfDays2026.contains(key)
        let afternoonClose = isHalfDay ? minutes(12, 10) : minutes(16, 10)
        let afterHoursEnd = isHalfDay ? minutes(13, 0) : minutes(18, 0)
        let phase: MarketSessionPhase
        if minute < minutes(9, 0) {
            phase = .closed
        } else if minute < minutes(9, 30) {
            phase = .preMarket
        } else if minute < minutes(12, 0) {
            phase = .regular
        } else if isHalfDay, minute < afternoonClose {
            phase = .regular
        } else if !isHalfDay, minute < minutes(13, 0) {
            phase = .middayBreak
        } else if !isHalfDay, minute < afternoonClose {
            phase = .regular
        } else if minute < afterHoursEnd {
            phase = .afterHours
        } else {
            phase = .closed
        }
        return MarketSessionBadge(phase: phase, marketName: "港股", detail: "港股交易日 \(key) · UTC+8")
    }

    private static func usSession(at date: Date) -> MarketSessionBadge {
        let marketClock = usMarketClock(at: date)
        let calendar = marketClock.calendar
        let key = dateKey(for: date, calendar: calendar)
        let minute = minuteOfDay(for: date, calendar: calendar)
        let regularClose = usEarlyCloseDays2026.contains(key) ? minutes(13, 0) : minutes(16, 0)
        let afterHoursEnd = usEarlyCloseDays2026.contains(key) ? minutes(17, 0) : minutes(20, 0)
        let isTodayTradingDay = isTradingDay(date, calendar: calendar, holidays: usHolidays2026)
        let nextDate = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        let nextKey = dateKey(for: nextDate, calendar: calendar)
        let isNextCalendarDayTradingDay = isTradingDay(nextDate, calendar: calendar, holidays: usHolidays2026)
        let phase: MarketSessionPhase
        if minute < minutes(4, 0) {
            phase = isTodayTradingDay ? .overnight : .closed
        } else if !isTodayTradingDay {
            phase = .closed
        } else if minute < minutes(9, 30) {
            phase = .preMarket
        } else if minute < regularClose {
            phase = .regular
        } else if minute < afterHoursEnd {
            phase = .afterHours
        } else if minute >= minutes(20, 0), isNextCalendarDayTradingDay {
            phase = .overnight
        } else {
            phase = .closed
        }

        let detail: String
        if phase == .overnight, minute >= minutes(20, 0) {
            detail = "隔夜交易连接 \(nextKey) 美股交易日 · 纽约时间"
        } else if isTodayTradingDay {
            detail = "美股交易日 \(key) · 纽约时间"
        } else {
            detail = "美股今日休市"
        }
        return MarketSessionBadge(phase: phase, marketName: "美股", detail: detail)
    }

    private static func usMarketClock(at date: Date) -> USMarketClock {
        let mode: USMarketClockMode = newYork.isDaylightSavingTime(for: date)
            ? .daylightSaving
            : .standard
        return USMarketClock(mode: mode)
    }

    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func isTradingDay(_ date: Date, calendar: Calendar, holidays: Set<String>) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        guard weekday != 1, weekday != 7 else { return false }
        return !holidays.contains(dateKey(for: date, calendar: calendar))
    }

    private static func dateKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func minuteOfDay(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return minutes(components.hour ?? 0, components.minute ?? 0)
    }

    private static func minutes(_ hour: Int, _ minute: Int) -> Int {
        hour * 60 + minute
    }
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
    @Published var notificationsEnabled = true {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Self.notificationsEnabledKey)
            if notificationsEnabled {
                requestNotificationAuthorizationIfNeeded()
            }
        }
    }
    @Published var screenshot: NSImage?
    @Published var importedPositions: [Position] = []
    @Published var isRecognizingScreenshot = false
    @Published var isResolvingImportedSymbols = false
    @Published var screenshotImportMessage: String?
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
    @Published var alpacaAPIKey = ""
    @Published var alpacaAPISecret = ""
    @Published var alpacaStatus = "未配置 Alpaca，夜盘将继续显示盘后最后价格"
    @Published var watchIndices: [WatchIndex] = []
    @Published var includeUSInReturn = true
    @Published var newsHoldingsOnly = false
    @Published var newsPushIntervalMinutes = 15   // 0 = 关闭推送

    private let key = "stockPet.positions.v1"
    private let watchIndicesKey = "stockPet.watchIndices.v1"
    private let includeUSInReturnKey = "stockPet.includeUSInReturn.v1"
    private let newsHoldingsOnlyKey = "stockPet.newsHoldingsOnly.v1"
    private let newsPushIntervalKey = "stockPet.newsPushInterval.v1"
    private let hiddenNewsKey = "stockPet.hiddenNews.v1"
    private static let notificationsEnabledKey = "stockPet.notifications.enabled.v1"
    private static let notifiedNewsKey = "stockPet.news.notifiedIDs.v1"
    private static let alpacaAPIKeyAccount = "alpaca-api-key"
    private static let alpacaAPISecretAccount = "alpaca-api-secret"
    private let speaker = AVSpeechSynthesizer()
    private var isRestoringPositions = true
    private var notifiedNewsIDs: Set<String> = []
    private var positionsSaveTask: Task<Void, Never>?
    private var newsPollingTask: Task<Void, Never>?
    private var marketPollingTask: Task<Void, Never>?

    var hasAlpacaCredentials: Bool {
        !alpacaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !alpacaAPISecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        alpacaAPIKey = StockPetKeychain.string(for: Self.alpacaAPIKeyAccount) ?? ""
        alpacaAPISecret = StockPetKeychain.string(for: Self.alpacaAPISecretAccount) ?? ""
        if !alpacaAPIKey.isEmpty, !alpacaAPISecret.isEmpty {
            alpacaStatus = "Alpaca 已配置，夜盘时自动使用免费 overnight 行情"
        }
        if UserDefaults.standard.object(forKey: Self.notificationsEnabledKey) != nil {
            notificationsEnabled = UserDefaults.standard.bool(forKey: Self.notificationsEnabledKey)
        }
        if let saved = Self.loadSavedPositions(forKey: key) {
            positions = saved
        } else {
            positions = Self.defaultPositions
        }
        if let data = UserDefaults.standard.data(forKey: watchIndicesKey),
           let saved = try? JSONDecoder().decode([WatchIndex].self, from: data), !saved.isEmpty {
            watchIndices = saved
        } else {
            watchIndices = IndexCatalog.defaults
        }
        let prefs = UserDefaults.standard
        if prefs.object(forKey: includeUSInReturnKey) != nil { includeUSInReturn = prefs.bool(forKey: includeUSInReturnKey) }
        if prefs.object(forKey: newsHoldingsOnlyKey) != nil { newsHoldingsOnly = prefs.bool(forKey: newsHoldingsOnlyKey) }
        if prefs.object(forKey: newsPushIntervalKey) != nil { newsPushIntervalMinutes = prefs.integer(forKey: newsPushIntervalKey) }
        isRestoringPositions = false
        hiddenNewsIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenNewsKey) ?? [])
        notifiedNewsIDs = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedNewsKey) ?? [])
        if notificationsEnabled {
            requestNotificationAuthorizationIfNeeded()
        }
        startNewsPolling()
        startMarketPolling()
    }

    func saveAlpacaCredentials() {
        alpacaAPIKey = alpacaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        alpacaAPISecret = alpacaAPISecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAlpacaCredentials else {
            alpacaStatus = "请完整填写 API Key 和 Secret Key"
            return
        }
        let savedKey = StockPetKeychain.set(alpacaAPIKey, for: Self.alpacaAPIKeyAccount)
        let savedSecret = StockPetKeychain.set(alpacaAPISecret, for: Self.alpacaAPISecretAccount)
        guard savedKey, savedSecret else {
            alpacaStatus = "保存失败，请检查系统钥匙串权限"
            return
        }
        alpacaStatus = "密钥已保存，正在刷新美股行情…"
        Task { await refreshMarketData() }
    }

    func clearAlpacaCredentials() {
        StockPetKeychain.remove(Self.alpacaAPIKeyAccount)
        StockPetKeychain.remove(Self.alpacaAPISecretAccount)
        alpacaAPIKey = ""
        alpacaAPISecret = ""
        alpacaStatus = "已停用 Alpaca 夜盘行情"
    }

    func importPositionScreenshot(_ image: NSImage) {
        screenshot = image
        importedPositions = []
        isRecognizingScreenshot = true
        screenshotImportMessage = "正在本机识别持仓截图…"
        defer { isRecognizingScreenshot = false }

        do {
            let recognized = try PositionScreenshotOCR.recognizePositions(in: image)
            importedPositions = recognized
            screenshotImportMessage = recognized.isEmpty
                ? "没有识别到完整仓位，请换一张同时包含名称、市值和涨跌幅的截图"
                : "已识别 \(recognized.count) 条仓位，请核对后更新；原有美股会保留"
        } catch {
            screenshotImportMessage = "图片识别失败，请换一张更清晰的原图"
        }
    }

    func loadPositionImportExample() {
        screenshot = nil
        importedPositions = [
            Position(name: "纳指科技ETF景顺", value: 76_297.20, change: 2.278, symbol: "sz159509"),
            Position(name: "纳指ETF广发", value: 140_132.10, change: 1.341, symbol: "sz159941"),
            Position(name: "中概互联网ETF", value: 9_846.20, change: -1.547, symbol: "sh513050")
        ]
        screenshotImportMessage = "这是虚构示例数据；可以体验更新流程，不会要求登录"
    }

    func resolveImportedPositionSymbols() async {
        guard !importedPositions.isEmpty else { return }
        isResolvingImportedSymbols = true
        defer { isResolvingImportedSymbols = false }
        var unresolvedNames: [String] = []
        let unresolvedIDs = importedPositions
            .filter { $0.symbol?.isEmpty != false }
            .map(\.id)
        for id in unresolvedIDs {
            guard let candidate = importedPositions.first(where: { $0.id == id }) else { continue }
            var candidates: [StockSearchResult] = []
            var seenSymbols = Set<String>()
            for query in Self.importedPositionSearchQueries(for: candidate.name) {
                await searchStocks(query)
                for result in stockSearchResults where seenSymbols.insert(result.symbol).inserted {
                    candidates.append(result)
                }
            }
            let bestMatch = Self.bestImportedPositionMatch(for: candidate.name, in: candidates)
            if let bestMatch,
               let index = importedPositions.firstIndex(where: { $0.id == id }) {
                importedPositions[index].name = bestMatch.name
                importedPositions[index].symbol = bestMatch.symbol
            } else {
                unresolvedNames.append(candidate.name)
            }
        }
        clearStockSearch()
        screenshotImportMessage = unresolvedNames.isEmpty
            ? "证券代码已自动匹配，请核对后更新仓位"
            : "未能确认「\(unresolvedNames.joined(separator: "、"))」的证券代码，请手动输入后再更新"
    }

    func applyImportedPositionsPreservingUS() {
        guard !importedPositions.isEmpty else { return }
        let unresolvedNames = importedPositions.compactMap { position -> String? in
            let symbol = position.symbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return symbol.isEmpty ? position.name : nil
        }
        guard unresolvedNames.isEmpty else {
            screenshotImportMessage = "请先为「\(unresolvedNames.joined(separator: "、"))」手动输入证券代码"
            return
        }
        let imported = importedPositions
        let preservedUSPositions = positions.filter(Self.isUSPosition)
        var updatedPositions = preservedUSPositions
        for candidate in imported {
            if Self.isUSPosition(candidate),
               let symbol = candidate.symbol?.lowercased(),
               updatedPositions.contains(where: { $0.symbol?.lowercased() == symbol }) {
                continue
            }
            updatedPositions.append(candidate)
        }
        positions = updatedPositions
        importedPositions = []
        screenshotImportMessage = preservedUSPositions.isEmpty
            ? "已清空旧仓位并写入截图仓位"
            : "已写入截图仓位，并保留 \(preservedUSPositions.count) 条美股仓位"
        save()
        Task { await refreshMarketData() }
    }

    private static func importedPositionSearchQueries(for name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed.replacingOccurrences(of: #"[\s·•・_—–-]+"#, with: "", options: .regularExpression)
        var queries = [trimmed, compact]
        if let fundTypeRange = compact.range(of: #"(?i)ETF|LOF|基金"#, options: .regularExpression) {
            let core = String(compact[..<fundTypeRange.lowerBound])
            if core.count >= 2 { queries.append(core) }
        }
        var seen = Set<String>()
        return queries.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func bestImportedPositionMatch(
        for importedName: String,
        in results: [StockSearchResult]
    ) -> StockSearchResult? {
        var scored: [(result: StockSearchResult, score: Int)] = []
        for result in results {
            let score = importedPositionMatchScore(importedName, result.name)
            if score >= 75 {
                scored.append((result: result, score: score))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.result.name.count < rhs.result.name.count
            }
            return lhs.score > rhs.score
        }
        guard let best = scored.first else { return nil }
        if scored.count > 1, scored[1].score == best.score { return nil }
        return best.result
    }

    private static func importedPositionMatchScore(_ importedName: String, _ resultName: String) -> Int {
        let imported = normalizedSecurityName(importedName)
        let result = normalizedSecurityName(resultName)
        guard !imported.isEmpty, !result.isEmpty else { return 0 }
        if imported == result { return 140 }

        let shorterCount = min(imported.count, result.count)
        if shorterCount >= 4, imported.contains(result) || result.contains(imported) {
            return 110 + shorterCount
        }

        let commonPrefixCount = zip(imported, result).prefix { pair in pair.0 == pair.1 }.count
        var score = commonPrefixCount >= 4 ? 60 + commonPrefixCount : 0
        let importedCore = securityNameCore(imported)
        let resultCore = securityNameCore(result)
        if importedCore.count >= 3, importedCore == resultCore {
            score = max(score, 70)
        }
        return score
    }

    private static func normalizedSecurityName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[\s·•・_—–\-（）()]"#, with: "", options: .regularExpression)
    }

    private static func securityNameCore(_ value: String) -> String {
        guard let range = value.range(of: #"(?i)ETF|LOF|基金"#, options: .regularExpression) else {
            return value
        }
        return String(value[..<range.lowerBound])
    }

    private static func isUSPosition(_ position: Position) -> Bool {
        guard let rawSymbol = position.symbol?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSymbol.isEmpty else { return false }
        if rawSymbol.lowercased().hasPrefix("us") { return true }
        return rawSymbol.range(of: #"^[A-Za-z]{1,6}(?:[.\-][A-Za-z]{1,2})?$"#, options: .regularExpression) != nil
    }

    func discardImportedPositions() {
        importedPositions = []
        screenshot = nil
        screenshotImportMessage = nil
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
                // 推送频率:关闭(0)时仍每 30 分钟刷新一次列表，只是不发通知
                let minutes = self.newsPushIntervalMinutes > 0 ? self.newsPushIntervalMinutes : 30
                do {
                    try await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
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

    // MARK: - 自定义指数栏

    func isWatchingIndex(_ symbol: String) -> Bool {
        watchIndices.contains { $0.symbol == symbol }
    }

    func toggleWatchIndex(_ item: WatchIndex) {
        if let idx = watchIndices.firstIndex(where: { $0.symbol == item.symbol }) {
            watchIndices.remove(at: idx)
        } else {
            watchIndices.append(item)
        }
        persistWatchIndices()
    }

    func addWatchIndex(symbol: String, name: String) {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !watchIndices.contains(where: { $0.symbol == trimmed }) else { return }
        watchIndices.append(WatchIndex(symbol: trimmed, name: name))
        persistWatchIndices()
    }

    func removeWatchIndex(_ item: WatchIndex) {
        watchIndices.removeAll { $0.symbol == item.symbol }
        persistWatchIndices()
    }

    func resetWatchIndices() {
        watchIndices = IndexCatalog.defaults
        persistWatchIndices()
    }

    private func persistWatchIndices() {
        if let data = try? JSONEncoder().encode(watchIndices) {
            UserDefaults.standard.set(data, forKey: watchIndicesKey)
        }
        Task { await refreshMarketData() }
    }

    func savePreferences() {
        let d = UserDefaults.standard
        d.set(includeUSInReturn, forKey: includeUSInReturnKey)
        d.set(newsHoldingsOnly, forKey: newsHoldingsOnlyKey)
        d.set(newsPushIntervalMinutes, forKey: newsPushIntervalKey)
        // 新闻范围改变时立即重拉资讯（总收益是实时计算的，无需刷新行情）
        Task { await refreshNews() }
    }

    func refreshMarketData(includeTrend: Bool = true) async {
        guard !isLoadingMarket else { return }
        isLoadingMarket = true
        marketError = nil
        defer { isLoadingMarket = false }

        // 用户自定义的顶部指数栏（默认回落到内置 A 股指数）
        let indexList = watchIndices.isEmpty ? IndexCatalog.defaults : watchIndices
        let symbols = Set(indexList.map(\.symbol) + positions.compactMap(\.symbol).filter { !$0.isEmpty })

        do {
            let quotes = try await fetchQuotes(Array(symbols))
            marketIndices = indexList.map { item in
                let quote = quotes[item.symbol]
                return MarketIndexSnapshot(
                    id: item.symbol,
                    name: item.name,
                    price: quote?.price ?? 0,
                    change: quote?.change ?? 0,
                    changePercent: quote?.percent ?? 0
                )
            }

            var snapshots: [UUID: PositionMarketSnapshot] = [:]
            for position in positions {
                let symbol = position.symbol ?? ""
                let quote = quotes[symbol]
                let previous = positionMarkets[position.id]
                let session = MarketSessionResolver.session(for: symbol)
                let shouldRefreshLatestPrice = session.phase.shouldRefreshLatestPrice
                let displayedPrice = shouldRefreshLatestPrice
                    ? quote?.price
                    : (previous?.currentPrice ?? quote?.price)
                let changeAmount = shouldRefreshLatestPrice
                    ? quote?.change ?? 0
                    : (previous?.changeAmount ?? quote?.change ?? 0)
                let changePercent = shouldRefreshLatestPrice
                    ? quote?.percent ?? position.change
                    : (previous?.changePercent ?? quote?.percent ?? position.change)
                // 分时走势与"是否刷新最新价"解耦：午休/隔夜等时段最新价可以冻结，
                // 但当天的真实分时(上午/收盘前的走势)仍要展示，不能退回合成正弦波。
                var liveTrend: [Double]? = nil
                if includeTrend, !symbol.isEmpty {
                    liveTrend = try? await fetchMinuteTrend(symbol)
                }

                let resolvedTrend: [Double]
                let hasRealTrend: Bool
                if let liveTrend, liveTrend.count > 1 {
                    resolvedTrend = liveTrend
                    hasRealTrend = true
                } else if let previous, previous.isLive, previous.trend.count > 1 {
                    // 未到分时刷新周期时，复用上一次抓到的真实走势
                    resolvedTrend = previous.trend
                    hasRealTrend = true
                } else {
                    resolvedTrend = Self.fallbackTrend(seed: changePercent)
                    hasRealTrend = false
                }

                snapshots[position.id] = PositionMarketSnapshot(
                    currentPrice: displayedPrice,
                    changeAmount: changeAmount,
                    changePercent: changePercent,
                    trend: resolvedTrend,
                    isLive: hasRealTrend
                )
            }
            positionMarkets = snapshots
            marketUpdatedAt = Date()
        } catch {
            marketError = "行情连接失败，当前展示本地走势"
            marketIndices = indexList.map {
                MarketIndexSnapshot(id: $0.symbol, name: $0.name, price: 0, change: 0, changePercent: 0)
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

    private struct AlpacaBar: Decodable {
        let close: Double

        private enum CodingKeys: String, CodingKey {
            case close = "c"
        }
    }

    private struct AlpacaTrade: Decodable {
        let price: Double

        private enum CodingKeys: String, CodingKey {
            case price = "p"
        }
    }

    private struct AlpacaQuote: Decodable {
        let askPrice: Double?
        let bidPrice: Double?

        private enum CodingKeys: String, CodingKey {
            case askPrice = "ap"
            case bidPrice = "bp"
        }

        var midpoint: Double? {
            guard let askPrice, let bidPrice, askPrice > 0, bidPrice > 0 else { return nil }
            return (askPrice + bidPrice) / 2
        }
    }

    private struct AlpacaSnapshot: Decodable {
        let latestTrade: AlpacaTrade?
        let latestQuote: AlpacaQuote?
        let minuteBar: AlpacaBar?
        let previousDailyBar: AlpacaBar?

        private enum CodingKeys: String, CodingKey {
            case latestTrade
            case latestQuote
            case minuteBar
            case previousDailyBar = "prevDailyBar"
        }
    }

    private struct AlpacaBarsResponse: Decodable {
        let bars: [String: [AlpacaBar]]?
    }

    private struct YahooChartResponse: Decodable {
        let chart: YahooChart
    }

    private struct YahooChart: Decodable {
        let result: [YahooChartResult]?
    }

    private struct YahooChartResult: Decodable {
        let meta: YahooChartMeta
        let indicators: YahooChartIndicators
    }

    private struct YahooChartMeta: Decodable {
        let regularMarketPrice: Double?
        let chartPreviousClose: Double?
        let previousClose: Double?
    }

    private struct YahooChartIndicators: Decodable {
        let quote: [YahooChartQuote]
    }

    private struct YahooChartQuote: Decodable {
        let close: [Double?]?
    }

    private struct NasdaqQuoteInfoResponse: Decodable {
        let data: NasdaqQuoteData?
    }

    private struct NasdaqQuoteData: Decodable {
        let primaryData: NasdaqQuotePriceData?
    }

    private struct NasdaqQuotePriceData: Decodable {
        let lastSalePrice: String?
        let netChange: String?
        let percentageChange: String?
    }

    private func fetchQuotes(_ symbols: [String]) async throws -> [String: QuoteValue] {
        guard !symbols.isEmpty else {
            return [:]
        }
        let querySymbols = symbols.flatMap { symbol -> [String] in
            symbol.lowercased().hasPrefix("us")
                ? ["s_\(symbol)", symbol]
                : ["s_\(symbol)"]
        }
        guard let url = URL(string: "https://qt.gtimg.cn/q=" + querySymbols.joined(separator: ",")) else {
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
            let key = rawKey
                .replacingOccurrences(of: "v_s_", with: "")
                .replacingOccurrences(of: "v_", with: "")
            let start = line.index(after: firstQuote)
            let fields = line[start..<lastQuote].split(separator: "~", omittingEmptySubsequences: false)
            // 完整行情(美股 v_us…)里 [30] 是时间戳，涨跌额/涨跌幅在 [31]/[32]；
            // 简版行情(v_s_…)里在 [4]/[5]。之前用了 [30]/[31] 导致美股涨跌幅解析失败、恒为 0。
            guard fields.count > 5,
                  let price = Double(fields[3]),
                  let change = Double(fields.count > 32 ? fields[31] : fields[4]),
                  let percent = Double(fields.count > 32 ? fields[32] : fields[5]) else { continue }
            result[key] = QuoteValue(price: price, change: change, percent: percent)
        }

        var alpacaResolvedSymbols = Set<String>()
        let overnightSymbols = symbols.filter {
            $0.lowercased().hasPrefix("us")
                && MarketSessionResolver.session(for: $0).phase == .overnight
        }
        if !overnightSymbols.isEmpty {
            if hasAlpacaCredentials {
                do {
                    let overnightQuotes = try await fetchAlpacaOvernightQuotes(
                        overnightSymbols,
                        fallbackQuotes: result
                    )
                    for (symbol, quote) in overnightQuotes {
                        result[symbol] = quote
                        alpacaResolvedSymbols.insert(symbol)
                    }
                    alpacaStatus = overnightQuotes.isEmpty
                        ? "Alpaca 已连接，但当前持仓暂时没有夜盘报价"
                        : "Alpaca 夜盘已连接 · 免费实时指示价"
                } catch {
                    alpacaStatus = "Alpaca 夜盘连接失败：\(error.localizedDescription)"
                }
            } else {
                alpacaStatus = "未配置 Alpaca，夜盘将继续显示盘后最后价格"
            }
        }

        for symbol in symbols where shouldFetchUSPrePostQuote(for: symbol)
            && !alpacaResolvedSymbols.contains(symbol) {
            if let quote = try? await fetchUSPrePostQuote(symbol) {
                result[symbol] = quote
            }
        }
        return result
    }

    private func shouldFetchUSPrePostQuote(for symbol: String) -> Bool {
        let normalized = symbol.lowercased()
        guard normalized.hasPrefix("us") else { return false }
        return MarketSessionResolver.session(for: normalized).phase.shouldRefreshLatestPrice
    }

    private enum AlpacaMarketError: LocalizedError {
        case invalidCredentials
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .invalidCredentials:
                return "API Key 无效或没有行情权限"
            case let .badResponse(status):
                return "服务返回 HTTP \(status)"
            }
        }
    }

    private func alpacaRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(alpacaAPIKey, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(alpacaAPISecret, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("StockPet/0.5", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validateAlpacaResponse(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw AlpacaMarketError.invalidCredentials
        }
        guard status == 200 else {
            throw AlpacaMarketError.badResponse(status)
        }
    }

    private func fetchAlpacaOvernightQuotes(
        _ symbols: [String],
        fallbackQuotes: [String: QuoteValue]
    ) async throws -> [String: QuoteValue] {
        let tickerBySymbol = Dictionary(uniqueKeysWithValues: symbols.map { symbol in
            (symbol, String(symbol.dropFirst(2)).uppercased())
        })
        let tickers = tickerBySymbol.values.filter { !$0.isEmpty }.sorted()
        guard !tickers.isEmpty,
              var components = URLComponents(string: "https://data.alpaca.markets/v2/stocks/snapshots") else {
            return [:]
        }
        components.queryItems = [
            URLQueryItem(name: "symbols", value: tickers.joined(separator: ",")),
            URLQueryItem(name: "feed", value: "overnight")
        ]
        guard let url = components.url else { return [:] }

        let (data, response) = try await URLSession.shared.data(for: alpacaRequest(url: url))
        try validateAlpacaResponse(response)
        let snapshots = try JSONDecoder().decode([String: AlpacaSnapshot].self, from: data)

        var quotes: [String: QuoteValue] = [:]
        for (symbol, ticker) in tickerBySymbol {
            guard let snapshot = snapshots[ticker] ?? snapshots[ticker.lowercased()],
                  let price = snapshot.latestQuote?.midpoint
                    ?? snapshot.minuteBar?.close
                    ?? snapshot.latestTrade?.price,
                  price > 0 else { continue }
            // 夜盘涨跌以刚结束的美股常规/盘后最后价为基准；Alpaca 的前日 K 线只作兜底。
            let previousClose = fallbackQuotes[symbol]?.price ?? snapshot.previousDailyBar?.close ?? price
            let change = price - previousClose
            let percent = previousClose == 0 ? 0 : change / previousClose * 100
            quotes[symbol] = QuoteValue(price: price, change: change, percent: percent)
        }
        return quotes
    }

    private func fetchUSPrePostQuote(_ symbol: String) async throws -> QuoteValue? {
        // 新浪 gb_ 接口国内可直接访问，含盘前/盘后价；Yahoo/Nasdaq 国内基本连不上，仅作兜底。
        if let quote = try? await fetchSinaUSQuote(symbol) {
            return quote
        }
        if let quote = try? await fetchYahooUSPrePostQuote(symbol) {
            return quote
        }
        return try await fetchNasdaqUSQuote(symbol)
    }

    /// 新浪美股行情 hq_str_gb_<ticker>：字段 [1]=最新价 [2]=涨跌幅% [4]=涨跌额，
    /// 盘前/盘后期间 [1] 会跟随延时行情更新（需带 finance.sina.com.cn 的 Referer）。
    private func fetchSinaUSQuote(_ symbol: String) async throws -> QuoteValue? {
        let ticker = String(symbol.dropFirst(2)).lowercased()
        guard !ticker.isEmpty,
              let url = URL(string: "https://hq.sinajs.cn/list=gb_\(ticker)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .isoLatin1),
              let firstQuote = text.firstIndex(of: "\""),
              let lastQuote = text.lastIndex(of: "\""), firstQuote < lastQuote else {
            return nil
        }
        let start = text.index(after: firstQuote)
        let fields = text[start..<lastQuote].split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count > 4,
              let price = Double(fields[1]), price > 0,
              let percent = Double(fields[2]) else {
            return nil
        }
        let change = Double(fields[4]) ?? (price * percent / (100 + percent))
        return QuoteValue(price: price, change: change, percent: percent)
    }

    private func fetchYahooUSPrePostQuote(_ symbol: String) async throws -> QuoteValue? {
        let ticker = String(symbol.dropFirst(2)).uppercased()
        guard !ticker.isEmpty,
              var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(ticker)") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "range", value: "1d"),
            URLQueryItem(name: "interval", value: "1m"),
            URLQueryItem(name: "includePrePost", value: "true")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        guard let chart = decoded.chart.result?.first else { return nil }

        let latestPrice = chart.indicators.quote
            .first?
            .close?
            .reversed()
            .compactMap { $0 }
            .first ?? chart.meta.regularMarketPrice
        guard let price = latestPrice else { return nil }

        let previousClose = chart.meta.chartPreviousClose ?? chart.meta.previousClose ?? price
        let change = price - previousClose
        let percent = previousClose == 0 ? 0 : change / previousClose * 100
        return QuoteValue(price: price, change: change, percent: percent)
    }

    private func fetchNasdaqUSQuote(_ symbol: String) async throws -> QuoteValue? {
        let ticker = String(symbol.dropFirst(2)).uppercased()
        guard !ticker.isEmpty,
              var components = URLComponents(string: "https://api.nasdaq.com/api/quote/\(ticker)/info") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "assetclass", value: "stocks")]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoded = try JSONDecoder().decode(NasdaqQuoteInfoResponse.self, from: data)
        guard let primaryData = decoded.data?.primaryData,
              let price = Self.parseMarketNumber(primaryData.lastSalePrice) else {
            return nil
        }

        return QuoteValue(
            price: price,
            change: Self.parseMarketNumber(primaryData.netChange) ?? 0,
            percent: Self.parseMarketNumber(primaryData.percentageChange) ?? 0
        )
    }

    private static func parseMarketNumber(_ value: String?) -> Double? {
        guard let value else { return nil }
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "+", with: "")
        guard !cleaned.isEmpty, cleaned.lowercased() != "n/a" else { return nil }
        return Double(cleaned)
    }

    private func fetchMinuteTrend(_ symbol: String) async throws -> [Double] {
        if symbol.lowercased().hasPrefix("us"),
           MarketSessionResolver.session(for: symbol).phase == .overnight,
           hasAlpacaCredentials,
           let overnightTrend = try? await fetchAlpacaOvernightTrend(symbol),
           overnightTrend.count > 1 {
            return overnightTrend
        }

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

    private func fetchAlpacaOvernightTrend(_ symbol: String) async throws -> [Double] {
        let ticker = String(symbol.dropFirst(2)).uppercased()
        guard !ticker.isEmpty,
              var components = URLComponents(string: "https://data.alpaca.markets/v2/stocks/bars") else {
            return []
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        components.queryItems = [
            URLQueryItem(name: "symbols", value: ticker),
            URLQueryItem(name: "timeframe", value: "1Min"),
            URLQueryItem(name: "start", value: formatter.string(from: Date().addingTimeInterval(-12 * 60 * 60))),
            URLQueryItem(name: "end", value: formatter.string(from: Date())),
            URLQueryItem(name: "feed", value: "boats"),
            URLQueryItem(name: "adjustment", value: "raw"),
            URLQueryItem(name: "sort", value: "asc"),
            URLQueryItem(name: "limit", value: "1000")
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await URLSession.shared.data(for: alpacaRequest(url: url))
        try validateAlpacaResponse(response)
        let decoded = try JSONDecoder().decode(AlpacaBarsResponse.self, from: data)
        return (decoded.bars?[ticker] ?? []).map(\.close)
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
    /// 参与总收益计算的持仓（可在设置里选择是否算入美股）
    var returnPositions: [Position] {
        includeUSInReturn
            ? positions
            : positions.filter { !($0.symbol?.lowercased().hasPrefix("us") ?? false) }
    }

    var totalReturn: Double {
        let ps = returnPositions
        guard !ps.isEmpty else { return 0 }
        let totalValue = ps.reduce(0) { $0 + max(0, $1.value) }
        if totalValue > 0 {
            return ps.reduce(0) { result, position in
                result + max(0, position.value) * todayChange(for: position)
            } / totalValue
        }
        return ps.reduce(0) { $0 + todayChange(for: $1) } / Double(ps.count)
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

    private struct SinaRollResponse: Decodable {
        struct Payload: Decodable {
            struct Item: Decodable {
                let docid: String?
                let title: String?
                let url: String?
                let media_name: String?
                let ctime: String?
            }
            let data: [Item]
        }
        let result: Payload
    }

    /// 持仓相关关键词(名称 + 数字代码)，用于"只看持仓新闻"过滤
    private var holdingKeywords: [String] {
        positions.flatMap { position -> [String] in
            var keywords: [String] = []
            let name = position.name.trimmingCharacters(in: .whitespaces)
            if name.count >= 2 { keywords.append(name) }
            if let symbol = position.symbol {
                let code = symbol.filter { $0.isNumber }
                if code.count >= 4 { keywords.append(code) }
            }
            return keywords
        }
    }

    func refreshNews() async {
        guard !isLoadingNews else { return }
        isLoadingNews = true
        newsError = nil
        defer { isLoadingNews = false }

        // 国内财经源（新浪财经滚动 · 全部财经）：链接直达 finance.sina.com.cn，
        // 国内浏览器可直接打开，不再经过 Google 跳转。
        guard let url = URL(string: "https://feed.mix.sina.com.cn/api/roll/get?pageid=153&lid=2509&num=20&page=1") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("StockPet/0.5", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(SinaRollResponse.self, from: data)

            var gathered: [StockNews] = []
            for item in decoded.result.data {
                guard let title = item.title, !title.isEmpty,
                      let urlString = item.url,
                      let link = URL(string: urlString) else { continue }
                let timestamp = Double(item.ctime ?? "") ?? Date().timeIntervalSince1970
                let source = (item.media_name?.isEmpty == false) ? item.media_name! : "财经"
                gathered.append(StockNews(
                    id: item.docid ?? urlString,
                    stock: "财经热点",
                    title: title,
                    source: source,
                    link: link,
                    publishedAt: Date(timeIntervalSince1970: timestamp)
                ))
            }

            // 只看持仓新闻:按持仓名称/代码过滤大盘财经流
            if newsHoldingsOnly {
                let keywords = holdingKeywords
                if !keywords.isEmpty {
                    gathered = gathered.filter { news in
                        keywords.contains { !$0.isEmpty && news.title.contains($0) }
                    }
                }
            }

            var seenTitles = Set<String>()
            newsItems = gathered
                .sorted { $0.publishedAt > $1.publishedAt }
                .filter { seenTitles.insert($0.title).inserted }
                .prefix(9)
                .map { $0 }

            // 推送频率为"关闭"时不发通知，只更新列表
            if newsPushIntervalMinutes > 0 {
                let unnotifiedNews = newsItems.filter {
                    !hiddenNewsIDs.contains($0.id) && !notifiedNewsIDs.contains($0.id)
                }
                sendNewsNotification(unnotifiedNews)
            }
        } catch {
            newsError = "资讯暂时不可用"
        }
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

    private func markNewsAsNotified(_ ids: [String]) {
        notifiedNewsIDs.formUnion(ids.filter { !$0.isEmpty })
        UserDefaults.standard.set(Array(Array(notifiedNewsIDs).suffix(200)), forKey: Self.notifiedNewsKey)
    }

    private func requestNotificationAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func sendSystemNotification(
        identifier: String,
        title: String,
        body: String,
        threadIdentifier: String,
        userInfo: [AnyHashable: Any] = [:],
        completion: ((Bool) -> Void)? = nil
    ) {
        guard notificationsEnabled else {
            completion?(false)
            return
        }

        let scheduleNotification = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = threadIdentifier
            content.userInfo = userInfo
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                completion?(error == nil)
            }
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                scheduleNotification()
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
                    if allowed {
                        scheduleNotification()
                    } else {
                        completion?(false)
                    }
                }
            case .denied:
                completion?(false)
            @unknown default:
                completion?(false)
            }
        }
    }

    private func sendNewsNotification(_ items: [StockNews]) {
        guard notificationsEnabled, let newest = items.first else { return }
        let ids = items.map(\.id)
        let title = items.count == 1 ? "\(newest.stock) · 热门资讯" : "持仓热门资讯"
        let body = items.count == 1
            ? newest.title
            : "新增 \(items.count) 条，\(newest.stock)：\(newest.title)"
        var userInfo: [AnyHashable: Any] = [:]
        if let link = newest.link?.absoluteString {
            userInfo["link"] = link
        }

        sendSystemNotification(
            identifier: "stock-news-\(newest.id)",
            title: title,
            body: body,
            threadIdentifier: "stock-news",
            userInfo: userInfo
        ) { [weak self] delivered in
            guard delivered else { return }
            Task { @MainActor in
                self?.markNewsAsNotified(ids)
            }
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

        sendSystemNotification(
            identifier: "stock-alert-\(UUID().uuidString)",
            title: "持仓异动提醒",
            body: message,
            threadIdentifier: "stock-alert"
        )
    }
}

private let mainPetWindowTitle = "持仓宠物"
private let mainPetWindowExpandedKey = "stockPet.window.isExpanded.current.v1"
private let expandedWindowStaysOnTopKey = "stockPet.expandedWindow.staysOnTop.v1"

private func configureMainPetWindowPresentation(_ window: NSWindow, isExpanded: Bool, expandedStaysOnTop: Bool) {
    let shouldFloatAboveApps = !isExpanded || expandedStaysOnTop
    window.level = shouldFloatAboveApps ? .statusBar : .normal
    window.isMovableByWindowBackground = true
    window.styleMask = [.borderless, .fullSizeContentView]
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isOpaque = false
    window.backgroundColor = .clear
    window.canHide = !shouldFloatAboveApps
    window.collectionBehavior = shouldFloatAboveApps
        ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        : [.fullScreenAuxiliary]
}

private func configureMainPetWindowPresentationFromDefaults(_ window: NSWindow) {
    configureMainPetWindowPresentation(
        window,
        isExpanded: UserDefaults.standard.bool(forKey: mainPetWindowExpandedKey),
        expandedStaysOnTop: UserDefaults.standard.bool(forKey: expandedWindowStaysOnTopKey)
    )
}

private func defaultCompactWindowFrame(for window: NSWindow) -> NSRect {
    let size = window.frame.size
    let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
    let margin: CGFloat = 24
    return NSRect(
        x: visible.maxX - size.width - margin,
        y: visible.minY + margin,
        width: size.width,
        height: size.height
    )
}

private enum AnonymousUsageAnalytics {
    private static let installationIDKey = "stockPet.analytics.installationID.v1"
    private static let lastReportedDayKey = "stockPet.analytics.lastReportedDay.v1"
    private static let endpoint = URL(string: "https://mclarenai.cn/api/stock-pet/events/app-open")!

    static func reportAppOpenIfNeeded() {
        let defaults = UserDefaults.standard
        let today = chinaDayString()
        guard defaults.string(forKey: lastReportedDayKey) != today else { return }

        let installationID: String
        if let existing = defaults.string(forKey: installationIDKey), UUID(uuidString: existing) != nil {
            installationID = existing
        } else {
            installationID = UUID().uuidString.lowercased()
            defaults.set(installationID, forKey: installationIDKey)
        }

        let info = Bundle.main.infoDictionary
        let payload: [String: String] = [
            "installation_id": installationID,
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info?["CFBundleVersion"] as? String ?? "unknown",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "locale": Locale.current.identifier
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        Task {
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }
            defaults.set(today, forKey: lastReportedDayKey)
        }
    }

    private static func chinaDayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "StockPet", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
        UNUserNotificationCenter.current().delegate = self
        AnonymousUsageAnalytics.reportAppOpenIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let window = self.mainPetWindow else { return }
            UserDefaults.standard.set(false, forKey: mainPetWindowExpandedKey)
            configureMainPetWindowPresentation(window, isExpanded: false, expandedStaysOnTop: false)
            window.hasShadow = false
            window.setContentSize(NSSize(width: 150, height: 165))
            window.setFrame(defaultCompactWindowFrame(for: window), display: true)
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
        configureMainPetWindowPresentationFromDefaults(window)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.setIsVisible(true)
        window.orderFrontRegardless()
    }

    private func keepMainPetWindowFloating() {
        guard let window = mainPetWindow, !window.isMiniaturized else { return }
        let isExpanded = UserDefaults.standard.bool(forKey: mainPetWindowExpandedKey)
        let expandedStaysOnTop = UserDefaults.standard.bool(forKey: expandedWindowStaysOnTopKey)
        configureMainPetWindowPresentation(window, isExpanded: isExpanded, expandedStaysOnTop: expandedStaysOnTop)
        guard !isExpanded || expandedStaysOnTop else { return }
        window.setIsVisible(true)
        window.orderFrontRegardless()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
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
    private let edgeThickness: CGFloat = 7
    private let bottomEdgeThickness: CGFloat = 10
    private let topCornerSize: CGFloat = 20
    private let bottomCornerSize: CGFloat = 26
    private let topControlSafeHeight: CGFloat = 56

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: topControlSafeHeight)
                        .allowsHitTesting(false)
                    WindowResizeHandle(region: .left, onResizeEnded: onResizeEnded)
                    Color.clear
                        .frame(height: bottomCornerSize)
                        .allowsHitTesting(false)
                }
                .frame(width: edgeThickness)
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: topControlSafeHeight)
                        .allowsHitTesting(false)
                    WindowResizeHandle(region: .right, onResizeEnded: onResizeEnded)
                    Color.clear
                        .frame(height: bottomCornerSize)
                        .allowsHitTesting(false)
                }
                .frame(width: edgeThickness)
            }
            .zIndex(1)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: topCornerSize)
                        .allowsHitTesting(false)
                    WindowResizeHandle(region: .top, onResizeEnded: onResizeEnded)
                    Color.clear
                        .frame(width: topCornerSize)
                        .allowsHitTesting(false)
                }
                .frame(height: edgeThickness)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: bottomCornerSize)
                        .allowsHitTesting(false)
                    WindowResizeHandle(region: .bottom, onResizeEnded: onResizeEnded)
                    Color.clear
                        .frame(width: bottomCornerSize)
                        .allowsHitTesting(false)
                }
                .frame(height: bottomEdgeThickness)
            }
            .zIndex(1)
            WindowResizeHandle(region: .topLeft, onResizeEnded: onResizeEnded)
                .frame(width: topCornerSize, height: topCornerSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(2)
            WindowResizeHandle(region: .topRight, onResizeEnded: onResizeEnded)
                .frame(width: topCornerSize, height: topCornerSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(2)
            WindowResizeHandle(region: .bottomLeft, onResizeEnded: onResizeEnded)
                .frame(width: bottomCornerSize, height: bottomCornerSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .zIndex(2)
            WindowResizeHandle(region: .bottomRight, onResizeEnded: onResizeEnded)
                .frame(width: bottomCornerSize, height: bottomCornerSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .zIndex(2)
        }
    }
}

/// 全局动画调速（帧动画皮肤播放速度倍率），由调试面板控制
enum PetAnimTuning {
    static var speedMultiplier: Double = 1.0
}

enum PetAnimationAction: String, CaseIterable, Codable, Hashable, Identifiable {
    case idle
    case happy
    case sad
    case waving
    case jump
    case failed
    case waiting
    case review
    case runleft
    case runright
    case run
    case walk
    case attack
    case shoot
    case hurt
    case crash

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idle: return "待机"
        case .happy: return "开心"
        case .sad: return "难过"
        case .waving: return "挥手"
        case .jump: return "跳跃"
        case .failed: return "倒下"
        case .waiting: return "小憩"
        case .review: return "思考"
        case .runleft: return "向左跑"
        case .runright: return "向右跑"
        case .run: return "奔跑"
        case .walk: return "行走"
        case .attack: return "攻击"
        case .shoot: return "发射"
        case .hurt: return "受击"
        case .crash: return "摔倒"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "figure.stand"
        case .happy: return "face.smiling"
        case .sad: return "cloud.rain"
        case .waving: return "hand.wave"
        case .jump: return "arrow.up"
        case .failed: return "arrow.down.to.line"
        case .waiting: return "zzz"
        case .review: return "text.magnifyingglass"
        case .runleft: return "arrow.left"
        case .runright: return "arrow.right"
        case .run: return "figure.run"
        case .walk: return "figure.walk"
        case .attack: return "bolt.fill"
        case .shoot: return "scope"
        case .hurt: return "bandage"
        case .crash: return "exclamationmark.triangle"
        }
    }

    var playbackSpeed: Double {
        switch self {
        case .runleft, .runright, .run: return 6.0
        case .walk: return 4.5
        case .attack, .shoot, .jump: return 5.0
        case .waiting: return 2.6
        default: return 4.0
        }
    }
}

/// 运行时探测皮肤某个动作的帧数（skin_<id>_<state>_N 连号计数），结果缓存。
/// 好处：新皮肤只要把帧文件放进资源就自动识别，不用改代码里的帧数表。
enum PetFrameProbe {
    nonisolated(unsafe) private static var cache: [String: Int] = [:]

    static func frameCount(skin: String, state: String) -> Int {
        let key = "\(skin)|\(state)"
        if let cached = cache[key] { return cached }
        var count = 0
        while count < 24, NSImage(named: NSImage.Name("skin_\(skin)_\(state)_\(count)")) != nil {
            count += 1
        }
        cache[key] = count
        return count
    }
}

struct PetAnimationSettings: Codable, Equatable {
    var scale: Double = 1.0
    var primaryAction: PetAnimationAction = .idle
    var hoverAction: PetAnimationAction = .happy
    var positiveAction: PetAnimationAction = .happy
    var negativeAction: PetAnimationAction = .sad

    static let `default` = PetAnimationSettings()
}

@MainActor
final class PetDebugState: ObservableObject {
    private static let appearanceSettingsKey = "stockPet.appearanceAnimationSettings.v1"

    @Published var isMockingReturn = false
    @Published var mockReturnRate = 0.0
    @Published var actionToken = UUID()
    @Published var previewAction: PetAnimationAction?
    @Published private(set) var appearanceSettings: [String: PetAnimationSettings]

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
        if let data = UserDefaults.standard.data(forKey: Self.appearanceSettingsKey),
           let saved = try? JSONDecoder().decode([String: PetAnimationSettings].self, from: data) {
            appearanceSettings = saved
        } else {
            appearanceSettings = [:]
        }
        overrideEnabled = UserDefaults.standard.bool(forKey: "stockPet.mockOverride.enabled.v1")
        overrideValue = UserDefaults.standard.double(forKey: "stockPet.mockOverride.value.v1")
        let savedSpeed = UserDefaults.standard.double(forKey: "stockPet.animSpeed.v1")
        speedMultiplier = savedSpeed > 0 ? savedSpeed : 1.0
        PetAnimTuning.speedMultiplier = speedMultiplier
    }

    func settings(for appearance: PetAppearance) -> PetAnimationSettings {
        var settings = appearanceSettings[appearance.rawValue] ?? .default
        let available = Set(appearance.availableAnimationActions)
        if !available.contains(settings.primaryAction) { settings.primaryAction = .idle }
        if !available.contains(settings.hoverAction) {
            settings.hoverAction = available.contains(.happy) ? .happy : .idle
        }
        if !available.contains(settings.positiveAction) {
            settings.positiveAction = available.contains(.happy) ? .happy : .idle
        }
        if !available.contains(settings.negativeAction) {
            settings.negativeAction = available.contains(.sad) ? .sad : .idle
        }
        return settings
    }

    func updateSettings(
        for appearance: PetAppearance,
        _ update: (inout PetAnimationSettings) -> Void
    ) {
        var settings = settings(for: appearance)
        update(&settings)
        settings.scale = min(2.0, max(0.5, settings.scale))
        appearanceSettings[appearance.rawValue] = settings
        guard let data = try? JSONEncoder().encode(appearanceSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.appearanceSettingsKey)
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
    /// 左右跑动帧数（0 表示该皮肤没有跑动动画）
    var runFrames: Int = 0
}

enum PetAppearance: String, CaseIterable, Identifiable {
    case robot, mech, polar
    case gptniang
    case labubu, chiikawa, usagi, hachiware, capy, shuitunlulu, deskotter, nai, gugugaga, crybaby
    case beretbear, woolbell, bubu, jokebear, obear
    case caishen
    case fleetsnowfluff, kunkunchick, yuexinmiao, pingo, guanmiao, advzombie
    case pikachu
    case gian, suneo, shizuka
    case shinchan, maruko, atom, sailormoon
    case kagome, kaitokid, heimerdinger
    case yantianzong, cubaibai, sakiko, nimbus, yamada

    var id: String { rawValue }

    static var availableCases: [PetAppearance] {
#if LOCAL_EXTENDED_SKINS
        Array(allCases)
#elseif PUBLIC_CREATOR_SKINS
        [
            .robot, .mech, .polar, .gptniang,
            .pikachu, .gian, .suneo, .shizuka,
            .shinchan, .maruko, .atom, .sailormoon,
            .kagome, .kaitokid, .heimerdinger,
            .yantianzong, .cubaibai, .sakiko, .nimbus, .yamada
        ]
#else
        [.robot, .mech, .polar]
#endif
    }

    var name: String {
        switch self {
        case .robot: return "行情机器人"
        case .mech: return "涨跌机甲"
        case .polar: return "红绿北极熊"
        case .gptniang: return "GPT娘"
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
        case .caishen: return "财神爷"
        case .fleetsnowfluff: return "雪绒码农"
        case .kunkunchick: return "坤坤鸡"
        case .yuexinmiao: return "月薪喵"
        case .pingo: return "企鹅Pingo"
        case .guanmiao: return "官喵"
        case .advzombie: return "冒险僵尸"
        case .pikachu: return "Pikachu"
        case .gian: return "哆啦A梦·胖虎"
        case .suneo: return "哆啦A梦·小夫"
        case .shizuka: return "哆啦A梦·静香"
        case .shinchan: return "蜡笔小新"
        case .maruko: return "樱桃小丸子"
        case .atom: return "铁臂阿童木"
        case .sailormoon: return "美少女战士"
        case .kagome: return "犬夜叉·戈薇"
        case .kaitokid: return "怪盗基德"
        case .heimerdinger: return "LoL 黑默丁格"
        case .yantianzong: return "剑网3·衍天宗"
        case .cubaibai: return "剑网3·醋摆摆"
        case .sakiko: return "丰川祥子"
        case .nimbus: return "筋斗云小孩"
        case .yamada: return "山田"
        }
    }

    /// 帧动画皮肤规格（nil 表示非帧动画皮肤）
    var skinSpec: PetSkinSpec? {
        switch self {
        case .mech:
            return PetSkinSpec(idleFrames: 10, happyFrames: 10, sadFrames: 10)
        case .polar:
            return PetSkinSpec(idleFrames: 12, happyFrames: 12, sadFrames: 10)
        case .gptniang:
            return PetSkinSpec(idleFrames: 6, happyFrames: 9, sadFrames: 8, runFrames: 8)
        case .labubu, .chiikawa, .usagi, .hachiware, .capy, .shuitunlulu, .deskotter, .nai, .gugugaga, .crybaby:
            return PetSkinSpec(idleFrames: 6, happyFrames: 9, sadFrames: 8, runFrames: 8)
        case .beretbear, .woolbell:
            return PetSkinSpec(idleFrames: 6, happyFrames: 9, sadFrames: 8, runFrames: 8)
        case .bubu, .jokebear, .obear:
            return PetSkinSpec(idleFrames: 6, happyFrames: 9, sadFrames: 8, runFrames: 8)
        case .caishen:
            return PetSkinSpec(idleFrames: 6, happyFrames: 6, sadFrames: 6)
        case .fleetsnowfluff, .kunkunchick, .yuexinmiao, .pingo, .guanmiao, .advzombie:
            return PetSkinSpec(idleFrames: 6, happyFrames: 6, sadFrames: 6, runFrames: 8)
        case .pikachu, .gian, .suneo, .shizuka, .shinchan, .maruko, .atom, .sailormoon,
             .kagome, .kaitokid, .heimerdinger, .yantianzong, .cubaibai, .sakiko, .nimbus, .yamada:
            return PetSkinSpec(idleFrames: 6, happyFrames: 9, sadFrames: 8, runFrames: 8)
        default:
            return nil
        }
    }

    var availableAnimationActions: [PetAnimationAction] {
        if self == .robot {
            return [.idle, .happy, .sad]
        }
        return PetAnimationAction.allCases.filter { animationFrameCount(for: $0) > 0 }
    }

    func animationFrameCount(for action: PetAnimationAction) -> Int {
        switch self {
        case .robot:
            return [.idle, .happy, .sad].contains(action) ? 1 : 0
        case .mech:
            switch action {
            case .idle, .happy, .sad: return 10
            case .run, .attack: return 8
            case .shoot: return 4
            case .crash: return 10
            default: return 0
            }
        case .polar:
            switch action {
            case .idle, .happy: return 12
            case .sad, .run, .jump, .crash: return 10
            case .walk: return 12
            case .attack: return 8
            case .hurt: return 6
            default: return 0
            }
        default:
            guard skinSpec != nil else { return 0 }
            // 运行时按资源文件自动探测帧数：素材有哪 9 个动作就能播哪 9 个
            return PetFrameProbe.frameCount(skin: rawValue, state: action.rawValue)
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
        case .gptniang: return "白发 GPT 娘，拖拽还会左右小跑"
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
        case .caishen: return "财神爷坐镇，涨了给你发红包，跌了替你镇宅"
        case .fleetsnowfluff: return "粉发墨镜小码农，边敲代码边盯盘"
        case .kunkunchick: return "篮球背带小鸡，涨了给你来段律动"
        case .yuexinmiao: return "月薪喵陪你搬砖，赚了加鸡腿"
        case .pingo: return "红围巾企鹅，冷静吃鱼稳如冰山"
        case .guanmiao: return "红袍官喵保佑，仓位步步高升"
        case .advzombie: return "冒险小僵尸，跌麻了也能爬起来"
        case .pikachu: return "电气鼠陪你盯盘，涨了放电庆祝"
        case .gian: return "胖虎气场全开，替你扛住行情波动"
        case .suneo: return "小夫灵活机敏，陪你观察盘面变化"
        case .shizuka: return "静香温柔陪伴，涨跌都保持从容"
        case .shinchan: return "小新负责搞怪，震荡行情也不无聊"
        case .maruko: return "小丸子陪你慢慢看盘，不被波动带节奏"
        case .atom: return "阿童木能量满格，守护你的核心仓位"
        case .sailormoon: return "月野兔变身守护，收益转正一起庆祝"
        case .kagome: return "戈薇穿越行情波动，陪你等待机会"
        case .kaitokid: return "怪盗基德优雅登场，捕捉盘面异动"
        case .heimerdinger: return "大发明家启动装置，研究每一次行情变化"
        case .yantianzong: return "衍天宗观星推演，陪你判断市场方向"
        case .cubaibai: return "醋摆摆执笔看盘，涨跌都淡定应对"
        case .sakiko: return "丰川祥子陪你专注工作，也关心今日收益"
        case .nimbus: return "乘着筋斗云穿越行情，涨了就加速"
        case .yamada: return "山田安静陪伴，工作看盘两不误"
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
    @AppStorage(expandedWindowStaysOnTopKey) private var expandedWindowStaysOnTop = false
    @State private var isExpanded = false
    @State private var showingNews = false
    @State private var hoveringCompact = false
    @State private var compactPetHovering = false
    @State private var compactWindowFrameBeforeExpansion: NSRect?
    @GestureState private var draggingCompactWindow = false
    @State private var walkDirection = 0
    @State private var walkStopToken = UUID()
    @State private var dragEventMonitor: Any?
    @State private var lastWindowX: CGFloat?
    @State private var hoveringPet = false
    @State private var isScreenshotDropTargeted = false
    @State private var alertPulse = false
    @State private var motionToken = UUID()
    @State private var showingPetStore = false
    @State private var showingShareCard = false
    @State private var showingAlpacaSettings = false
    @State private var showingIndexSettings = false
    @State private var showingPreferences = false
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
    private let expandedWindowMinimumSize = NSSize(width: 360, height: 280)
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

    private var selectedAnimationSettings: PetAnimationSettings {
        debugState.settings(for: selectedAppearance)
    }

    private var appearanceScaleBinding: Binding<Double> {
        Binding(
            get: { selectedAnimationSettings.scale },
            set: { newValue in
                debugState.updateSettings(for: selectedAppearance) { $0.scale = newValue }
            }
        )
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

    private var compactPetSide: CGFloat { 116 * petScale }

    private var compactWindowSize: NSSize {
        // 侧边和顶部多留白：跑动/跳跃姿势会甩出精灵图中心区域，避免被窗口边裁切
        let visualSide = compactPetSide * CGFloat(selectedAnimationSettings.scale)
        return NSSize(width: visualSide + 92, height: visualSide + 104)
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
        .onChange(of: displayReturn) { _, _ in
            triggerPetMotion()
            if !isDebugWindow && !isExpanded {
                DispatchQueue.main.async {
                    resizeCompactWindowForReturn()
                }
            }
        }
        .onChange(of: selectedAnimationSettings.scale) { _, _ in
            guard !isDebugWindow, !isExpanded else { return }
            DispatchQueue.main.async {
                resizeCompactWindowForReturn()
            }
        }
        .onAppear {
            if !isDebugWindow {
                DispatchQueue.main.async {
                    resizeCompactWindowForReturn(animated: false)
                }
                installDragWalkMonitor()
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
        .sheet(isPresented: $showingAlpacaSettings) {
            alpacaSettingsPage
        }
        .sheet(isPresented: $showingIndexSettings) {
            IndexSettingsView(store: store)
        }
        .sheet(isPresented: $showingPreferences) {
            PreferencesView(store: store)
        }
        .onChange(of: debugState.actionToken) { _, _ in
            triggerPetMotion()
        }
        .onDisappear {
            if isDebugWindow { resetDebugState() }
            if let monitor = dragEventMonitor {
                NotificationCenter.default.removeObserver(monitor)
                dragEventMonitor = nil
            }
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
                appearance: selectedAppearance,
                animationSettings: selectedAnimationSettings,
                previewAction: debugState.previewAction,
                walkDirection: walkDirection
            )
            .frame(width: compactPetSide, height: compactPetSide)
            .id(debugState.actionToken)
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
                .offset(y: compactPetSide * CGFloat(selectedAnimationSettings.scale) / 2 + 16)
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
                HStack {
                    Spacer()
                    Button {
                        hoveringCompact = false
                        showingPreferences = true
                    } label: {
                        Circle()
                            .fill(.black.opacity(0.62))
                            .frame(width: 25, height: 25)
                            .overlay(Circle().stroke(.white.opacity(0.20)))
                            .overlay(
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                    .allowsWindowActivationEvents()
                    .accessibilityLabel("设置")
                    .help("设置")
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
                appearance: selectedAppearance,
                animationSettings: selectedAnimationSettings,
                previewAction: debugState.previewAction
            )
            .frame(width: 150, height: 150)
            .id(debugState.actionToken)
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
            let usesPeekLayout = proxy.size.width < 820 || proxy.size.height < 540
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
                toolbarIcon("moon.stars.fill", help: "美股夜盘设置") {
                    showingAlpacaSettings = true
                }
                toolbarIcon(
                    expandedWindowStaysOnTop ? "pin.fill" : "pin",
                    help: expandedWindowStaysOnTop ? "取消置顶" : "保持置顶",
                    action: toggleExpandedWindowPriority
                )
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
                toolbarIcon("slider.horizontal.3", help: "自定义指数栏") { showingIndexSettings = true }
                toolbarIcon("gearshape.fill", help: "设置") { showingPreferences = true }
                toolbarIcon("bag.fill", help: "宠物商城") { showingPetStore = true }
                toolbarIcon("moon.stars.fill", help: "美股夜盘设置") { showingAlpacaSettings = true }
                toolbarIcon("ladybug.fill", help: "调试", action: openDebugPanel)
                toolbarIcon(
                    expandedWindowStaysOnTop ? "pin.fill" : "pin",
                    help: expandedWindowStaysOnTop ? "取消置顶" : "保持置顶",
                    action: toggleExpandedWindowPriority
                )
            }
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
            let nameWidth = max(180, min(240, proxy.size.width * 0.21))
            let chartWidth = max(180, min(280, proxy.size.width * 0.25))
            let chartToValueGap: CGFloat = 28
            let indexCardWidth: CGFloat = 150
            let indexCardSpacing: CGFloat = 10
            let indexHorizontalPadding: CGFloat = 20
            let indexToTableGap: CGFloat = 14
            let indexStripContentWidth = CGFloat(displayedIndices.count) * indexCardWidth
                + CGFloat(max(0, displayedIndices.count - 1)) * indexCardSpacing
                + indexHorizontalPadding * 2
            let indexStripWidth = max(proxy.size.width, indexStripContentWidth)
            let totalPositionValue = store.positions.reduce(0) { $0 + max(0, $1.value) }
            let tableWidth = max(920, proxy.size.width)
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
                        Text(store.marketError ?? (hasOvernightUSPosition ? store.alpacaStatus : "主要指数与持仓分时"))
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
                    HStack(spacing: indexCardSpacing) {
                        ForEach(displayedIndices) { index in
                            indexCard(index)
                        }
                    }
                    .padding(.horizontal, indexHorizontalPadding)
                    .frame(width: indexStripWidth, alignment: .center)
                }
                .frame(height: 92)
                .padding(.bottom, indexToTableGap)

                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("名称 / 代码").frame(width: nameWidth, alignment: .leading)
                            Text("当日分时").frame(width: chartWidth, alignment: .leading)
                            Text("持仓金额").frame(width: 100, alignment: .leading)
                                .padding(.leading, chartToValueGap)
                            Text("仓位占比").frame(width: 72, alignment: .leading)
                            Text("最新价").frame(width: 84, alignment: .leading)
                            Text("当日涨跌").frame(width: 88, alignment: .leading)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                        .padding(.horizontal, 20)
                        .frame(height: 36)
                        .background(.black.opacity(0.16))

                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(store.positions) { position in
                                    positionMarketRow(
                                        position,
                                        nameWidth: nameWidth,
                                        chartWidth: chartWidth,
                                        chartToValueGap: chartToValueGap,
                                        totalPositionValue: totalPositionValue
                                    )
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
            let availableWidth = max(360, proxy.size.width)
            let showsTrend = availableWidth >= 430
            let horizontalPadding: CGFloat = availableWidth < 430 ? 10 : 14
            let priceWidth: CGFloat = availableWidth < 430 ? 58 : 68
            let changeWidth: CGFloat = availableWidth < 430 ? 64 : 68
            let showsPositionColumns = availableWidth >= 600
            let nameWidth: CGFloat = showsPositionColumns ? max(130, min(170, availableWidth * 0.26)) : 0
            let positionValueWidth: CGFloat = 72
            let allocationWidth: CGFloat = 48
            let chartWidth: CGFloat = max(82, min(120, availableWidth * 0.19))
            let totalPositionValue = store.positions.reduce(0) { $0 + max(0, $1.value) }
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

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("股票").frame(
                            width: showsPositionColumns ? nameWidth : nil,
                            alignment: .leading
                        )
                        .frame(maxWidth: showsPositionColumns ? nil : .infinity, alignment: .leading)
                        if showsTrend {
                            Text("分时").frame(width: chartWidth, alignment: .leading)
                        }
                        if showsPositionColumns {
                            Text("仓位资金").frame(width: positionValueWidth, alignment: .leading)
                            Text("占比").frame(width: allocationWidth, alignment: .leading)
                        }
                        Text("最新").frame(width: priceWidth, alignment: .leading)
                        Text("涨跌").frame(width: changeWidth, alignment: .leading)
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, horizontalPadding)
                    .frame(height: 28)
                    .background(.black.opacity(0.14))

                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(store.positions) { position in
                                peekPositionRow(
                                    position,
                                    showsTrend: showsTrend,
                                    showsPositionColumns: showsPositionColumns,
                                    nameWidth: nameWidth,
                                    chartWidth: chartWidth,
                                    positionValueWidth: positionValueWidth,
                                    allocationWidth: allocationWidth,
                                    priceWidth: priceWidth,
                                    changeWidth: changeWidth,
                                    horizontalPadding: horizontalPadding,
                                    totalPositionValue: totalPositionValue
                                )
                                Divider().overlay(.white.opacity(0.055)).padding(.horizontal, horizontalPadding)
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
                .frame(maxHeight: .infinity)
            }
        }
        .background(.black.opacity(0.12))
    }

    private func peekPositionRow(
        _ position: Position,
        showsTrend: Bool,
        showsPositionColumns: Bool,
        nameWidth: CGFloat,
        chartWidth: CGFloat,
        positionValueWidth: CGFloat,
        allocationWidth: CGFloat,
        priceWidth: CGFloat,
        changeWidth: CGFloat,
        horizontalPadding: CGFloat,
        totalPositionValue: Double
    ) -> some View {
        let snapshot = store.positionMarkets[position.id]
        let change = snapshot?.changePercent ?? 0
        let color = snapshot == nil ? .white.opacity(0.35) : (change >= 0 ? gainColor : lossColor)
        let trend = snapshot?.trend ?? [0, 0]
        let changeText = snapshot == nil ? "--" : percent(change)
        let allocation = positionAllocation(position.value, total: totalPositionValue)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(position.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(position.symbol?.uppercased() ?? "未设置代码")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                    marketSessionTag(for: position, compact: true)
                    if !showsPositionColumns {
                        Text("\(currency(position.value)) · \(allocation)")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: showsPositionColumns ? nameWidth : nil, alignment: .leading)
            .frame(maxWidth: showsPositionColumns ? nil : .infinity, alignment: .leading)

            if showsTrend {
                SparklineView(values: trend, color: color)
                    .frame(width: chartWidth, height: 30)
            }

            if showsPositionColumns {
                Text(currency(position.value))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: positionValueWidth, alignment: .leading)

                Text(allocation)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: allocationWidth, alignment: .leading)
            }

            AnimatedMarketValue(
                text: snapshot?.currentPrice.map(price) ?? "--",
                value: snapshot?.currentPrice,
                baseColor: snapshot == nil ? .white.opacity(0.35) : color,
                positiveColor: gainColor,
                negativeColor: lossColor,
                font: .system(size: 11, weight: .medium, design: .rounded),
                width: priceWidth,
                alignment: .leading
            )

            AnimatedMarketValue(
                text: changeText,
                value: snapshot?.changePercent,
                baseColor: color,
                positiveColor: gainColor,
                negativeColor: lossColor,
                font: .system(size: 10, weight: .bold, design: .rounded),
                width: changeWidth,
                height: 26,
                alignment: .leading,
                backgroundOpacity: 0.13,
                cornerRadius: 7,
                pulsesByDeltaDirection: false
            )
        }
        .padding(.horizontal, horizontalPadding)
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

    private func positionMarketRow(
        _ position: Position,
        nameWidth: CGFloat,
        chartWidth: CGFloat,
        chartToValueGap: CGFloat,
        totalPositionValue: Double
    ) -> some View {
        let snapshot = store.positionMarkets[position.id]
        let change = snapshot?.changePercent ?? 0
        let color = snapshot == nil ? .white.opacity(0.35) : (change >= 0 ? gainColor : lossColor)
        let trend = snapshot?.trend ?? [0, 0]
        let changeText = snapshot == nil ? "--" : percent(change)
        let allocation = positionAllocation(position.value, total: totalPositionValue)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(position.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(position.symbol?.uppercased() ?? "未设置代码")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.34))
                    marketSessionTag(for: position)
                }
            }
            .frame(width: nameWidth, alignment: .leading)

            SparklineView(values: trend, color: color)
                .frame(width: chartWidth, height: 54)

            Text(currency(position.value))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(width: 100, alignment: .leading)
                .padding(.leading, chartToValueGap)

            Text(allocation)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 72, alignment: .leading)

            AnimatedMarketValue(
                text: snapshot?.currentPrice.map(price) ?? "--",
                value: snapshot?.currentPrice,
                baseColor: snapshot == nil ? .white.opacity(0.35) : color,
                positiveColor: gainColor,
                negativeColor: lossColor,
                font: .system(size: 13, weight: .medium, design: .rounded),
                width: 84,
                alignment: .leading
            )

            AnimatedMarketValue(
                text: changeText,
                value: snapshot?.changePercent,
                baseColor: color,
                positiveColor: gainColor,
                negativeColor: lossColor,
                font: .system(size: 12, weight: .bold, design: .rounded),
                width: 88,
                height: 30,
                alignment: .leading,
                horizontalPadding: 9,
                backgroundOpacity: 0.16,
                cornerRadius: 7,
                pulsesByDeltaDirection: false
            )
        }
        .padding(.horizontal, 20)
        .frame(height: 82)
    }

    private func marketSessionTag(for position: Position, compact: Bool = false) -> some View {
        let session = MarketSessionResolver.session(for: position.symbol)
        return Text(session.label)
            .font(.system(size: compact ? 7 : 8, weight: .semibold))
            .foregroundStyle(session.color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, compact ? 4 : 5)
            .padding(.vertical, 2)
            .background(session.color.opacity(0.13), in: Capsule())
            .overlay(Capsule().stroke(session.color.opacity(0.24), lineWidth: 1))
            .help("\(session.marketName) · \(session.detail)")
    }

    private var marketUpdateText: String {
        guard let date = store.marketUpdatedAt else { return store.isLoadingMarket ? "正在刷新…" : "等待行情" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss 更新"
        return formatter.string(from: date)
    }

    private var hasOvernightUSPosition: Bool {
        store.positions.contains { position in
            guard let symbol = position.symbol, symbol.lowercased().hasPrefix("us") else { return false }
            return MarketSessionResolver.session(for: symbol).phase == .overnight
        }
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

    private func positionAllocation(_ value: Double, total: Double) -> String {
        guard total > 0 else { return "0.0%" }
        return String(format: "%.1f%%", max(0, value) / total * 100)
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
                        appearance: selectedAppearance,
                        animationSettings: selectedAnimationSettings,
                        previewAction: debugState.previewAction
                    )
                    .frame(width: 150, height: 150)
                    .id(debugState.actionToken)
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
                actionButton("▣  上传持仓截图") { choosePositionScreenshot() }
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
                    Text("系统推送").font(.system(size: 11, weight: .semibold))
                    Text("热门资讯与异动提醒").font(.system(size: 8)).foregroundStyle(.white.opacity(0.34))
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

    private var alpacaSettingsPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.42, green: 0.64, blue: 1.0))
                VStack(alignment: .leading, spacing: 2) {
                    Text("美股夜盘行情")
                        .font(.system(size: 16, weight: .bold))
                    Text("Alpaca · 美东时间 20:00–04:00")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.38))
                }
                Spacer()
                Button { showingAlpacaSettings = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().overlay(.white.opacity(0.07))

            VStack(alignment: .leading, spacing: 13) {
                Text("免费账户使用实时指示报价；夜盘成交与分钟走势可能延迟约 15 分钟。密钥只保存在这台 Mac 的系统钥匙串中。")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("API KEY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.38))
                    SecureField("APCA-API-KEY-ID", text: $store.alpacaAPIKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.1)))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("SECRET KEY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.38))
                    SecureField("APCA-API-SECRET-KEY", text: $store.alpacaAPISecret)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.1)))
                }

                Text(store.alpacaStatus)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(store.hasAlpacaCredentials ? .green.opacity(0.8) : .orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        store.saveAlpacaCredentials()
                    } label: {
                        Label("保存并刷新", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Color(red: 0.24, green: 0.48, blue: 0.95), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)

                    Button("清除密钥") {
                        store.clearAlpacaCredentials()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
                    .frame(width: 92, height: 36)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                }

                Link("免费注册并获取 API Key ↗", destination: URL(string: "https://app.alpaca.markets/signup")!)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.46, green: 0.68, blue: 1.0))
            }
            .padding(20)
        }
        .frame(width: 460, height: 420)
        .background(
            LinearGradient(
                colors: [Color(red: 0.075, green: 0.08, blue: 0.12), Color(red: 0.035, green: 0.04, blue: 0.065)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .preferredColorScheme(.dark)
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
                                appearance: appearance,
                                animationSettings: debugState.settings(for: appearance)
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
        if let previewAction = debugState.previewAction,
           !appearance.availableAnimationActions.contains(previewAction) {
            debugState.previewAction = nil
        }
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

            petSizeControl

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

            animationActionPanel

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

    private var petSizeControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("人物大小")
                    .font(.system(size: 10, weight: .medium))
                Spacer()
                Text("×\(String(format: "%.2f", selectedAnimationSettings.scale))")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(selectedAnimationSettings.scale == 1 ? .secondary : mood.color)
            }
            Slider(value: appearanceScaleBinding, in: 0.5...2.0, step: 0.05)
                .tint(mood.color)
            HStack(spacing: 5) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { scale in
                    Button("×\(petScaleLabel(scale))") {
                        debugState.updateSettings(for: selectedAppearance) { $0.scale = scale }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Spacer()
                Text("仅对当前宠物生效")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
    }

    private func petScaleLabel(_ scale: Double) -> String {
        if scale.rounded() == scale { return String(format: "%.0f", scale) }
        if (scale * 10).rounded() == scale * 10 { return String(format: "%.1f", scale) }
        return String(format: "%.2f", scale)
    }

    private var animationActionPanel: some View {
        let selectedAction = debugState.previewAction ?? selectedAnimationSettings.primaryAction
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("动作预览与分配", systemImage: "play.rectangle")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("点击动作，调试页与右侧宠物同步播放")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.38))
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    ForEach(selectedAppearance.availableAnimationActions) { action in
                        Button {
                            debugState.previewAction = action
                            debugState.actionToken = UUID()
                        } label: {
                            Label(action.label, systemImage: action.systemImage)
                                .font(.system(size: 9, weight: selectedAction == action ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .frame(height: 28)
                                .background(
                                    selectedAction == action ? mood.color.opacity(0.24) : .white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selectedAction == action ? mood.color.opacity(0.8) : .white.opacity(0.07))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 3)
            }
            .frame(height: 36)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 6
            ) {
                animationRoleSummary("主要动作", action: selectedAnimationSettings.primaryAction, icon: "star.fill")
                animationRoleSummary("鼠标悬停", action: selectedAnimationSettings.hoverAction, icon: "cursorarrow.motionlines")
                animationRoleSummary("收益为正", action: selectedAnimationSettings.positiveAction, icon: "arrow.up.right")
                animationRoleSummary("收益为负", action: selectedAnimationSettings.negativeAction, icon: "arrow.down.right")
            }

            Text("把「\(selectedAction.label)」设置为")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.48))

            HStack(spacing: 5) {
                animationAssignmentButton("主要", icon: "star") { $0.primaryAction = selectedAction }
                animationAssignmentButton("悬停", icon: "cursorarrow") { $0.hoverAction = selectedAction }
                animationAssignmentButton("开心", icon: "arrow.up") { $0.positiveAction = selectedAction }
                animationAssignmentButton("难过", icon: "arrow.down") { $0.negativeAction = selectedAction }
            }
        }
        .padding(10)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07)))
    }

    private func animationRoleSummary(
        _ title: String,
        action: PetAnimationAction,
        icon: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(mood.color)
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.42))
            Spacer()
            Text(action.label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(.horizontal, 7)
        .frame(height: 25)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }

    private func animationAssignmentButton(
        _ title: String,
        icon: String,
        update: @escaping (inout PetAnimationSettings) -> Void
    ) -> some View {
        Button {
            debugState.updateSettings(for: selectedAppearance, update)
            debugState.actionToken = UUID()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 8, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 27)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
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
                positionScreenshotInput

                if !store.importedPositions.isEmpty {
                    importedPositionsPreview
                }

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
                        ? (store.importedPositions.isEmpty ? 214 : 94)
                        : (store.importedPositions.isEmpty ? 112 : 72),
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

    private var positionScreenshotInput: some View {
        HStack(spacing: 10) {
            Button {
                choosePositionScreenshot()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(gainColor.opacity(isScreenshotDropTargeted ? 0.24 : 0.12))
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(gainColor)
                    }
                    .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isScreenshotDropTargeted ? "松开即可识别" : "上传持仓截图")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.86))
                        Text("点击选择或拖入图片 · 仅在本机识别")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.34))
                    }
                    Spacer()
                    if store.isRecognizingScreenshot || store.isResolvingImportedSymbols {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.24))
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button("免登录示例") {
                store.loadPositionImportExample()
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(gainColor)
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(gainColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("载入虚构数据体验截图导入流程")
        }
        .padding(5)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isScreenshotDropTargeted ? gainColor.opacity(0.8) : .white.opacity(0.08),
                    style: StrokeStyle(lineWidth: isScreenshotDropTargeted ? 1.5 : 1, dash: [5, 4])
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            importPositionScreenshot(from: url)
            return true
        } isTargeted: { targeted in
            isScreenshotDropTargeted = targeted
        }
        .overlay(alignment: .bottomLeading) {
            if let message = store.screenshotImportMessage, store.importedPositions.isEmpty {
                Text(message)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .padding(.leading, 11)
                    .offset(y: 12)
            }
        }
    }

    private var importedPositionsPreview: some View {
        let unresolvedCount = store.importedPositions.filter {
            ($0.symbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }.count
        return VStack(spacing: 7) {
            HStack(spacing: 8) {
                Label("识别预览", systemImage: "text.viewfinder")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(store.importedPositions.count) 条")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(gainColor)
                if let message = store.screenshotImportMessage {
                    Text(message)
                        .font(.system(size: 8))
                        .foregroundStyle(unresolvedCount > 0 ? .orange.opacity(0.9) : .white.opacity(0.34))
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    store.discardImportedPositions()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.28))
                }
                .buttonStyle(.plain)
                .help("取消本次导入")
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach($store.importedPositions) { $item in
                        VStack(alignment: .leading, spacing: 5) {
                            TextField("股票名称", text: $item.name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 10, weight: .semibold))
                            HStack(spacing: 5) {
                                TextField("市值", value: $item.value, format: .number)
                                    .textFieldStyle(PetField())
                                    .frame(width: 82)
                                TextField("涨跌%", value: $item.change, format: .number.precision(.fractionLength(0...3)))
                                    .textFieldStyle(PetField())
                                    .frame(width: 68)
                            }
                            TextField("证券代码（必填，如 sh513000）", text: Binding(
                                get: { item.symbol ?? "" },
                                set: { item.symbol = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(
                                (item.symbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
                                    ? .orange.opacity(0.9)
                                    : .white.opacity(0.5)
                            )
                        }
                        .padding(8)
                        .frame(width: 174, height: 78, alignment: .topLeading)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(height: 82)

            HStack(spacing: 8) {
                if unresolvedCount > 0 {
                    Label("还有 \(unresolvedCount) 条需要手动输入证券代码", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange.opacity(0.9))
                }
                Spacer()
                Button(store.isResolvingImportedSymbols ? "正在匹配证券代码…" : "更新仓位（保留美股）") {
                    store.applyImportedPositionsPreservingUS()
                }
                .buttonStyle(.plain)
                .foregroundStyle(gainColor)
                .disabled(store.isResolvingImportedSymbols)
            }
            .font(.system(size: 9, weight: .semibold))
        }
        .padding(9)
        .background(gainColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(gainColor.opacity(0.18)))
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

    private func choosePositionScreenshot() {
        let panel = NSOpenPanel()
        panel.title = "选择持仓截图"
        panel.message = "选择券商持仓页面截图，图片只会在本机识别"
        panel.prompt = "选择图片"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                importPositionScreenshot(from: url)
            }
        }
    }

    private func importPositionScreenshot(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
        }
        guard let image = NSImage(contentsOf: url) else {
            store.screenshotImportMessage = "无法读取这张图片，请选择 PNG、JPG 或系统支持的图片格式"
            return
        }
        store.importPositionScreenshot(image)
        store.showingEditor = true
        guard !store.importedPositions.isEmpty else { return }
        Task { await store.resolveImportedPositionSymbols() }
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

    /// 监听窗口移动：拖动迷你宠物时按水平位移方向播放左/右跑动动画。
    /// 不用 NSEvent 拖拽监听——系统接管窗口拖动时收不到 leftMouseDragged。
    private func installDragWalkMonitor() {
        guard dragEventMonitor == nil else { return }
        dragEventMonitor = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { note in
            let window = note.object as? NSWindow
            Task { @MainActor in
                handleWindowMove(window)
            }
        }
    }

    @MainActor
    private func handleWindowMove(_ window: NSWindow?) {
        guard !isExpanded,
              let window,
              window.title == "持仓宠物",
              NSEvent.pressedMouseButtons & 1 == 1 else {
            lastWindowX = nil
            return
        }
        let x = window.frame.origin.x
        let previous = lastWindowX
        lastWindowX = x
        guard let previous, abs(x - previous) > 0.7 else { return }
        walkDirection = x - previous > 0 ? 1 : -1
        let token = UUID()
        walkStopToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if walkStopToken == token { walkDirection = 0 }
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
        debugState.previewAction = nil
        debugState.actionToken = UUID()
    }

    private func applyMainPetWindowPresentation(bringToFront: Bool = false) {
        guard let window = mainPetWindow else { return }
        UserDefaults.standard.set(isExpanded, forKey: mainPetWindowExpandedKey)
        configureMainPetWindowPresentation(
            window,
            isExpanded: isExpanded,
            expandedStaysOnTop: expandedWindowStaysOnTop
        )
        if bringToFront || !isExpanded || expandedWindowStaysOnTop {
            window.setIsVisible(true)
            window.orderFrontRegardless()
        }
    }

    private func toggleExpandedWindowPriority() {
        expandedWindowStaysOnTop.toggle()
        applyMainPetWindowPresentation(bringToFront: expandedWindowStaysOnTop)
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
        // 重新确认窗口层级；紧凑宠物置顶，展开面板按图钉按钮决定是否置顶。
        applyMainPetWindowPresentation(bringToFront: expanded)
        if expanded {
            window.makeKeyAndOrderFront(nil)
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

struct PreferencesView: View {
    @ObservedObject var store: PetStore
    @Environment(\.dismiss) private var dismiss

    private let gain = Color(red: 1.0, green: 0.28, blue: 0.30)
    private let intervals = [0, 15, 30, 60]

    private func intervalLabel(_ m: Int) -> String { m == 0 ? "关闭" : "\(m)分钟" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    block("新闻范围") {
                        Picker("", selection: Binding(
                            get: { store.newsHoldingsOnly },
                            set: { store.newsHoldingsOnly = $0; store.savePreferences() }
                        )) {
                            Text("全部财经").tag(false)
                            Text("只看持仓").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(store.newsHoldingsOnly ? "只显示标题含持仓名称/代码的资讯" : "显示大盘热门财经资讯")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }

                    block("推送频率") {
                        HStack(spacing: 6) {
                            ForEach(intervals, id: \.self) { value in
                                Button {
                                    store.newsPushIntervalMinutes = value
                                    store.savePreferences()
                                } label: {
                                    Text(intervalLabel(value))
                                        .font(.system(size: 11))
                                        .padding(.horizontal, 11).frame(height: 28)
                                        .background(store.newsPushIntervalMinutes == value ? gain.opacity(0.85) : Color.white.opacity(0.06),
                                                    in: RoundedRectangle(cornerRadius: 7))
                                        .foregroundStyle(.white)
                                }.buttonStyle(.plain)
                            }
                        }
                        Text("关闭则只更新资讯列表、不发系统通知").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("总收益算入美股").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                            Text("关闭后总收益率只统计 A 股 / 港股持仓").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { store.includeUSInReturn },
                            set: { store.includeUSInReturn = $0; store.savePreferences() }
                        )).labelsHidden().toggleStyle(.switch).tint(gain)
                    }

                    block("美股夜盘源") {
                        Text(store.alpacaStatus).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        Text("默认用新浪盘后收盘价；要真·隔夜逐笔行情，可在顶栏「月亮」图标里配置 Alpaca。")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    }

                    block("隐私与数据") {
                        Text("持仓和调试设置保存在本机；持仓截图只在设备上识别。每天首次启动会发送一次不含持仓内容的匿名统计事件，详情见隐私政策。")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 16) {
                            Link(
                                "隐私政策 ↗",
                                destination: URL(string: "https://github.com/andy304yang/Pet-stock/blob/main/PRIVACY.md")!
                            )
                            Link(
                                "第三方说明 ↗",
                                destination: URL(string: "https://github.com/andy304yang/Pet-stock/blob/main/THIRD_PARTY_NOTICES.md")!
                            )
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(gain)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 400, height: 540)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            content()
        }
    }
}

struct IndexSettingsView: View {
    @ObservedObject var store: PetStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?

    private let gain = Color(red: 1.0, green: 0.28, blue: 0.30)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("自定义指数栏")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("重置默认") { store.resetWatchIndices() }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.55))
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeader("已选 · \(store.watchIndices.count)（点勾去除）")
                    if store.watchIndices.isEmpty {
                        Text("暂无，勾选下方指数或搜索添加").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    } else {
                        ForEach(store.watchIndices) { indexRow($0) }
                    }

                    sectionHeader("搜索添加任意标的")
                    TextField("股票 / ETF / 指数 名称或代码", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                        .onChange(of: query) { _, newValue in runSearch(newValue) }
                    if store.isSearchingStocks {
                        Text("搜索中…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    }
                    ForEach(store.stockSearchResults) { r in
                        indexRow(WatchIndex(symbol: r.symbol, name: r.name))
                    }

                    ForEach(IndexCatalog.groups) { group in
                        sectionHeader(group.title)
                        ForEach(group.items) { indexRow($0) }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 400, height: 580)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
    }

    @ViewBuilder
    private func indexRow(_ item: WatchIndex) -> some View {
        let selected = store.isWatchingIndex(item.symbol)
        Button {
            store.toggleWatchIndex(item)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    Text(item.symbol).font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? gain : .white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func runSearch(_ newValue: String) {
        searchTask?.cancel()
        let q = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            store.clearStockSearch()
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await store.searchStocks(q)
        }
    }
}

private struct AnimatedMarketValue: View {
    let text: String
    let value: Double?
    let baseColor: Color
    let positiveColor: Color
    let negativeColor: Color
    let font: Font
    let width: CGFloat
    var height: CGFloat? = nil
    var alignment: Alignment = .leading
    var horizontalPadding: CGFloat = 0
    var backgroundOpacity: Double = 0
    var cornerRadius: CGFloat = 7
    var pulsesByDeltaDirection = true

    @State private var previousValue: Double?
    @State private var pulse = false
    @State private var pulseColor = Color.white
    @State private var pulseTask: Task<Void, Never>?

    var body: some View {
        let activeColor = pulse ? pulseColor : baseColor
        let extraPulseOpacity = backgroundOpacity > 0 ? 0.12 : 0.13
        let fillOpacity = backgroundOpacity + (pulse ? extraPulseOpacity : 0)
        Text(text)
            .font(font)
            .foregroundStyle(activeColor)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.74)
            .padding(.horizontal, horizontalPadding)
            .frame(width: width, height: height, alignment: alignment)
            .background {
                if fillOpacity > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(activeColor.opacity(fillOpacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: text)
            .animation(.easeOut(duration: 0.24), value: pulse)
            .onAppear {
                previousValue = value
                pulseColor = baseColor
            }
            .onChange(of: value) { oldValue, newValue in
                updatePulse(from: oldValue, to: newValue)
            }
    }

    private func updatePulse(from oldValue: Double?, to newValue: Double?) {
        guard let newValue else {
            previousValue = nil
            return
        }
        let baseline = oldValue ?? previousValue
        previousValue = newValue
        guard let baseline, abs(newValue - baseline) > 0.0001 else { return }

        pulseColor = pulsesByDeltaDirection
            ? (newValue >= baseline ? positiveColor : negativeColor)
            : (newValue >= 0 ? positiveColor : negativeColor)
        pulseTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            pulse = true
        }
        pulseTask = Task {
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.35)) {
                    pulse = false
                }
            }
        }
    }
}

struct SparklineView: View {
    let values: [Double]
    let color: Color
    @State private var updatePulse = false
    @State private var pulseTask: Task<Void, Never>?

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
                .shadow(color: color.opacity(updatePulse ? 0.55 : 0), radius: updatePulse ? 5 : 0)

                if let last = points.last {
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .scaleEffect(updatePulse ? 1.65 : 1)
                        .shadow(color: color.opacity(updatePulse ? 0.6 : 0), radius: updatePulse ? 5 : 0)
                        .position(last)
                }
            }
            .animation(.easeInOut(duration: 0.34), value: values)
            .animation(.spring(response: 0.24, dampingFraction: 0.62), value: updatePulse)
        }
        .padding(.vertical, 5)
        .onChange(of: values) { oldValues, newValues in
            guard oldValues != newValues else { return }
            triggerUpdatePulse()
        }
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

    private func triggerUpdatePulse() {
        pulseTask?.cancel()
        updatePulse = true
        pulseTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                updatePulse = false
            }
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
    var animationSettings: PetAnimationSettings = .default
    var previewAction: PetAnimationAction? = nil
    /// 拖拽方向：-1 向左走，1 向右走，0 正常状态
    var walkDirection: Int = 0

    @State private var hoverStartedAt = Date.distantPast
    @State private var alertStartedAt = Date.distantPast
    @State private var actionStartedAt = Date()

    private var displayedAction: PetAnimationAction {
        // 调试预览优先级最高：用户点了哪个动作就播哪个，不被悬停/异动打断
        if let previewAction {
            return previewAction
        }
        if isHovered || isAlerting {
            return animationSettings.hoverAction
        }
        if returnRate > 0.001 {
            return animationSettings.positiveAction
        }
        if returnRate < -0.001 {
            return animationSettings.negativeAction
        }
        return animationSettings.primaryAction
    }

    private var displayedMood: PetMood {
        switch displayedAction {
        case .sad, .hurt, .crash, .failed: return .bear
        case .happy, .jump, .attack, .shoot, .waving: return .bull
        default: return mood
        }
    }

    private var displayedReturnRate: Double {
        switch displayedAction {
        case .sad, .hurt, .crash, .failed: return min(-1, returnRate)
        case .happy, .jump, .attack, .shoot, .waving: return max(2, returnRate)
        default: return returnRate
        }
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let actionTime = max(0, timeline.date.timeIntervalSince(actionStartedAt))
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
                                mood: displayedMood,
                                returnRate: displayedReturnRate,
                                blinking: time.truncatingRemainder(dividingBy: 4.1) > 3.88,
                                actionActive: bullActionActive || bearActionActive
                            )
                        } else {
                            OpenPetsMascot(
                                mood: displayedMood,
                                returnRate: displayedReturnRate,
                                time: actionTime,
                                actionActive: bullActionActive || bearActionActive,
                                appearance: appearance,
                                animationAction: displayedAction,
                                walkDirection: walkDirection
                            )
                        }
                    }
                    .scaleEffect(x: breath, y: 2 - breath, anchor: .bottom)
                    .scaleEffect(CGFloat(animationSettings.scale), anchor: .bottom)
                    .offset(x: shake, y: idleLift - jumpHeight)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .onChange(of: isHovered) { wasHovered, hovering in
            guard hovering && !wasHovered else { return }
            hoverStartedAt = Date()
            actionStartedAt = Date()
        }
        .onChange(of: isAlerting) { wasAlerting, alerting in
            guard alerting && !wasAlerting else { return }
            alertStartedAt = Date()
            actionStartedAt = Date()
        }
        .onChange(of: previewAction) { _, _ in
            actionStartedAt = Date()
        }
        .onChange(of: animationSettings) { _, _ in
            actionStartedAt = Date()
        }
        .onChange(of: returnRate >= 0) { _, _ in
            actionStartedAt = Date()
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
    let animationAction: PetAnimationAction?
    var walkDirection: Int = 0

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

    private var configuredFrameName: String? {
        let action: PetAnimationAction
        if walkDirection != 0,
           appearance.animationFrameCount(for: walkDirection > 0 ? .runright : .runleft) > 0 {
            action = walkDirection > 0 ? .runright : .runleft
        } else if let animationAction {
            action = animationAction
        } else {
            return nil
        }
        let count = appearance.animationFrameCount(for: action)
        guard count > 0 else { return nil }
        return skinFrame(
            appearance.rawValue,
            state: action.rawValue,
            count: count,
            speed: action.playbackSpeed
        )
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

        // 拖拽中：朝拖动方向小跑（跑动帧率稍快，跟手感）
        if walkDirection != 0 && spec.runFrames > 0 {
            let runFps = 6.0 * PetAnimTuning.speedMultiplier
            let frame = Int(time * runFps) % spec.runFrames
            return "skin_\(appearance.rawValue)_\(walkDirection > 0 ? "runright" : "runleft")_\(frame)"
        }

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
            if let frame = configuredFrameName,
               let image = NSImage(named: NSImage.Name(frame)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if let frame = currentSkinFrame,
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
