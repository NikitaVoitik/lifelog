// Menu-bar shell: status item (left click → panel, right click → quick menu), Settings and Welcome windows.

import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    lazy var db = DB(path: rootDir.appendingPathComponent("lifelog.db").path)
    lazy var model = AppModel(recorder: Recorder(db: db))
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var settingsWindow: NSWindow?
    var settingsTabs: NSTabViewController?
    var welcomeWindow: NSWindow?
    var bag = Set<AnyCancellable>()
    let noPrompt = CommandLine.arguments.contains("--no-prompt")

    func applicationDidFinishLaunching(_ note: Notification) {
        ensureDir(rootDir)
        NSApp.mainMenu = makeMainMenu()
        model.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        model.$iconName.removeDuplicates().sink { [weak self] name in
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Lifelog")
            img?.isTemplate = true
            self?.statusItem.button?.image = img
        }.store(in: &bag)

        let host = NSHostingController(rootView: PopoverView(model: model, openSettings: { [weak self] t in self?.openSettings(t) },
                                                             quit: { NSApp.terminate(nil) }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if !noPrompt && (!model.missingPermissions.isEmpty || !UserDefaults.standard.bool(forKey: "welcomed")) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openWelcome() }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        model.recorder.shutdown()
    }

    // reopening the app from Finder/Spotlight while it runs → show the panel
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    // MARK: status item

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showQuickMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        model.visible = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) { model.visible = false }

    func showQuickMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ key: String = "", _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runBlock(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        let r = model.recorder
        if r.paused {
            add("Resume Recording") { [weak self] in self?.model.resume() }
        } else {
            add("Pause for 15 Minutes") { [weak self] in self?.model.pause(minutes: 15) }
            add("Pause for 1 Hour") { [weak self] in self?.model.pause(minutes: 60) }
            add("Pause Until I Resume") { [weak self] in self?.model.pause(minutes: nil) }
        }
        menu.addItem(.separator())
        add("Open Today's Timeline") { [weak self] in self?.model.openTimeline() }
        add("Update Timeline Now") { [weak self] in self?.model.runProcess() }
        if model.cloudConfigured { add("Sync to Cloud Now") { [weak self] in self?.model.runSync() } }
        menu.addItem(.separator())
        add("Settings…", ",") { [weak self] in self?.openSettings(.general) }
        add("Quit Lifelog", "q") { NSApp.terminate(nil) }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func runBlock(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }

    /// only visible while a window is open, but it's what makes ⌘C/⌘V/⌘W/⌘Q work in Settings
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Lifelog", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Lifelog", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Lifelog", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.windowsMenu = win
        return main
    }

    @objc func openSettingsMenu() { openSettings(.general) }

    // MARK: windows

    func openSettings(_ tab: SettingsTab) {
        popover.performClose(nil)
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = [.allowUserInteraction]
            for t in SettingsTab.allCases {
                let vc = NSHostingController(rootView: t.view(model).frame(width: 580, height: t.height))
                vc.sizingOptions = [.preferredContentSize]
                let item = NSTabViewItem(viewController: vc)
                item.label = t.title
                item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
                tabs.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
            settingsTabs = tabs
        }
        settingsTabs?.selectedTabViewItemIndex = tab.rawValue
        model.refreshAll()
        present(settingsWindow!)
    }

    func openWelcome() {
        if welcomeWindow == nil {
            let host = NSHostingController(rootView: WelcomeView(model: model) { [weak self] in
                UserDefaults.standard.set(true, forKey: "welcomed")
                self?.welcomeWindow?.close()
            })
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            welcomeWindow = w
        }
        present(welcomeWindow!)
    }

    /// while a window is open we behave like a normal app (Dock icon, ⌘-Tab); back to menu-bar-only when closed
    func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let open = [self.settingsWindow, self.welcomeWindow].contains { $0?.isVisible == true }
            if !open { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
