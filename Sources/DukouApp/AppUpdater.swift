import AppKit
import Combine
import DukouCore
import Foundation
import Sparkle

/// Checks the project's public GitHub releases. A configured signed feed uses
/// Sparkle; without one, checks report versions and open the release page.
@MainActor
final class AppUpdater: ObservableObject {
    private static let requestTimeout: TimeInterval = 15
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isCheckingGitHub = false

    private let controller: SPUStandardUpdaterController
    let isConfigured: Bool
    private var canCheckObserver: AnyCancellable?

    init(bundle: Bundle = .main) {
        isConfigured = bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        guard isConfigured else { return }
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObserver = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
    }

    /// The daily check, as the 通用 pane's switch. Reads false and ignores
    /// writes in an unconfigured build, which is the honest state of a
    /// `swift run` binary with no feed to check.
    var automaticallyChecksForUpdates: Bool {
        get {
            guard isConfigured else { return false }
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            guard isConfigured else { return }
            // Sparkle owns the value; the view only needs to know it moved.
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var actionTitle: String {
        isCheckingGitHub ? L10n.text("正在检查更新…") : L10n.text("检查更新…")
    }

    var canPerformAction: Bool {
        isConfigured ? canCheckForUpdates : !isCheckingGitHub
    }

    func showUpdates() {
        if isConfigured {
            controller.checkForUpdates(nil)
        } else {
            checkGitHubRelease()
        }
    }

    private func checkGitHubRelease() {
        guard !isCheckingGitHub else { return }
        isCheckingGitHub = true
        Task {
            defer { isCheckingGitHub = false }
            do {
                let repository = AppLinks.github
                guard repository.host == "github.com", repository.pathComponents.count == 3 else {
                    throw CheckFailure.repositoryURL
                }
                let response = try await request(AppLinks.releases.appendingPathComponent("latest"))
                guard response.statusCode == 200 else { throw CheckFailure.http(response.statusCode) }
                guard let releaseURL = response.url else { throw CheckFailure.response }
                if releaseURL == AppLinks.releases {
                    showResult(
                        title: L10n.text("尚未发布正式版本"),
                        detail: L10n.format("当前版本：%@（构建 %@）。仓库尚无正式 Release，发布后即可检测版本更新。", AppVersion.short, AppVersion.build),
                        releaseURL: AppLinks.releases
                    )
                    return
                }
                let components = releaseURL.pathComponents
                let releasePrefix = AppLinks.releases.appendingPathComponent("tag").pathComponents
                guard releaseURL.host == repository.host, components.count == releasePrefix.count + 1,
                      Array(components.dropLast()) == releasePrefix else { throw CheckFailure.response }
                let tag = releaseURL.lastPathComponent
                let latest = try versionNumbers(tag)
                let current = try versionNumbers(AppVersion.short)
                let newer = current.lexicographicallyPrecedes(latest)
                let detail = L10n.format("当前版本：%@（构建 %@）", AppVersion.short, AppVersion.build)
                    + "\n" + L10n.format("最新发行版本：%@", tag)
                showResult(
                    title: newer ? L10n.format("发现新版本 %@", tag) : L10n.text("没有发现更高版本"),
                    detail: detail,
                    releaseURL: releaseURL
                )
            } catch {
                showResult(title: L10n.text("检查更新失败"), detail: error.localizedDescription, releaseURL: nil)
            }
        }
    }

    private enum CheckFailure: LocalizedError {
        case repositoryURL, response, http(Int), version(String)

        var errorDescription: String? {
            switch self {
            case .repositoryURL: L10n.text("项目地址必须是公开的 GitHub 仓库地址。")
            case .response: L10n.text("GitHub 没有返回有效的更新响应。")
            case .http(let code): L10n.format("GitHub 更新请求失败（HTTP %d）。", code)
            case .version(let value): L10n.format("无法识别版本号 %@，请使用 v1.2.3 或 1.2.3 格式。", value)
            }
        }
    }

    private func request(_ url: URL) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("xiaoai-archive/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CheckFailure.response }
        return response
    }

    private func versionNumbers(_ value: String) throws -> [Int] {
        let version = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw CheckFailure.version(value) }
        return try parts.map { part in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let number = Int(part) else {
                throw CheckFailure.version(value)
            }
            return number
        }
    }

    private func showResult(title: String, detail: String, releaseURL: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        if releaseURL != nil {
            alert.addButton(withTitle: L10n.text("查看发行说明与下载"))
            alert.addButton(withTitle: L10n.text("关闭"))
        } else {
            alert.addButton(withTitle: L10n.text("关闭"))
        }
        if alert.runModal() == .alertFirstButtonReturn, let releaseURL { AppLinks.open(releaseURL) }
    }
}
