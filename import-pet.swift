#!/usr/bin/env swift

import AppKit
import Foundation

private struct PetManifest: Decodable {
    let id: String
    let displayName: String?
    let description: String?
}

private struct ImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct FrameSource {
    let state: String
    let row: Int
    let columns: [Int]
}

private let usage = """
用法：
  ./import-pet.swift <包含 pet.json 和 spritesheet.webp 的目录> [--force] [--local-only]

示例：
  ./import-pet.swift "$HOME/.codex/pets/ricklet"

默认会加入本地商城、公开 DMG 和 App Store 构建。
--local-only  只加入本地扩展商城，不加入公开构建。
--force       覆盖已经存在的同 ID 动画帧；已经登记的商城 ID 仍会拒绝重复导入。
"""

private func fail(_ message: String) throws -> Never {
    throw ImportError(message: message)
}

private func normalizedPetID(_ source: String) throws -> String {
    var value = source.lowercased()
        .map { character -> Character in
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1,
                  (scalar.value >= 48 && scalar.value <= 57
                    || scalar.value >= 97 && scalar.value <= 122) else {
                return "_"
            }
            return character
        }
        .reduce(into: "") { result, character in
            if character == "_", result.last == "_" { return }
            result.append(character)
        }
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

    guard !value.isEmpty else {
        try fail("pet.json 的 id 无法转换成有效商城 ID")
    }
    if value.first?.isNumber == true {
        value = "pet_\(value)"
    }
    let swiftKeywords: Set<String> = [
        "associatedtype", "break", "case", "catch", "class", "continue",
        "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "for", "func", "guard", "if",
        "import", "in", "init", "inout", "internal", "is", "let", "nil",
        "open", "operator", "private", "protocol", "public", "repeat", "rethrows",
        "return", "self", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "true", "try", "typealias", "var", "where", "while"
    ]
    if swiftKeywords.contains(value) {
        value = "pet_\(value)"
    }
    return value
}

private func swiftStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}

private func writeTextPreservingPermissions(
    _ source: String,
    to fileURL: URL,
    fileManager: FileManager
) throws {
    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
    try source.write(to: fileURL, atomically: true, encoding: .utf8)
    if let permissions = attributes[.posixPermissions] {
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: fileURL.path
        )
    }
}

private func inserting(
    _ line: String,
    before marker: String,
    in source: String,
    file: String
) throws -> String {
    guard source.contains(marker) else {
        try fail("\(file) 缺少导入标记：\(marker)")
    }
    return source.replacingOccurrences(of: marker, with: "\(line)\n\(marker)")
}

private func addingSkinToPackagingList(
    _ petID: String,
    source: String,
    file: String
) throws -> String {
    let pattern = #"skin_\{([^}]*)\}_\*\.png"#
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..., in: source)
    let matches = regex.matches(in: source, range: range)
    guard !matches.isEmpty else {
        try fail("\(file) 中找不到公开宠物素材列表")
    }

    var result = source
    for match in matches.reversed() {
        guard let listRange = Range(match.range(at: 1), in: result) else { continue }
        let entries = result[listRange].split(separator: ",").map(String.init)
        guard !entries.contains(petID) else { continue }
        result.replaceSubrange(listRange, with: entries.joined(separator: ",") + ",\(petID)")
    }
    return result
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(
        using: .png,
        properties: [.compressionFactor: 0.9]
    ) else {
        try fail("无法生成 PNG：\(url.lastPathComponent)")
    }
    try data.write(to: url, options: .atomic)
}

