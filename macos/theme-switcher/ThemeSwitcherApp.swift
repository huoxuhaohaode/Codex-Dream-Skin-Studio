import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThemeColors: Decodable, Hashable {
  let accent: String?
  let secondary: String?
  let highlight: String?
}

struct ThemeMetadata: Decodable, Hashable {
  let id: String
  let name: String
  let tagline: String?
  let image: String
  let colors: ThemeColors?
}

struct ThemeOrigin: Decodable, Hashable {
  let sourceIdentifier: String?
  let sourceName: String?
  let repository: String?
  let sourceURL: String?
  let commit: String?
  let license: String?
  let artworkLicense: String?
  let verified: Bool
}

struct ThemeItem: Identifiable, Hashable {
  let metadata: ThemeMetadata
  let directoryURL: URL
  let imageURL: URL
  let origin: ThemeOrigin?

  var id: String { metadata.id }
}

struct CommunityCatalog: Decodable {
  let schemaVersion: Int
  let themes: [CommunityTheme]
}

struct CommunityTheme: Identifiable, Decodable, Hashable {
  let id: String
  let name: String
  let tagline: String
  let repository: String
  let sourceURL: String
  let commit: String
  let license: String
  let artworkLicense: String
  let verified: Bool
  let imageURL: String
}

struct CommandResult {
  let status: Int32
  let output: String
}

enum CommandRunner {
  static func run(_ executableURL: URL, arguments: [String]) -> CommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    process.environment = ProcessInfo.processInfo.environment.merging([
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path
    ]) { _, new in new }

    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""
      return CommandResult(status: process.terminationStatus, output: output)
    } catch {
      return CommandResult(status: 127, output: error.localizedDescription)
    }
  }
}

@MainActor
final class ThemeStore: ObservableObject {
  @Published var themes: [ThemeItem] = []
  @Published var communityThemes: [CommunityTheme] = []
  @Published var favoriteThemeIDs: Set<String> = []
  @Published var activeThemeID: String?
  @Published var activeThemeName = "未设置"
  @Published var sessionState = "检测中"
  @Published var codexIsOpen = false
  @Published var isBusy = false
  @Published var activityText = ""
  @Published var errorText: String?

  private let fileManager = FileManager.default
  private let decoder = JSONDecoder()

