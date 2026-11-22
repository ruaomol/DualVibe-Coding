import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @ObservedObject var launcher: ApplicationLaunchStore
    @EnvironmentObject private var i18n: LocalizationStore
    @StateObject private var state = LauncherCatalogState()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onEditMapping: (LauncherApplication) -> Void

    private var filteredApplications: [LauncherApplication] {
        guard !state.term.isEmpty else { return launcher.applications }
        return launcher.applications.filter {
            $0.name.localizedStandardContains(state.term) || $0.id.localizedStandardContains(state.term)
        }
    }

    var body: some View {
        let _ = i18n.language
        ZStack {
            Group {
                if launcher.applications.isEmpty {
                    emptyCatalog
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(L("已添加 \(launcher.applications.count) 个应用",
                                       "\(launcher.applications.count) Apps"))
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                                Spacer()
                                Text(L("支持直接从访达拖入 .app", "Drag .app bundles from Finder to add"))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            if filteredApplications.isEmpty {
                                ContentUnavailableView {
                                    Label(L("没有匹配的应用", "No Matching Apps"), systemImage: "magnifyingglass")
                                } description: {
                                    Text(L("未找到与「\(state.term)」相关的应用。", "No apps match “\(state.term)”."))
                                } actions: {
                                    Button(L("清除搜索", "Clear Search")) { state.query = "" }
                                }
                                .frame(minHeight: 360)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: 14)], alignment: .leading, spacing: 14) {
                                    ForEach(filteredApplications) { application in
                                        LauncherAppTile(
                                            application: application,
                                            isFirst: launcher.applications.first?.id == application.id,
                                            isLast: launcher.applications.last?.id == application.id,
                                            onOpen: { open(application) },
                                            onEdit: { edit(application) },
                                            onUseGlobal: { launcher.setOwnMappings(false, for: application.id) },
                                            onMoveBack: { launcher.move(application.id, by: -1) },
                                            onMoveForward: { launcher.move(application.id, by: 1) },
                                            onRemove: {
                                                withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                                                    launcher.remove(application.id)
                                                }
                                            }
                                        )
                                    }
                                }
                            }

                            if let feedback = state.feedback {
                                DualVibeStatusBadge(
                                    text: feedback.message,
                                    systemImage: feedback.added ? "checkmark.circle.fill" : "info.circle",
                                    tone: feedback.added ? .accent : .neutral
                                )
                                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: 1040)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }

            if state.isDropTargeted {
                dropOverlay
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .searchable(text: $state.query, prompt: L("搜索应用", "Search Apps"))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    chooseApplications()
                } label: {
                    Label(L("添加 App…", "Add Apps…"), systemImage: "plus")
                }
                .help(L("从应用程序文件夹选择并添加 App", "Select apps from Applications to add"))
            }
        }
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: state.isDropTargeted)
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: launcher.applications)
        .onDrop(of: [.fileURL], isTargeted: $state.isDropTargeted) { providers in
            LauncherDrop.accept(providers, into: launcher, onComplete: applyImport)
        }
    }

    private var emptyCatalog: some View {
        ContentUnavailableView {
            Label(L("应用库为空", "App Library is Empty"), systemImage: "square.grid.2x2")
        } description: {
            Text(L("将 .app 从访达直接拖入此处，或点击下方按钮添加常用应用，随后即可配置快捷轮盘与独立按键映射。",
                   "Drag .app bundles from Finder here or add common apps to configure Quick Wheel slots and per-app mappings."))
        } actions: {
            HStack(spacing: 10) {
                Button(L("选择 App…", "Choose Apps…"), action: chooseApplications)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if !LauncherSuggestions.applications.isEmpty {
                    Button(L("添加常用 App", "Add Common Apps"), action: addSuggestions)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dropOverlay: some View {
        let accent = DualVibePalette.lightBar(for: colorScheme)
        return VStack(spacing: 10) {
            DualVibeIconBadge(systemImage: "arrow.down.app.fill", tint: accent, size: 54, cornerRadius: 15)
            Text(L("松开添加 App", "Drop to Add Apps"))
                .font(.title3.weight(.semibold))
            Text(L("支持同时拖入多个应用程序", "Multiple .app bundles supported"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent.opacity(0.72), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(14)
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        applyImport(launcher.importApplications(at: panel.urls))
    }

    private func addSuggestions() {
        applyImport(launcher.importApplications(at: LauncherSuggestions.applications.map { $0.url }))
    }

    private func applyImport(_ result: LauncherImportResult) {
        var parts: [String] = []
        if !result.added.isEmpty {
            state.query = ""
            parts.append("已添加 \(result.added.count) 个应用")
        }
        if result.duplicateCount > 0 { parts.append("\(result.duplicateCount) 个已在应用库") }
        if result.invalidCount > 0 { parts.append("\(result.invalidCount) 项无法添加，请拖入 .app") }
        withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
            state.feedback = parts.isEmpty ? nil : .init(message: parts.joined(separator: " · "), added: !result.added.isEmpty)
        }
    }

    private func open(_ application: LauncherApplication) {
        launcher.launch(application, onOpened: {})
    }

    private func edit(_ application: LauncherApplication) {
        launcher.setOwnMappings(true, for: application.id)
        onEditMapping(application)
    }
}

private struct LauncherAppTile: View {
    let application: LauncherApplication
    let isFirst: Bool
    let isLast: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onUseGlobal: () -> Void
    let onMoveBack: () -> Void
    let onMoveForward: () -> Void
    let onRemove: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hover = DualVibeHoverState()

    var body: some View {
        let isHovered = hover.isHovered
        let accent = DualVibePalette.lightBar(for: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: onOpen) {
                    HStack(spacing: 11) {
                        LauncherArtwork(application: application, size: 46)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(application.name)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            DualVibeStatusBadge(
                                text: application.usesOwnMappings ? L("独立映射", "Per-App") : L("全局映射", "Global"),
                                systemImage: application.usesOwnMappings ? "slider.horizontal.3" : "globe",
                                tone: application.usesOwnMappings ? .accent : .neutral
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开 \(application.name)")
                .accessibilityLabel("打开\(application.name)")

                Menu {
                    menuActions
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(application.name) 设置")
            }

            Divider().opacity(0.7)

            Button(action: onEdit) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                    Text(application.usesOwnMappings ? L("编辑独立映射", "Edit Per-App Mapping") : L("设置独立映射", "Set Per-App Mapping"))
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(application.usesOwnMappings ? accent : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑\(application.name)的映射")
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isHovered ? accent.opacity(0.45) : DualVibePalette.hairlineBorder(for: colorScheme),
                    lineWidth: isHovered ? 1.1 : 0.8
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(isHovered ? (colorScheme == .dark ? 0.30 : 0.08) : 0.04),
                radius: isHovered ? 12 : 5,
                y: isHovered ? 4 : 2)
        .offset(y: isHovered && !reduceMotion ? -1.5 : 0)
        .onHover { hovering in
            withAnimation(DualVibeMotion.resolve(DualVibeMotion.tactile, reduceMotion: reduceMotion)) {
                hover.isHovered = hovering
            }
        }
        .contextMenu { menuActions }
    }

    @ViewBuilder
    private var menuActions: some View {
        Button(L("打开 App", "Open App"), systemImage: "arrow.up.right.square", action: onOpen)
        Button(application.usesOwnMappings ? L("编辑独立映射", "Edit Per-App Mapping") : L("设置独立映射", "Set Per-App Mapping"),
               systemImage: "slider.horizontal.3", action: onEdit)
        if application.usesOwnMappings {
            Button(L("改用全局映射", "Use Global Mapping"), systemImage: "globe", action: onUseGlobal)
        }
        Divider()
        Button(L("向前移动", "Move Back"), systemImage: "arrow.left", action: onMoveBack).disabled(isFirst)
        Button(L("向后移动", "Move Forward"), systemImage: "arrow.right", action: onMoveForward).disabled(isLast)
        Divider()
        Button(L("从应用库移除", "Remove from Library"), systemImage: "minus.circle", role: .destructive, action: onRemove)
    }
}

struct LauncherArtwork: View {
    let application: LauncherApplication
    let size: CGFloat

    var body: some View {
        Group {
            if let url = application.installedURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.64))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private final class LauncherCatalogState: ObservableObject {
    struct Feedback {
        let message: String
        let added: Bool
    }

    @Published var query = ""
    @Published var isDropTargeted = false
    @Published var feedback: Feedback?
    var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
}

@MainActor
private enum LauncherSuggestions {
    static let applications: [LauncherApplication] = [
        "com.apple.Terminal", "com.apple.Safari", "com.apple.Notes", "com.apple.TextEdit",
    ].compactMap { identifier in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              Bundle(url: url)?.bundleIdentifier == identifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return LauncherApplication(id: identifier, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                                   path: url.path, usesOwnMappings: false)
    }
}
