import AppKit
import Combine

struct LauncherApplication: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var path: String
    var usesOwnMappings: Bool

    var profileID: String { "app:\(id)" }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    var installedURL: URL? {
        if hasSavedLocation { return url }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    fileprivate var hasSavedLocation: Bool {
        FileManager.default.fileExists(atPath: path) && Bundle(url: url)?.bundleIdentifier == id
    }
}

struct LauncherImportResult {
    var added: [LauncherApplication] = []
    var duplicateCount = 0
    var invalidCount = 0
}

@MainActor
final class ApplicationLaunchStore: ObservableObject {
    @Published private(set) var applications: [LauncherApplication] = []
    @Published private(set) var foregroundBundleIdentifier: String?
    @Published var launchError: String?

    private static let catalogKey = "launcherApplications"
    private let defaults: UserDefaults
    private var workspaceObserver: NSObjectProtocol?

    var foregroundProfileID: String? {
        applications.first { $0.id == foregroundBundleIdentifier && $0.usesOwnMappings }?.profileID
    }

    var isOwnAppForeground: Bool {
        foregroundBundleIdentifier != nil && foregroundBundleIdentifier == Bundle.main.bundleIdentifier
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.catalogKey),
           let saved = try? JSONDecoder().decode([LauncherApplication].self, from: data) {
            var seen = Set<String>()
            applications = saved.filter { seen.insert($0.id).inserted }
        }
        updateForeground(NSWorkspace.shared.frontmostApplication)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.updateForeground(application ?? NSWorkspace.shared.frontmostApplication)
            }
        }
    }

    deinit {
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    @discardableResult
    func importApplications(at urls: [URL]) -> LauncherImportResult {
        var catalog = applications
        var result = LauncherImportResult()
        for url in urls {
            guard let application = Self.application(at: url) else {
                result.invalidCount += 1
                continue
            }
            if let index = catalog.firstIndex(where: { $0.id == application.id }) {
                result.duplicateCount += 1
                let saved = catalog[index]
                if !saved.hasSavedLocation {
                    catalog[index].name = application.name
                    catalog[index].path = application.path
                }
            } else {
                catalog.append(application)
                result.added.append(application)
            }
        }
        save(catalog)
        return result
    }

    private static func application(at url: URL) -> LauncherApplication? {
        guard url.isFileURL else { return nil }
        var target = ((url as NSURL).filePathURL ?? url).resolvingSymlinksInPath()
        if (try? target.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true {
            // Resolving local Finder aliases should not mount or prompt for missing external volumes.
            guard let resolved = try? URL(resolvingAliasFileAt: target, options: [.withoutUI, .withoutMounting])
            else { return nil }
            target = resolved.resolvingSymlinksInPath()
        }
        target = target.standardizedFileURL
        guard target.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let bundle = Bundle(url: target), let id = bundle.bundleIdentifier, !id.isEmpty,
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              id != Bundle.main.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: target.path)
        let title = name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        return LauncherApplication(id: id, name: title, path: target.path, usesOwnMappings: false)
    }

    func setOwnMappings(_ enabled: Bool, for id: String) {
        guard let index = applications.firstIndex(where: { $0.id == id }) else { return }
        var catalog = applications
        catalog[index].usesOwnMappings = enabled
        save(catalog)
    }

    func move(_ id: String, by offset: Int) {
        guard let index = applications.firstIndex(where: { $0.id == id }),
              applications.indices.contains(index + offset) else { return }
        var catalog = applications
        catalog.swapAt(index, index + offset)
        save(catalog)
    }

    func remove(_ id: String) {
        save(applications.filter { $0.id != id })
    }

    func launch(_ application: LauncherApplication, onOpened: @escaping @MainActor () -> Void) {
        guard let url = application.installedURL else {
            launchError = "找不到「\(application.name)」。"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.launchError = error.localizedDescription
                } else {
                    onOpened()
                }
            }
        }
    }

    private func save(_ catalog: [LauncherApplication]) {
        guard catalog != applications else { return }
        applications = catalog
        if let data = try? JSONEncoder().encode(catalog) { defaults.set(data, forKey: Self.catalogKey) }
    }

    private func updateForeground(_ application: NSRunningApplication?) {
        let identifier = application?.bundleIdentifier
        if identifier != foregroundBundleIdentifier { foregroundBundleIdentifier = identifier }
    }
}