  private var engineRoot: URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_DREAM_SKIN_ENGINE"],
       !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    if let resources = Bundle.main.resourceURL {
      let bundled = resources.appendingPathComponent("engine", isDirectory: true)
      let switchScript = bundled.appendingPathComponent("scripts/switch-theme-macos.sh")
      if fileManager.isExecutableFile(atPath: switchScript.path) {
        return bundled
      }
    }
    return fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/codex-dream-skin-studio", isDirectory: true)
  }

  private var stateRoot: URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexDreamSkinStudio", isDirectory: true)
  }

  private var themesRoot: URL {
    stateRoot.appendingPathComponent("themes", isDirectory: true)
  }

  private var activeThemeURL: URL {
    stateRoot.appendingPathComponent("theme/theme.json")
  }

  init() {
    favoriteThemeIDs = Set(UserDefaults.standard.stringArray(forKey: "favoriteThemeIDs") ?? [])
    loadCommunityCatalog()
    refresh()
    syncBundledPresets()
  }

  func refresh() {
    loadThemes()
    refreshRuntimeStatus()
  }

  func apply(_ theme: ThemeItem) {
    runScript(
      name: "正在应用 \(theme.metadata.name)…",
      script: "switch-theme-macos.sh",
      arguments: ["--id", theme.id],
      success: "已应用 \(theme.metadata.name)"
    )
  }

  func toggleFavorite(_ theme: ThemeItem) {
    if favoriteThemeIDs.contains(theme.id) {
      favoriteThemeIDs.remove(theme.id)
    } else {
      favoriteThemeIDs.insert(theme.id)
    }
    UserDefaults.standard.set(Array(favoriteThemeIDs).sorted(), forKey: "favoriteThemeIDs")
  }

  func reapply() {
    runScript(
      name: "正在重新应用皮肤…",
      script: "start-dream-skin-macos.sh",
      arguments: ["--port", "9341", "--restart-existing"],
      success: "皮肤已重新应用"
    )
  }

  func pause() {
    runScript(
      name: "正在暂停皮肤…",
      script: "pause-dream-skin-macos.sh",
      arguments: [],
      success: "皮肤已暂停"
    )
  }

  func createTheme(
    imageURL: URL,
    name: String,
    tagline: String,
    appearance: String,
    safeArea: String,
    taskMode: String,
    focusX: Double,
    focusY: Double,
    accent: Color,
    secondary: Color,
    highlight: Color
  ) {
    runScript(
      name: "正在制作 \(name)…",
      script: "load-image-theme-macos.sh",
      arguments: [
        "--file", imageURL.path,
        "--name", name,
        "--tagline", tagline,
        "--appearance", appearance,
        "--safe-area", safeArea,
        "--task-mode", taskMode,
        "--focus-x", String(format: "%.2f", focusX),
        "--focus-y", String(format: "%.2f", focusY),
        "--accent", accent.hexString,
        "--secondary", secondary.hexString,
        "--highlight", highlight.hexString
      ],
      success: "已创建并应用 \(name)"
    )
  }

  func importTheme(from sourceURL: URL) {
    let hasAccess = sourceURL.startAccessingSecurityScopedResource()
    runScript(
      name: "正在安全检查并导入…",
      script: "import-theme-macos.sh",
      arguments: ["--source", sourceURL.path, "--no-apply"],
      success: "主题已导入，可在主题库中应用",
      completion: {
        if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
      }
    )
  }

  func exportTheme(_ theme: ThemeItem) {
    let panel = NSSavePanel()
    panel.title = "导出 Dream Skin 主题包"
    panel.nameFieldStringValue = "\(theme.metadata.name).dreamskin"
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    guard panel.runModal() == .OK, let outputURL = panel.url else { return }
    runScript(
      name: "正在导出 \(theme.metadata.name)…",
      script: "export-theme-macos.sh",
      arguments: ["--id", theme.id, "--output", outputURL.path],
      success: "已导出 \(outputURL.lastPathComponent)"
    )
  }

  func installCommunityTheme(_ theme: CommunityTheme) {
    runScript(
      name: "正在验证并导入 \(theme.name)…",
      script: "install-community-theme-macos.sh",
      arguments: ["--id", theme.id, "--no-apply"],
      success: "已验证并导入 \(theme.name)"
    )
  }

  func isCommunityThemeInstalled(_ theme: CommunityTheme) -> Bool {
    themes.contains { $0.origin?.sourceIdentifier == theme.id }
  }

  func openCommunitySource(_ theme: CommunityTheme) {
    guard let url = URL(string: theme.sourceURL) else { return }
    NSWorkspace.shared.open(url)
  }

  func openImagesFolder() {
    let folder = stateRoot.appendingPathComponent("images", isDirectory: true)
    do {
      try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
      NSWorkspace.shared.open(folder)
    } catch {
      errorText = error.localizedDescription
    }
  }

  func openThemesFolder() {
    do {
      try fileManager.createDirectory(at: themesRoot, withIntermediateDirectories: true)
      NSWorkspace.shared.open(themesRoot)
    } catch {
      errorText = error.localizedDescription
    }
  }

  func reveal(_ theme: ThemeItem) {
    NSWorkspace.shared.activateFileViewerSelecting([theme.directoryURL])
  }

  func openThemeSource(_ theme: ThemeItem) {
    guard let source = theme.origin?.sourceURL, let url = URL(string: source) else { return }
    NSWorkspace.shared.open(url)
  }

  func delete(_ theme: ThemeItem) {
    runScript(
      name: "正在删除 \(theme.metadata.name)…",
      script: "delete-theme-macos.sh",
      arguments: ["--id", theme.id],
      success: "已删除 \(theme.metadata.name)"
    )
  }

  private func syncBundledPresets() {
    let script = engineRoot.appendingPathComponent("scripts/sync-presets-macos.sh")
    guard fileManager.isExecutableFile(atPath: script.path) else { return }
    Task {
      let result = await Task.detached(priority: .utility) {
        CommandRunner.run(URL(fileURLWithPath: "/bin/bash"), arguments: [script.path])
      }.value
      if result.status == 0 { loadThemes() }
    }
  }

  private func loadCommunityCatalog() {
    let catalogURL = engineRoot.appendingPathComponent("community/catalog.json")
    guard let data = try? Data(contentsOf: catalogURL),
          let catalog = try? decoder.decode(CommunityCatalog.self, from: data),
          catalog.schemaVersion == 1 else {
      communityThemes = []
      return
    }
    communityThemes = catalog.themes.filter { $0.verified }
  }

  private func loadThemes() {
    errorText = nil
    var loaded: [ThemeItem] = []

    do {
      try fileManager.createDirectory(at: themesRoot, withIntermediateDirectories: true)
      let directories = try fileManager.contentsOfDirectory(
        at: themesRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )

      for directory in directories {
        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { continue }
        let metadataURL = directory.appendingPathComponent("theme.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? decoder.decode(ThemeMetadata.self, from: data) else {
          continue
        }
        let imageURL = directory.appendingPathComponent(metadata.image)
        guard fileManager.fileExists(atPath: imageURL.path) else { continue }
        let originURL = directory.appendingPathComponent("origin.json")
        let origin = (try? Data(contentsOf: originURL)).flatMap {
          try? decoder.decode(ThemeOrigin.self, from: $0)
        }
        loaded.append(ThemeItem(
          metadata: metadata,
          directoryURL: directory,
          imageURL: imageURL,
          origin: origin
        ))
      }
    } catch {
      errorText = "无法读取主题库：\(error.localizedDescription)"
    }

    themes = loaded.sorted {
      if $0.id.hasPrefix("custom-") != $1.id.hasPrefix("custom-") {
        return $0.id.hasPrefix("custom-")
      }
      return $0.metadata.name.localizedStandardCompare($1.metadata.name) == .orderedAscending
    }

    if let data = try? Data(contentsOf: activeThemeURL),
       let active = try? decoder.decode(ThemeMetadata.self, from: data) {
      activeThemeID = active.id
      activeThemeName = active.name
    } else {
      activeThemeID = nil
      activeThemeName = "未设置"
    }
  }

  private func refreshRuntimeStatus() {
    let script = engineRoot.appendingPathComponent("scripts/status-dream-skin-macos.sh")
    guard fileManager.isExecutableFile(atPath: script.path) else {
      sessionState = "引擎未安装"
      codexIsOpen = false
      return
    }

    Task {
      let result = await Task.detached(priority: .utility) {
        CommandRunner.run(URL(fileURLWithPath: "/bin/bash"), arguments: [script.path])
      }.value

      guard result.status == 0 else {
        sessionState = "状态未知"
        return
      }
      let values = parseStatus(result.output)
      codexIsOpen = values["codex"] == "true"
      switch values["session"] {
      case "active": sessionState = "运行中"
      case "paused": sessionState = "已暂停"
      case "stale": sessionState = "需要重启"
      default: sessionState = "未启用"
      }
    }
  }

  private func parseStatus(_ output: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in output.split(whereSeparator: \.isNewline) {
      let pieces = line.split(separator: "=", maxSplits: 1).map(String.init)
      if pieces.count == 2 { result[pieces[0]] = pieces[1] }
    }
    return result
  }

  private func runScript(
    name: String,
    script: String,
    arguments: [String],
    success: String,
    completion: (() -> Void)? = nil
  ) {
    guard !isBusy else { return }
    let scriptURL = engineRoot.appendingPathComponent("scripts/\(script)")
    guard fileManager.isExecutableFile(atPath: scriptURL.path) else {
      errorText = "找不到已安装的 Dream Skin 引擎。"
      return
    }

    isBusy = true
    activityText = name
    errorText = nil

    Task {
      let result = await Task.detached(priority: .userInitiated) {
        CommandRunner.run(
          URL(fileURLWithPath: "/bin/bash"),
          arguments: [scriptURL.path] + arguments
        )
      }.value

      completion?()
      isBusy = false
      if result.status == 0 {
        activityText = success
        loadThemes()
        refreshRuntimeStatus()
      } else {
        activityText = ""
        let message = result.output
          .split(whereSeparator: \.isNewline)
          .last
          .map(String.init) ?? "操作失败"
        errorText = message
      }
    }
  }
}

