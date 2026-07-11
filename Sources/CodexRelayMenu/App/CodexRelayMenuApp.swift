import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var terminationHandler: (() -> Void)?
    private var previewStore: RelayMenuStore?
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(CodexRelayMenuApp.previewMode ? .regular : .accessory)
        guard CodexRelayMenuApp.previewMode else { return }

        let store = RelayMenuStore(startSupervisor: false, loadLocalUsage: false)
        let previewProfile = store.config?.profiles.first
        let showsEnrollment = CommandLine.arguments.contains("--preview-enrollment")
        let showsActions = CommandLine.arguments.contains("--preview-actions")
            || CommandLine.arguments.contains("--preview-delete-confirmation")
        let confirmsDeletion = CommandLine.arguments.contains("--preview-delete-confirmation")
        let controller = NSHostingController(rootView: MenuContentView(
            store: store,
            showsEnrollment: showsEnrollment,
            expandedActionsProfile: showsActions ? previewProfile : nil,
            confirmingDeletionProfile: confirmsDeletion ? previewProfile : nil))
        let window = NSWindow(contentViewController: controller)
        window.title = "CodexRelay 菜单预览"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        previewStore = store
        previewWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.terminationHandler?()
        Self.terminationHandler = nil
        RelaySupervisor.shared.stop()
    }
}

@main
struct CodexRelayMenuApp: App {
    static let previewMode = CommandLine.arguments.contains("--preview-menu")

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: RelayMenuStore

    init() {
        let store = RelayMenuStore(startSupervisor: !Self.previewMode)
        _store = StateObject(wrappedValue: store)
        AppDelegate.terminationHandler = { [weak store] in store?.shutdown() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            WatchdogLogo(size: 18, showsBackground: false)
                .opacity(store.isWorkerRunning ? 1 : 0.45)
        }
        .menuBarExtraStyle(.window)
    }
}
