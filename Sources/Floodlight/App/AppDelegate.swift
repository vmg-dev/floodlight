import AppKit
import Carbon

private func floodlightHotKeyHandler(
    _: EventHandlerCallRef?,
    _: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.togglePanel()
    }
    return noErr
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = SearchCoordinator()
    private var panelController: FloodlightPanelController?
    private var onboardingController: OnboardingWindowController?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var activeShortcut: FloodlightShortcut?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panelController = FloodlightPanelController(model: model)
        model.onDismiss = { [weak self] in self?.panelController?.hide() }
        model.onShowSettings = { [weak self] in self?.showSettingsFromSearch() }
        installMenu()
        installStatusItem()
        installGlobalHotKey()
        model.enableLaunchAtLoginOnFirstRun()
        if OnboardingSession.shouldPresent() {
            showInitialSetup()
        } else {
            model.start()
            panelController?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if onboardingController?.window?.isVisible == true {
            onboardingController?.show()
            return true
        }
        panelController?.show()
        return true
    }

    @objc func togglePanel() {
        if onboardingController?.window?.isVisible == true {
            onboardingController?.show()
            return
        }
        panelController?.toggle()
    }

    @objc private func showPanel() {
        if onboardingController?.window?.isVisible == true {
            onboardingController?.show()
            return
        }
        panelController?.show()
    }

    private func showInitialSetup() {
        showConfiguration(
            presentation: .onboarding,
            showSearchOnFinish: true,
            showSearchOnDismiss: false
        )
    }

    @objc private func showSettings() {
        showConfiguration(
            presentation: .settings,
            showSearchOnFinish: false,
            showSearchOnDismiss: false
        )
    }

    @objc private func showSettingsFromSearch() {
        showConfiguration(
            presentation: .settings,
            showSearchOnFinish: true,
            showSearchOnDismiss: true
        )
    }

    private func showConfiguration(
        presentation: FloodlightConfigurationPresentation,
        showSearchOnFinish: Bool,
        showSearchOnDismiss: Bool
    ) {
        if let onboardingController, onboardingController.window?.isVisible == true {
            onboardingController.show()
            return
        }

        panelController?.hide()
        let controller = OnboardingWindowController(
            presentation: presentation,
            activeShortcut: activeShortcut ?? FloodlightShortcut.preferred(),
            launchesAtLogin: model.launchesAtLogin,
            rootURL: model.rootURL,
            selectShortcut: { [weak self] shortcut in
                self?.selectShortcut(shortcut) ?? false
            },
            setLaunchAtLogin: { [weak self] enabled in
                guard let self else { return "Floodlight is no longer running." }
                do {
                    try model.setLaunchAtLogin(enabled)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            chooseScope: { [weak self] in
                self?.model.chooseRoot()
            },
            onFinished: { [weak self] in
                self?.configurationClosed(showSearch: showSearchOnFinish)
            },
            onDismissed: { [weak self] in
                self?.configurationClosed(showSearch: showSearchOnDismiss)
            }
        )
        onboardingController = controller
        controller.show()
    }

    @objc private func chooseRoot() {
        panelController?.show()
        model.chooseRoot()
    }

    @objc private func rebuildIndex() {
        model.rebuildIndex()
    }

    @objc private func toggleLaunchAtLogin() {
        let wanted = !model.launchesAtLogin
        do {
            try model.setLaunchAtLogin(wanted)
        } catch {
            let alert = NSAlert()
            alert.messageText = wanted
                ? "Floodlight could not be added to Login Items."
                : "Floodlight could not be removed from Login Items."
            alert.informativeText = """
                \(error.localizedDescription)

                You can change this yourself in System Settings → General → \
                Login Items & Extensions.
                """
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func installGlobalHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            floodlightHotKeyHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )

        let preferred = FloodlightShortcut.preferred()
        if let registered = registerHotKey(preferred) {
            hotKeyRef = registered
            activeShortcut = preferred
        } else if let registered = registerHotKey(preferred.fallback) {
            hotKeyRef = registered
            activeShortcut = preferred.fallback
        } else {
            NSLog("Floodlight could not register its global keyboard shortcut.")
        }
    }

    private func selectShortcut(_ shortcut: FloodlightShortcut) -> Bool {
        guard shortcut != activeShortcut else {
            shortcut.save()
            return true
        }

        let previous = activeShortcut
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            activeShortcut = nil
        }

        if let registered = registerHotKey(shortcut) {
            hotKeyRef = registered
            activeShortcut = shortcut
            shortcut.save()
            return true
        }

        if let previous, let restored = registerHotKey(previous) {
            hotKeyRef = restored
            activeShortcut = previous
        }
        return false
    }

    private func registerHotKey(_ shortcut: FloodlightShortcut) -> EventHotKeyRef? {
        let identifier = EventHotKeyID(signature: fourCharacterCode("FLIT"), id: 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        return status == noErr ? reference : nil
    }

    private func configurationClosed(showSearch: Bool) {
        model.start()
        if showSearch {
            panelController?.show()
        }
        DispatchQueue.main.async { [weak self] in
            self?.onboardingController = nil
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = FloodlightMenuBarIcon.image()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Floodlight"
            button.setAccessibilityLabel("Floodlight")
        }
        statusItem = item
        let menu = makeStatusMenu()
        menu.delegate = self
        statusMenu = menu
        item.menu = menu
    }

    /// Floodlight is an `LSUIElement` agent, so it never shows an application
    /// menu bar. Without this menu, everything in `installMenu()` is reachable
    /// only by key equivalent — and Launch at Login has none.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let show = NSMenuItem(
            title: "Show Floodlight",
            action: #selector(showPanel),
            keyEquivalent: " "
        )
        show.keyEquivalentModifierMask = [.command]
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        let scope = NSMenuItem(
            title: "Choose Search Scope…",
            action: #selector(chooseRoot),
            keyEquivalent: "l"
        )
        scope.target = self
        menu.addItem(scope)

        let rebuild = NSMenuItem(
            title: "Rebuild Index",
            action: #selector(rebuildIndex),
            keyEquivalent: "r"
        )
        rebuild.keyEquivalentModifierMask = [.command, .shift]
        rebuild.target = self
        menu.addItem(rebuild)

        let launch = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        menu.addItem(launch)
        launchAtLoginItem = launch

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Floodlight",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        launchAtLoginItem?.state = model.launchesAtLogin ? .on : .off
    }

    /// This menu is never drawn — Floodlight is an agent app. It exists so the
    /// key equivalents below work while the panel is key. Anything a user has
    /// to click belongs in `makeStatusMenu()` instead.
    private func installMenu() {
        NSApp.mainMenu = makeMainMenu()
    }

    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Floodlight")

        let show = NSMenuItem(
            title: "Show Floodlight",
            action: #selector(showPanel),
            keyEquivalent: " "
        )
        show.keyEquivalentModifierMask = [.command]
        show.target = self
        appMenu.addItem(show)
        appMenu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsFromSearch),
            keyEquivalent: ","
        )
        settings.target = self
        appMenu.addItem(settings)

        let scope = NSMenuItem(
            title: "Choose Search Scope…",
            action: #selector(chooseRoot),
            keyEquivalent: "l"
        )
        scope.target = self
        appMenu.addItem(scope)

        let rebuild = NSMenuItem(
            title: "Rebuild Index",
            action: #selector(rebuildIndex),
            keyEquivalent: "r"
        )
        rebuild.keyEquivalentModifierMask = [.command, .shift]
        rebuild.target = self
        appMenu.addItem(rebuild)

        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Floodlight",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redo = editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        return mainMenu
    }

    private func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