struct ThemePreview: View {
  let imageURL: URL

  var body: some View {
    Group {
      if let image = NSImage(contentsOf: imageURL) {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        ZStack {
          Color(nsColor: .controlBackgroundColor)
          Image(systemName: "photo")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
        }
      }
    }
    .clipped()
  }
}

struct ColorSwatch: View {
  let value: String?

  var body: some View {
    Circle()
      .fill(Color(hex: value) ?? Color.secondary.opacity(0.3))
      .frame(width: 13, height: 13)
      .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
  }
}

struct ThemeCard: View {
  let theme: ThemeItem
  let isActive: Bool
  let isBusy: Bool
  let isFavorite: Bool
  let apply: () -> Void
  let toggleFavorite: () -> Void
  let reveal: () -> Void
  let export: () -> Void
  let openSource: (() -> Void)?
  let requestDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .top) {
        ThemePreview(imageURL: theme.imageURL)
          .aspectRatio(16 / 9, contentMode: .fit)

        HStack(alignment: .top) {
          Button(action: toggleFavorite) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
              .foregroundStyle(isFavorite ? Color.red : Color.primary)
          }
          .buttonStyle(.plain)
          .padding(7)
          .background(.regularMaterial, in: Circle())
          .help(isFavorite ? "取消收藏" : "收藏主题")
          Spacer()
          if isActive {
            Label("当前", systemImage: "checkmark.circle.fill")
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(.regularMaterial, in: Capsule())
          }
        }
        .padding(8)
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(theme.metadata.name)
            .font(.headline)
            .lineLimit(1)
          Spacer(minLength: 8)
          HStack(spacing: 5) {
            ColorSwatch(value: theme.metadata.colors?.accent)
            ColorSwatch(value: theme.metadata.colors?.secondary)
            ColorSwatch(value: theme.metadata.colors?.highlight)
          }
        }

        if let origin = theme.origin {
          Label(
            origin.verified ? "已验证社区主题" : "本地导入主题",
            systemImage: origin.verified ? "checkmark.shield.fill" : "tray.and.arrow.down.fill"
          )
          .font(.caption2.weight(.medium))
          .foregroundStyle(origin.verified ? Color.green : Color.secondary)
        }

        Text(theme.metadata.tagline ?? "Dream Skin 主题")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

        HStack(spacing: 8) {
          if isActive {
            Button(action: apply) {
              Label("重新应用", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
          } else {
            Button(action: apply) {
              Label("应用主题", systemImage: "paintbrush.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)
          }

          Button(action: export) {
            Image(systemName: "square.and.arrow.up")
              .frame(width: 18)
          }
          .buttonStyle(.bordered)
          .help(theme.origin?.verified != true && theme.id.hasPrefix("custom-") ? "导出 .dreamskin 主题包" : "已验证社区主题请从原始来源分享")
          .disabled(isBusy || theme.origin?.verified == true || !theme.id.hasPrefix("custom-"))

          if theme.id.hasPrefix("custom-") {
            Button(action: requestDelete) {
              Image(systemName: "trash")
                .frame(width: 18)
            }
            .buttonStyle(.bordered)
            .help(isActive ? "请先切换到其他主题" : "删除自制主题")
            .disabled(isBusy || isActive)
          }
        }
      }
      .padding(12)
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(isActive ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isActive ? 2 : 1)
    )
    .contextMenu {
      Button(action: reveal) {
        Label("在 Finder 中显示", systemImage: "folder")
      }
      Button(action: export) {
        Label("导出主题包…", systemImage: "square.and.arrow.up")
      }
      .disabled(isBusy || theme.origin?.verified == true || !theme.id.hasPrefix("custom-"))
      Button(action: toggleFavorite) {
        Label(isFavorite ? "取消收藏" : "收藏主题", systemImage: isFavorite ? "heart.slash" : "heart")
      }
      if let openSource {
        Button(action: openSource) {
          Label("查看主题来源", systemImage: "arrow.up.right.square")
        }
      }
      if theme.id.hasPrefix("custom-") {
        Button(role: .destructive, action: requestDelete) {
          Label("删除自制主题", systemImage: "trash")
        }
        .disabled(isBusy || isActive)
      }
    }
  }
}

