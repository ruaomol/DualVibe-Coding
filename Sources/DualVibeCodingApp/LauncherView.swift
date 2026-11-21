import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @ObservedObject var launcher: ApplicationLaunchStore
    @StateObject private var state = LauncherCatalogState()

    let onEditMapping: (LauncherApplication) -> Void

    private var filteredApplications: [LauncherApplication] {
        guard !state.term.isEmpty else { return launcher.applications }
        return launcher.applications.filter {
            $0.name.localizedStandardContains(state.term) || $0.id.localizedStandardContains(state.term)
        }
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if launcher.applications.isEmpty {
                        emptyCatalog
                    } else {
                        catalog
                    }
                    if let feedback = state.feedback {
                        Label(feedback.message, systemImage: feedback.added ? "checkmark.circle.fill" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(feedback.added ? Color.accentColor : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(minHeight: 560, alignment: .top)
            }
            .scrollContentBackground(.hidden)
            .background(.regularMaterial)

            if state.isDropTargeted {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 30, weight: .medium))
                    Text("松开添加 App")
                        .font(.title3.weight(.semibold))
                    Text("支持同时拖入多个应用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial.opacity(0.86), in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.accentColor.opacity(0.72), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(12)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $state.isDropTargeted) { providers in
            LauncherDrop.accept(providers, into: launcher, onComplete: applyImport)
        }
    }

    private var emptyCatalog: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("应用库为空")
                .font(.title2.weight(.semibold))
            Text("把 .app 拖到这里")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("选择 App…", action: chooseApplications)
                    .buttonStyle(.borderedProminent)
                if !LauncherSuggestions.applications.isEmpty {
                    Button("添加常用 App", action: addSuggestions)
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 480)
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("应用库")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("拖入 .app 添加")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                searchField
            }

            if filteredApplications.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的应用", systemImage: "magnifyingglass")
                } actions: {
                    Button("清除搜索") { state.query = "" }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], alignment: .leading, spacing: 14) {
                    ForEach(filteredApplications) { application in
                        applicationTile(application)
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("搜索应用", text: $state.query)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索应用")
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 184)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func dropWell(expanded: Bool) -> some View {
        HStack(spacing: expanded ? 18 : 10) {
            Image(systemName: state.isDropTargeted ? "arrow.down.to.line" : "plus.app")
                .font(.system(size: expanded ? 24 : 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: expanded ? 52 : 34, height: expanded ? 52 : 34)
                .background(Color.accentColor.opacity(state.isDropTargeted ? 0.18 : 0.09),
                            in: RoundedRectangle(cornerRadius: expanded ? 14 : 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.isDropTargeted ? "松开以添加" : "从 Finder 拖入 App")
                    .font(expanded ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                if expanded {
                    Text("可同时拖入多个应用，添加后即可用手柄启动。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("选择应用…", action: chooseApplications)
                .buttonStyle(.bordered)
                .controlSize(expanded ? .regular : .small)
        }
        .padding(expanded ? 20 : 10)
        .frame(maxWidth: .infinity, minHeight: expanded ? 114 : 0, alignment: .leading)
        .background(Color.accentColor.opacity(state.isDropTargeted ? 0.10 : 0.025),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(state.isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: state.isDropTargeted ? 1.6 : 1, dash: [5, 4]))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("应用拖放区")
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("可快速添加")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(LauncherSuggestions.applications) { application in
                    Button {
                        applyImport(launcher.importApplications(at: [application.url]))
                    } label: {
                        HStack(spacing: 6) {
                            LauncherArtwork(application: application, size: 22)
                            Text(application.name).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "plus")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("添加\(application.name)")
                }
            }
        }
    }

    private func applicationTile(_ application: LauncherApplication) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 4) {
                Button {
                    open(application)
                } label: {
                    HStack(spacing: 8) {
                        LauncherArtwork(application: application, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(application.name)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(application.usesOwnMappings ? "独立映射" : "全局映射")
                                .font(.caption)
                                .foregroundStyle(application.usesOwnMappings ? Color.accentColor : Color.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开\(application.name)")
                .accessibilityLabel("打开\(application.name)")

                tileMenu(for: application)
            }

            Divider()

            Button {
                edit(application)
            } label: {
                Label(application.usesOwnMappings ? "编辑独立映射" : "设置独立映射", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(application.usesOwnMappings ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑\(application.name)的映射")
        }
        .padding(16)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }

    private func tileMenu(for application: LauncherApplication) -> some View {
        Menu {
            Button("打开 App", systemImage: "arrow.up.right.square") { open(application) }
            if application.usesOwnMappings {
                Button("改用全局映射", systemImage: "globe") {
                    launcher.setOwnMappings(false, for: application.id)
                }
            }
            Divider()
            Button("向前移动", systemImage: "arrow.left") { launcher.move(application.id, by: -1) }
                .disabled(launcher.applications.first?.id == application.id)
            Button("向后移动", systemImage: "arrow.right") { launcher.move(application.id, by: 1) }
                .disabled(launcher.applications.last?.id == application.id)
            Divider()
            Button("从启动台移除", systemImage: "minus.circle", role: .destructive) {
                launcher.remove(application.id)
            }
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
        if result.duplicateCount > 0 { parts.append("\(result.duplicateCount) 个已在启动台") }
        if result.invalidCount > 0 { parts.append("\(result.invalidCount) 项无法添加，请拖入 .app") }
        state.feedback = parts.isEmpty ? nil : .init(message: parts.joined(separator: " · "), added: !result.added.isEmpty)
    }

    private func open(_ application: LauncherApplication) {
        launcher.launch(application, onOpened: {})
    }

    private func edit(_ application: LauncherApplication) {
        launcher.setOwnMappings(true, for: application.id)
        onEditMapping(application)
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