private func run() throws {
    let rawArguments = Array(CommandLine.arguments.dropFirst())
    let force = rawArguments.contains("--force")
    let localOnly = rawArguments.contains("--local-only")
    let paths = rawArguments.filter { !$0.hasPrefix("--") }
    guard paths.count == 1 else {
        print(usage)
        try fail("请提供一个宠物素材目录")
    }

    let fileManager = FileManager.default
    let sourcePath = NSString(string: paths[0]).expandingTildeInPath
    let sourceDirectory = URL(fileURLWithPath: sourcePath, isDirectory: true)
        .standardizedFileURL
    let manifestURL = sourceDirectory.appendingPathComponent("pet.json")
    let spritesheetURL = sourceDirectory.appendingPathComponent("spritesheet.webp")
    guard fileManager.fileExists(atPath: manifestURL.path) else {
        try fail("找不到 \(manifestURL.path)")
    }
    guard fileManager.fileExists(atPath: spritesheetURL.path) else {
        try fail("找不到 \(spritesheetURL.path)")
    }

    let manifest = try JSONDecoder().decode(
        PetManifest.self,
        from: Data(contentsOf: manifestURL)
    )
    let petID = try normalizedPetID(manifest.id)
    let displayName = manifest.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let petName = displayName?.isEmpty == false ? displayName! : petID
    let rawDescription = manifest.description?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let tagline = rawDescription?.isEmpty == false
        ? rawDescription!
        : "\(petName)陪你盯盘"

    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .standardizedFileURL
    let projectRoot = scriptURL.deletingLastPathComponent()
    let swiftURL = projectRoot.appendingPathComponent("native/StockPet.swift")
    let resourcesURL = projectRoot.appendingPathComponent("native/Resources/OpenPets")
    guard fileManager.fileExists(atPath: swiftURL.path) else {
        try fail("请从项目内运行脚本，找不到 native/StockPet.swift")
    }

    var swiftSource = try String(contentsOf: swiftURL, encoding: .utf8)
    let enumStart = swiftSource.range(of: "struct PetAppearance:")
    let enumEnd = swiftSource.range(of: "struct ContentView:")
    guard let enumStart, let enumEnd, enumStart.lowerBound < enumEnd.lowerBound else {
        try fail("无法定位 PetAppearance")
    }
    let enumSource = String(swiftSource[enumStart.lowerBound..<enumEnd.lowerBound])
    let identifierPattern = "\\b\(NSRegularExpression.escapedPattern(for: petID))\\b"
    let identifierRegex = try NSRegularExpression(pattern: identifierPattern)
    if identifierRegex.firstMatch(
        in: enumSource,
        range: NSRange(enumSource.startIndex..., in: enumSource)
    ) != nil {
        try fail("商城中已经登记了 ID：\(petID)")
    }

    guard let nsImage = NSImage(contentsOf: spritesheetURL),
          let sheet = nsImage.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
          ) else {
        try fail("无法读取 spritesheet.webp")
    }
    let frameWidth = 192
    let frameHeight = 208
    let requiredWidth = frameWidth * 8
    let requiredHeight = frameHeight * 9
    guard sheet.width == requiredWidth, sheet.height == requiredHeight else {
        try fail(
            "图集尺寸应为 \(requiredWidth)×\(requiredHeight)，当前为 \(sheet.width)×\(sheet.height)"
        )
    }

    let existingFrames = try fileManager.contentsOfDirectory(
        at: resourcesURL,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("skin_\(petID)_") }
    if !existingFrames.isEmpty, !force {
        try fail("已经存在 \(petID) 的动画帧；如需覆盖请加 --force")
    }

    let temporaryDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("stockpet-import-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    let frameSources = [
        FrameSource(state: "idle", row: 0, columns: Array(0..<6)),
        FrameSource(state: "runright", row: 1, columns: Array(0..<8)),
        FrameSource(state: "runleft", row: 2, columns: Array(0..<8)),
        FrameSource(state: "waving", row: 3, columns: Array(0..<4)),
        FrameSource(state: "jump", row: 4, columns: Array(0..<5)),
        FrameSource(state: "failed", row: 5, columns: Array(0..<8)),
        FrameSource(state: "waiting", row: 6, columns: Array(0..<6)),
        FrameSource(state: "run", row: 7, columns: Array(0..<6)),
        FrameSource(state: "review", row: 8, columns: Array(0..<6)),
        FrameSource(state: "happy", row: 3, columns: Array(0..<4)),
        FrameSource(state: "sad", row: 5, columns: Array(0..<8))
    ]

    var generatedCount = 0
    for source in frameSources {
        for (outputIndex, column) in source.columns.enumerated() {
            let cropRect = CGRect(
                x: column * frameWidth,
                y: source.row * frameHeight,
                width: frameWidth,
                height: frameHeight
            )
            guard let frame = sheet.cropping(to: cropRect) else {
                try fail("切图失败：\(source.state) \(outputIndex)")
            }
            let outputURL = temporaryDirectory.appendingPathComponent(
                "skin_\(petID)_\(source.state)_\(outputIndex).png"
            )
            try writePNG(frame, to: outputURL)
            generatedCount += 1
        }
    }
    for column in 0..<5 {
        let cropRect = CGRect(
            x: column * frameWidth,
            y: 4 * frameHeight,
            width: frameWidth,
            height: frameHeight
        )
        guard let frame = sheet.cropping(to: cropRect) else {
            try fail("切图失败：happy \(column + 4)")
        }
        try writePNG(
            frame,
            to: temporaryDirectory.appendingPathComponent(
                "skin_\(petID)_happy_\(column + 4).png"
            )
        )
        generatedCount += 1
    }

    let nameLiteral = swiftStringLiteral(petName)
    let taglineLiteral = swiftStringLiteral(tagline)
    swiftSource = try inserting(
        "    static let \(petID) = PetAppearance(\(swiftStringLiteral(petID)))",
        before: "    // AUTO-IMPORT: PET_CASES",
        in: swiftSource,
        file: "native/StockPet.swift"
    )
    swiftSource = try inserting(
        "        .\(petID),",
        before: "        // AUTO-IMPORT: ALL_CASES",
        in: swiftSource,
        file: "native/StockPet.swift"
    )
    if !localOnly {
        swiftSource = try inserting(
            "            .\(petID),",
            before: "            // AUTO-IMPORT: PUBLIC_CASES",
            in: swiftSource,
            file: "native/StockPet.swift"
        )
    }
    swiftSource = try inserting(
        "        case .\(petID): return \(nameLiteral)",
        before: "        // AUTO-IMPORT: PET_NAMES",
        in: swiftSource,
        file: "native/StockPet.swift"
    )
    swiftSource = try inserting(
        "        case .\(petID): return PetSkinSpec(idleFrames: 6, happyFrames: 9, sadFrames: 8, runFrames: 8)",
        before: "        // AUTO-IMPORT: PET_SPECS",
        in: swiftSource,
        file: "native/StockPet.swift"
    )
    swiftSource = try inserting(
        "        case .\(petID): return \(taglineLiteral)",
        before: "        // AUTO-IMPORT: PET_TAGLINES",
        in: swiftSource,
        file: "native/StockPet.swift"
    )

    var packagingUpdates: [(URL, String)] = []
    if !localOnly {
        for relativePath in [
            "build-native.sh",
            "build-app-store.sh",
            "run-dev.sh",
            "release-macos.sh"
        ] {
            let fileURL = projectRoot.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                if relativePath == "release-macos.sh" { continue }
                try fail("找不到 \(relativePath)")
            }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            packagingUpdates.append((
                fileURL,
                try addingSkinToPackagingList(
                    petID,
                    source: source,
                    file: relativePath
                )
            ))
        }
    }

    if force {
        for frame in existingFrames {
            try fileManager.removeItem(at: frame)
        }
    }
    for frame in try fileManager.contentsOfDirectory(
        at: temporaryDirectory,
        includingPropertiesForKeys: nil
    ) {
        try fileManager.moveItem(
            at: frame,
            to: resourcesURL.appendingPathComponent(frame.lastPathComponent)
        )
    }
    try writeTextPreservingPermissions(
        swiftSource,
        to: swiftURL,
        fileManager: fileManager
    )
    for (fileURL, source) in packagingUpdates {
        try writeTextPreservingPermissions(
            source,
            to: fileURL,
            fileManager: fileManager
        )
    }

    print("已导入：\(petName)（\(petID)）")
    print("生成动画帧：\(generatedCount)")
    print("商城范围：\(localOnly ? "仅本地扩展商城" : "本地商城 + 公开 DMG + App Store")")
    print("下一步：重新启动开发版，由用户检查九组动画和商城卡片。")
}

do {
    try run()
} catch {
    fputs("导入失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