struct StatusDot: View {
  let active: Bool

  var body: some View {
    Circle()
      .fill(active ? Color.green : Color.secondary)
      .frame(width: 8, height: 8)
  }
}

struct BrandIcon: View {
  var body: some View {
    Group {
      if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
         let image = NSImage(contentsOf: url) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "paintpalette.fill")
          .resizable()
          .scaledToFit()
          .padding(8)
          .foregroundStyle(Color.accentColor)
      }
    }
    .frame(width: 42, height: 42)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

struct ThemeCreatorView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: ThemeStore

  @State private var imageURL: URL?
  @State private var showImporter = false
  @State private var name = "我的主题"
  @State private var tagline = "为今天的工作台换一种气氛。"
  @State private var appearance = "auto"
  @State private var safeArea = "left"
  @State private var taskMode = "ambient"
  @State private var focusX = 0.75
  @State private var focusY = 0.50
  @State private var accent = Color(red: 0.29, green: 0.64, blue: 0.55)
  @State private var secondary = Color(red: 0.88, green: 0.42, blue: 0.33)
  @State private var highlight = Color(red: 0.86, green: 0.68, blue: 0.28)

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "paintbrush.pointed.fill")
          .font(.system(size: 24))
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text("制作主题")
            .font(.title2.weight(.semibold))
          Text("背景、配色与页面构图")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(22)

      Divider()

      HStack(alignment: .top, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
          ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
            if let imageURL, let image = NSImage(contentsOf: imageURL) {
              Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
              VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                  .font(.system(size: 34))
                  .foregroundStyle(.secondary)
                Text("选择一张横向背景图")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
            }
          }
          .aspectRatio(16 / 9, contentMode: .fit)
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.primary.opacity(0.12), lineWidth: 1)
          )

          Button(action: { showImporter = true }) {
            Label(imageURL == nil ? "选择图片" : "更换图片", systemImage: "photo.badge.plus")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)

          VStack(alignment: .leading, spacing: 8) {
            Label("构图焦点", systemImage: "scope")
              .font(.subheadline.weight(.medium))
            HStack {
              Text("水平")
              Slider(value: $focusX, in: 0...1)
              Text(focusX.formatted(.number.precision(.fractionLength(2))))
                .monospacedDigit()
                .frame(width: 34)
            }
            HStack {
              Text("垂直")
              Slider(value: $focusY, in: 0...1)
              Text(focusY.formatted(.number.precision(.fractionLength(2))))
                .monospacedDigit()
                .frame(width: 34)
            }
          }
          .font(.caption)
          .padding(.top, 6)
        }
        .frame(width: 330)

        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 7) {
            Text("主题名称")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextField("我的主题", text: $name)
              .textFieldStyle(.roundedBorder)
          }

          VStack(alignment: .leading, spacing: 7) {
            Text("主题说明")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextField("一句简短说明", text: $tagline)
              .textFieldStyle(.roundedBorder)
          }

          VStack(alignment: .leading, spacing: 7) {
            Text("界面外观")
              .font(.caption)
              .foregroundStyle(.secondary)
            Picker("界面外观", selection: $appearance) {
              Text("自动").tag("auto")
              Text("浅色").tag("light")
              Text("深色").tag("dark")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
          }

          VStack(alignment: .leading, spacing: 7) {
            Text("内容安全区")
              .font(.caption)
              .foregroundStyle(.secondary)
            Picker("内容安全区", selection: $safeArea) {
              Text("自动").tag("auto")
              Text("左侧").tag("left")
              Text("右侧").tag("right")
              Text("居中").tag("center")
              Text("无").tag("none")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
          }

          VStack(alignment: .leading, spacing: 7) {
            Text("任务页背景")
              .font(.caption)
              .foregroundStyle(.secondary)
            Picker("任务页背景", selection: $taskMode) {
              Text("自动").tag("auto")
              Text("氛围").tag("ambient")
              Text("横幅").tag("banner")
              Text("关闭").tag("off")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
          }

          HStack(spacing: 18) {
            ColorPicker("强调", selection: $accent, supportsOpacity: false)
            ColorPicker("辅助", selection: $secondary, supportsOpacity: false)
            ColorPicker("高亮", selection: $highlight, supportsOpacity: false)
          }
          .font(.subheadline)

          Spacer()
        }
        .frame(maxWidth: .infinity)
      }
      .padding(22)

      Divider()

      HStack {
        Spacer()
        Button("取消", action: { dismiss() })
          .keyboardShortcut(.cancelAction)
        Button(action: createTheme) {
          Label("创建并应用", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(imageURL == nil || trimmedName.isEmpty || store.isBusy)
      }
      .padding(18)
    }
    .frame(width: 820, height: 650)
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result { imageURL = urls.first }
    }
  }

  private func createTheme() {
    guard let imageURL, !trimmedName.isEmpty else { return }
    store.createTheme(
      imageURL: imageURL,
      name: trimmedName,
      tagline: tagline.trimmingCharacters(in: .whitespacesAndNewlines),
      appearance: appearance,
      safeArea: safeArea,
      taskMode: taskMode,
      focusX: focusX,
      focusY: focusY,
      accent: accent,
      secondary: secondary,
      highlight: highlight
    )
    dismiss()
  }
}

struct CommunityThemeCard: View {
  let theme: CommunityTheme
  let installed: Bool
  let isBusy: Bool
  let install: () -> Void
  let openSource: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      AsyncImage(url: URL(string: theme.imageURL)) { phase in
        switch phase {
        case .success(let image):
          image.resizable().scaledToFill()
        case .failure:
          ZStack {
            Color(nsColor: .controlBackgroundColor)
            Image(systemName: "photo.badge.exclamationmark")
              .font(.system(size: 28))
              .foregroundStyle(.secondary)
          }
        default:
          ZStack {
            Color(nsColor: .controlBackgroundColor)
            ProgressView()
          }
        }
      }
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipped()

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(theme.name)
            .font(.headline)
          Spacer()
          Label("已验证", systemImage: "checkmark.shield.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
        }
        Text(theme.tagline)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .frame(minHeight: 32, alignment: .topLeading)
        VStack(alignment: .leading, spacing: 4) {
          Label(theme.repository, systemImage: "shippingbox")
          Label("\(theme.license) · 固定提交 \(theme.commit.prefix(8))", systemImage: "doc.text")
          Text(theme.artworkLicense)
            .lineLimit(2)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)

        HStack(spacing: 8) {
          Button(action: install) {
            Label(installed ? "已导入" : "验证并导入", systemImage: installed ? "checkmark" : "tray.and.arrow.down.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(installed || isBusy)
          Button(action: openSource) {
            Image(systemName: "arrow.up.right.square")
          }
          .buttonStyle(.bordered)
          .help("查看 GitHub 来源")
        }
      }
      .padding(14)
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
    )
  }
}

struct CommunityGalleryView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: ThemeStore

  private let columns = [
    GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 16, alignment: .top)
  ]

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "globe.asia.australia.fill")
          .font(.system(size: 24))
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text("社区主题")
            .font(.title2.weight(.semibold))
          Text("只展示锁定 Git 提交、许可证与 SHA-256 均已复核的纯数据主题")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(action: { dismiss() }) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.bordered)
        .help("关闭社区主题")
      }
      .padding(22)

      Divider()

      if store.communityThemes.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "checkmark.shield")
            .font(.system(size: 42))
            .foregroundStyle(.secondary)
          Text("暂无已验证主题")
            .font(.headline)
          Text("社区资源必须先通过来源、授权和哈希审查。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(store.communityThemes) { theme in
              CommunityThemeCard(
                theme: theme,
                installed: store.isCommunityThemeInstalled(theme),
                isBusy: store.isBusy,
                install: { store.installCommunityTheme(theme) },
                openSource: { store.openCommunitySource(theme) }
              )
            }
          }
          .padding(22)
        }
      }

      Divider()
      HStack(spacing: 8) {
        Image(systemName: "lock.shield.fill")
          .foregroundStyle(.green)
        Text("下载仅允许固定提交的 GitHub Raw 文件并校验 SHA-256；许可受限或素材权利不清的主题不会提供一键导入。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 14)
    }
    .frame(width: 900, height: 650)
  }
}

struct HelpRow: View {
  let icon: String
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 18))
        .foregroundStyle(Color.accentColor)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
        Text(text)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct HelpView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: ThemeStore

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "questionmark.circle.fill")
          .font(.system(size: 24))
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text("Dream Skin 帮助")
            .font(.title2.weight(.semibold))
          Text("版本 1.9.0")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(action: { dismiss() }) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.bordered)
        .help("关闭帮助")
      }
      .padding(22)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HelpRow(
            icon: "paintpalette.fill",
            title: "切换主题",
            text: "在主题库中查看预览并点击“应用主题”。当前主题显示蓝色边框；运行状态应为“运行中”。"
          )
          HelpRow(
            icon: "paintbrush.pointed.fill",
            title: "制作主题",
            text: "点击“制作主题”，选择背景图、名称、明暗外观、内容安全区和三种配色。创建后会自动保存到主题库并立即应用。"
          )
          HelpRow(
            icon: "tray.and.arrow.down.fill",
            title: "导入别人制作的主题",
            text: "可选择一个包含 theme.json 与背景图的文件夹，或选择 .dreamskin 单文件主题包；旧版 .codexskin 仍兼容。导入器只提取数据文件，不复制或运行第三方脚本与 CSS。"
          )
          HelpRow(
            icon: "checkmark.shield.fill",
            title: "已验证社区主题",
            text: "社区页只收录来源、许可证、固定 Git 提交和 SHA-256 都已审核的主题。代码采用 MIT 不代表其中的明星、动漫、游戏或品牌图片也可自由分发。"
          )
          HelpRow(
            icon: "square.and.arrow.up",
            title: "分享主题",
            text: "自制主题和本地导入主题可导出为 .dreamskin 数据包，其中只有 JSON、背景图和完整性哈希。请先确认原素材允许再分发；已验证社区主题保留原始来源链接，并禁止二次打包。"
          )
          HelpRow(
            icon: "rectangle.inset.filled.and.person.filled",
            title: "背景构图",
            text: "横向图片效果最好。把主要人物或物体放在右侧，并为左侧标题和项目列表保留低对比空间；焦点滑杆用于控制裁切中心。"
          )
          HelpRow(
            icon: "arrow.clockwise",
            title: "应用后没有变化",
            text: "先点击左侧“重新应用”。首页背景最明显，任务页默认使用较轻的氛围层；制作主题时可把任务页背景改成“横幅”。"
          )
          HelpRow(
            icon: "folder.fill",
            title: "主题资源位置",
            text: "自制主题保存在 ~/Library/Application Support/CodexDreamSkinStudio/themes，原始导入图片保存在相邻的 images 文件夹。"
          )
          HelpRow(
            icon: "lock.shield.fill",
            title: "安全边界",
            text: "工具只通过 127.0.0.1 回环调试端口注入样式，不修改官方 Codex.app、app.asar、代码签名、API Key 或 Base URL。"
          )

          HStack(spacing: 10) {
            Button(action: store.openThemesFolder) {
              Label("打开主题文件夹", systemImage: "folder")
            }
            Button(action: store.openImagesFolder) {
              Label("打开图片文件夹", systemImage: "photo.on.rectangle")
            }
          }
        }
        .padding(24)
      }
    }
    .frame(width: 640, height: 610)
  }
}

struct SidebarView: View {
  @ObservedObject var store: ThemeStore
  @Binding var showCreator: Bool
  @Binding var showImporter: Bool
  @Binding var showCommunity: Bool
  @Binding var showHelp: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 10) {
        BrandIcon()
        VStack(alignment: .leading, spacing: 1) {
          Text("Dream Skin")
            .font(.headline)
          Text("主题工作室")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("当前主题")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(store.activeThemeName)
          .font(.title3.weight(.semibold))
          .lineLimit(2)
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          StatusDot(active: store.sessionState == "运行中")
          Text(store.sessionState)
          Spacer()
        }
        HStack(spacing: 8) {
          Image(systemName: store.codexIsOpen ? "macwindow" : "macwindow.badge.xmark")
            .frame(width: 10)
          Text(store.codexIsOpen ? "Codex 已打开" : "Codex 未打开")
          Spacer()
        }
      }
      .font(.subheadline)
      .padding(12)
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(spacing: 8) {
        Button(action: { showCreator = true }) {
          Label("制作主题", systemImage: "paintbrush.pointed.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        Button(action: { showCommunity = true }) {
          Label("社区主题", systemImage: "globe.asia.australia.fill")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button(action: { showImporter = true }) {
          Label("导入主题包", systemImage: "tray.and.arrow.down.fill")
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Button(action: store.reapply) {
          Label("重新应用", systemImage: "arrow.clockwise")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button(action: store.openImagesFolder) {
          Label("图片文件夹", systemImage: "folder")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button(action: store.pause) {
          Label("暂停皮肤", systemImage: "pause.circle")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button(action: { showHelp = true }) {
          Label("帮助", systemImage: "questionmark.circle")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .disabled(store.isBusy)

      Spacer()

      if store.isBusy {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(store.activityText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      } else if !store.activityText.isEmpty {
        Label(store.activityText, systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(20)
    .frame(width: 230)
    .background(Color(nsColor: .underPageBackgroundColor))
  }
}

struct ThemeLibraryView: View {
  @StateObject private var store = ThemeStore()
  @State private var showCreator = false
  @State private var showImporter = false
  @State private var showCommunity = false
  @State private var showHelp = false
  @State private var themeToDelete: ThemeItem?
  @State private var searchText = ""
  @State private var themeFilter = "all"

  private let columns = [
    GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 16, alignment: .top)
  ]

  private var themeImportTypes: [UTType] {
    [
      UTType(filenameExtension: "dreamskin") ?? .data,
      UTType(filenameExtension: "codexskin") ?? .data,
      .folder
    ]
  }

  private var filteredThemes: [ThemeItem] {
    store.themes.filter { theme in
      let matchesSearch = searchText.isEmpty
        || theme.metadata.name.localizedCaseInsensitiveContains(searchText)
        || (theme.metadata.tagline ?? "").localizedCaseInsensitiveContains(searchText)
      let matchesFilter: Bool
      switch themeFilter {
      case "favorites": matchesFilter = store.favoriteThemeIDs.contains(theme.id)
      case "built-in": matchesFilter = theme.origin == nil && !theme.id.hasPrefix("custom-")
      case "mine": matchesFilter = theme.id.hasPrefix("custom-")
      case "verified": matchesFilter = theme.origin?.verified == true
      default: matchesFilter = true
      }
      return matchesSearch && matchesFilter
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      SidebarView(
        store: store,
        showCreator: $showCreator,
        showImporter: $showImporter,
        showCommunity: $showCommunity,
        showHelp: $showHelp
      )

      Divider()

      VStack(spacing: 0) {
        HStack(alignment: .center) {
          VStack(alignment: .leading, spacing: 3) {
            Text("主题库")
              .font(.title2.weight(.semibold))
            Text("显示 \(filteredThemes.count) / \(store.themes.count) 套主题")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(action: { showCommunity = true }) {
            Label("社区", systemImage: "globe.asia.australia.fill")
          }
          .buttonStyle(.bordered)
          .disabled(store.isBusy)
          Button(action: { showImporter = true }) {
            Image(systemName: "tray.and.arrow.down")
          }
          .buttonStyle(.bordered)
          .help("导入主题文件夹、.dreamskin 或旧版 .codexskin")
          .disabled(store.isBusy)
          Button(action: { showCreator = true }) {
            Label("制作主题", systemImage: "plus")
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.isBusy)
          Button(action: { showHelp = true }) {
            Image(systemName: "questionmark.circle")
          }
          .buttonStyle(.bordered)
          .help("打开帮助")
          Button(action: store.refresh) {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
          .help("刷新主题和运行状态")
          .disabled(store.isBusy)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)

        HStack(spacing: 12) {
          TextField("搜索主题", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 300)
          Picker("来源", selection: $themeFilter) {
            Text("全部").tag("all")
            Text("收藏").tag("favorites")
            Text("内置").tag("built-in")
            Text("自制/导入").tag("mine")
            Text("已验证").tag("verified")
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(maxWidth: 430)
          Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)

        Divider()

        if filteredThemes.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: "paintpalette")
              .font(.system(size: 42))
              .foregroundStyle(.secondary)
            Text(store.themes.isEmpty ? "主题库为空" : "没有匹配的主题")
              .font(.headline)
            Text(store.themes.isEmpty ? "可制作、导入或从社区添加主题。" : "调整搜索词或来源筛选。")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
              ForEach(filteredThemes) { theme in
                ThemeCard(
                  theme: theme,
                  isActive: store.activeThemeID == theme.id,
                  isBusy: store.isBusy,
                  isFavorite: store.favoriteThemeIDs.contains(theme.id),
                  apply: { store.apply(theme) },
                  toggleFavorite: { store.toggleFavorite(theme) },
                  reveal: { store.reveal(theme) },
                  export: { store.exportTheme(theme) },
                  openSource: theme.origin?.sourceURL == nil ? nil : { store.openThemeSource(theme) },
                  requestDelete: { themeToDelete = theme }
                )
              }
            }
            .padding(22)
          }
        }

        if let error = store.errorText {
          HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text(error)
              .font(.caption)
              .lineLimit(2)
            Spacer()
          }
          .padding(.horizontal, 18)
          .padding(.vertical, 10)
          .background(Color.orange.opacity(0.08))
        }
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 850, minHeight: 590)
    .sheet(isPresented: $showCreator) {
      ThemeCreatorView(store: store)
    }
    .sheet(isPresented: $showCommunity) {
      CommunityGalleryView(store: store)
    }
    .sheet(isPresented: $showHelp) {
      HelpView(store: store)
    }
    .onReceive(NotificationCenter.default.publisher(for: .showDreamSkinHelp)) { _ in
      showHelp = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .showDreamSkinCreator)) { _ in
      showCreator = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .showDreamSkinImporter)) { _ in
      showImporter = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .showDreamSkinCommunity)) { _ in
      showCommunity = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .reapplyDreamSkin)) { _ in
      store.reapply()
    }
    .onReceive(NotificationCenter.default.publisher(for: .pauseDreamSkin)) { _ in
      store.pause()
    }
    .alert(
      "删除自制主题？",
      isPresented: Binding(
        get: { themeToDelete != nil },
        set: { if !$0 { themeToDelete = nil } }
      ),
      presenting: themeToDelete
    ) { theme in
      Button("删除", role: .destructive) {
        store.delete(theme)
        themeToDelete = nil
      }
      Button("取消", role: .cancel) {
        themeToDelete = nil
      }
    } message: { theme in
      Text("“\(theme.metadata.name)”及其主题副本将从主题库删除，原始导入图片仍保留在 images 文件夹。")
    }
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: themeImportTypes,
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let source = urls.first { store.importTheme(from: source) }
      case .failure(let error):
        store.errorText = "无法选择主题：\(error.localizedDescription)"
      }
    }
  }
}

extension Color {
  init?(hex: String?) {
    guard let source = hex else { return nil }
    let value = source.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
    self.init(
      red: Double((number >> 16) & 0xff) / 255,
      green: Double((number >> 8) & 0xff) / 255,
      blue: Double(number & 0xff) / 255
    )
  }

  var hexString: String {
    let source = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
    let red = Int((source.redComponent * 255).rounded())
    let green = Int((source.greenComponent * 255).rounded())
    let blue = Int((source.blueComponent * 255).rounded())
    return String(format: "#%02x%02x%02x", red, green, blue)
  }
}

extension Notification.Name {
  static let showDreamSkinHelp = Notification.Name("showDreamSkinHelp")
  static let showDreamSkinCreator = Notification.Name("showDreamSkinCreator")
  static let showDreamSkinImporter = Notification.Name("showDreamSkinImporter")
  static let showDreamSkinCommunity = Notification.Name("showDreamSkinCommunity")
  static let reapplyDreamSkin = Notification.Name("reapplyDreamSkin")
  static let pauseDreamSkin = Notification.Name("pauseDreamSkin")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var fallbackWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
       let icon = NSImage(contentsOf: iconURL) {
      NSApp.applicationIconImage = icon
    }
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self else { return }
      if !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) {
        self.showMainWindow()
      }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showMainWindow()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func showMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
      window.makeKeyAndOrderFront(nil)
      return
    }

    if fallbackWindow == nil {
      let controller = NSHostingController(rootView: ThemeLibraryView())
      let window = NSWindow(contentViewController: controller)
      window.title = "Codex Dream Skin Switcher"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.setContentSize(NSSize(width: 1050, height: 680))
      window.minSize = NSSize(width: 850, height: 590)
      window.isReleasedWhenClosed = false
      window.center()
      fallbackWindow = window
    }
    fallbackWindow?.makeKeyAndOrderFront(nil)
  }
}

@main
struct DreamSkinSwitcherApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup("Codex Dream Skin Switcher") {
      ThemeLibraryView()
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("显示主窗口") {
          (NSApp.delegate as? AppDelegate)?.showMainWindow()
        }
        .keyboardShortcut("0", modifiers: .command)
      }
      CommandGroup(replacing: .help) {
        Button("Dream Skin 帮助") {
          NotificationCenter.default.post(name: .showDreamSkinHelp, object: nil)
        }
        .keyboardShortcut("?", modifiers: .command)
      }
      CommandMenu("主题") {
        Button("制作主题…") {
          NotificationCenter.default.post(name: .showDreamSkinCreator, object: nil)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Button("导入主题包…") {
          NotificationCenter.default.post(name: .showDreamSkinImporter, object: nil)
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])

        Button("浏览社区主题…") {
          NotificationCenter.default.post(name: .showDreamSkinCommunity, object: nil)
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])

        Divider()

        Button("重新应用当前主题") {
          NotificationCenter.default.post(name: .reapplyDreamSkin, object: nil)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Button("暂停皮肤") {
          NotificationCenter.default.post(name: .pauseDreamSkin, object: nil)
        }
      }
    }
  }
}
