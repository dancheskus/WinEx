import AppKit

/// The first-launch assistant: language, access to files, WinEx instead of Finder, keys, look,
/// startup. Each step can be skipped; everything can be changed later in Settings. Shown once
/// (again after "По умолчанию…", or from the menu: "Мастер настройки…").
@MainActor
final class SetupWizard: NSWindowController, NSWindowDelegate {
    private static var current: SetupWizard?
    private static let doneKey = "setupDone"
    private static let resumeKey = "setupWizardStep"

    // MARK: When

    /// Someone who used WinEx before the assistant existed shouldn't meet it after an update.
    static func markExistingUser() {
        let store = AppDefaults.store
        guard store.object(forKey: doneKey) == nil else { return }
        let used = ["sidebarWidth", "lastWindowPlacement", "viewModeDefaults2", "desktopLayout", "replaceFinder"]
        if used.contains(where: { store.object(forKey: $0) != nil }) { store.set(true, forKey: doneKey) }
    }

    static var shouldShow: Bool {
        #if DEBUG
        if Scenario.isRequested { return false }  // the "wizard" scenario opens it itself
        #endif
        return AppDefaults.store.object(forKey: resumeKey) != nil || !AppDefaults.store.bool(forKey: doneKey)
    }

    static func show() {
        if let current { current.window?.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let step = AppDefaults.store.object(forKey: resumeKey) as? Int ?? 0
        AppDefaults.store.removeObject(forKey: resumeKey)
        let wizard = SetupWizard(step: step)
        current = wizard
        NSApp.activate()
        wizard.showWindow(nil)
        wizard.window?.center()
        wizard.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Steps

    private enum Step: Int, CaseIterable { case welcome, language, access, finder, keys, look, startup, done }

    private var step: Step
    private let stage = NSView()
    private var page: NSView?
    private let dots = WizardDots()
    private let backButton = NSButton(title: L("Назад"), target: nil, action: nil)
    private let skipButton = NSButton(title: L("Пропустить"), target: nil, action: nil)
    private let nextButton = NSButton(title: L("Далее"), target: nil, action: nil)
    private let observers = Observers()

    // Choices (start from the current settings)
    private var language = Localization.chosen
    private var replaceFinder = Settings.replaceFinder
    private var windowsKeys = Settings.windowsKeys
    private var hotKey = GlobalHotKey.preset
    private var viewMode = ViewMode.saved
    private var commandBar = Settings.showCommandBar
    private var showHidden = Settings.showHidden
    private var openAtLogin = LoginItem.isEnabled
    private var checkUpdates = Updater.automaticChecks
    private var startFolder = Settings.startFolder
    private var accessStatus: NSTextField?
    private var accessIcon: NSImageView?

    static let size = NSSize(width: 680, height: 600)

    private init(step: Int) {
        self.step = Step(rawValue: step) ?? .welcome
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = L("Мастер настройки WinEx")
        let toolbar = NSToolbar(identifier: "WinExSetup")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        build()
        show(self.step, direction: 0)
        // Back from System Settings: the access step shows whether it was granted
        observers.add(NSApplication.didBecomeActiveNotification) { [weak self] in self?.updateAccess() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        window.contentView = background

        stage.wantsLayer = true
        stage.layer?.masksToBounds = true
        for button in [backButton, skipButton, nextButton] {
            button.controlSize = .large
            button.target = self
        }
        backButton.action = #selector(goBack(_:))
        skipButton.action = #selector(skip(_:))
        nextButton.action = #selector(goNext(_:))
        nextButton.keyEquivalent = "\r"
        nextButton.bezelColor = .controlAccentColor
        skipButton.isBordered = false
        skipButton.contentTintColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [backButton, spacer, skipButton, nextButton])
        bar.spacing = 10
        for view in [stage, dots, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            dots.topAnchor.constraint(equalTo: background.topAnchor, constant: 22),
            dots.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stage.topAnchor.constraint(equalTo: background.topAnchor, constant: 60),
            stage.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -16),
            bar.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 32),
            bar.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -32),
            bar.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -26),
            background.widthAnchor.constraint(equalToConstant: Self.size.width),
            background.heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        dots.count = Step.allCases.count
    }

    // MARK: Moving between steps

    /// Slides the new page in from the side it comes from (1: from the right), the old one out.
    private func show(_ newStep: Step, direction: CGFloat) {
        step = newStep
        dots.current = newStep.rawValue
        backButton.isHidden = newStep == .welcome || newStep == .done
        skipButton.isHidden = newStep == .welcome || newStep == .done
        nextButton.title = newStep == .welcome ? L("Начать") : newStep == .done ? L("Открыть WinEx") : L("Далее")
        window?.layoutIfNeeded()
        let new = makePage(newStep)
        new.frame = stage.bounds
        new.autoresizingMask = [.width, .height]
        new.wantsLayer = true
        stage.addSubview(new)
        let old = page
        page = new
        guard direction != 0, let newLayer = new.layer else { return }
        // Core Animation on the layers (layout stays put): the new page slides in and fades in,
        // the old one slides out the other way and fades out
        let shift = stage.bounds.width * 0.3
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        func animate(_ layer: CALayer, from: CGFloat, to: CGFloat, opacity: (Float, Float)) {
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = from
            move.toValue = to
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity.0
            fade.toValue = opacity.1
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 0.38
            group.timingFunction = curve
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "slide")
        }
        animate(newLayer, from: direction * shift, to: 0, opacity: (0, 1))
        if let old {
            old.wantsLayer = true
            if let oldLayer = old.layer { animate(oldLayer, from: 0, to: -direction * shift, opacity: (1, 0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { old.removeFromSuperview() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { newLayer.removeAnimation(forKey: "slide") }
    }

    @objc private func goNext(_ sender: Any?) {
        apply(step)
        if step == .done { return finish() }
        // A new language: WinEx restarts and the assistant goes on from the next step
        if step == .language, Localization.needsRestart {
            AppDefaults.store.set(Step.access.rawValue, forKey: Self.resumeKey)
            AppDelegate.shared.restartKeepingWindows(settingsOpen: false)
            return
        }
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        show(next, direction: 1)
    }

    @objc private func skip(_ sender: Any?) {
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        show(next, direction: 1)
    }

    @objc private func goBack(_ sender: Any?) {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        show(previous, direction: -1)
    }

    private func finish() {
        AppDefaults.store.set(true, forKey: Self.doneKey)
        window?.close()
        if !AppDelegate.shared.windowControllers.contains(where: { $0.window?.isVisible == true }) {
            AppDelegate.shared.openWindow(at: Settings.startURL)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closed with the red button: done too (it can be run again from the menu)
        AppDefaults.store.set(true, forKey: Self.doneKey)
        Self.current = nil
    }

    /// The choices of `step` take effect.
    private func apply(_ step: Step) {
        switch step {
        case .language:
            Localization.chosen = language
        case .finder:
            if replaceFinder != Settings.replaceFinder { AppDelegate.shared.setReplaceFinder(replaceFinder) }
        case .keys:
            Settings.windowsKeys = windowsKeys
            NotificationCenter.default.post(name: .keyboardSettingsChanged, object: nil)
            GlobalHotKey.preset = hotKey
            GlobalHotKey.shared.apply()
        case .look:
            ViewMode.applyToAllFolders(viewMode)
            Settings.showCommandBar = commandBar
            NotificationCenter.default.post(name: .commandBarSettingChanged, object: nil)
            if showHidden != Settings.showHidden { AppDelegate.shared.setShowHidden(showHidden) }
        case .startup:
            if openAtLogin != LoginItem.isEnabled { try? LoginItem.set(openAtLogin) }
            Updater.automaticChecks = checkUpdates
            Updater.shared.startAutomaticChecks()
            Settings.startFolder = startFolder
        case .welcome, .access, .done:
            break
        }
    }

    // MARK: Pages

    private func makePage(_ step: Step) -> NSView {
        switch step {
        case .welcome:
            return WizardPage(symbol: "folder.fill", colors: [.systemBlue, .systemIndigo], title: L("Добро пожаловать в WinEx"),
                              text: L("Проводник в стиле Windows для macOS. Настроим главное за минуту — всё это можно поменять потом в настройках."), content: [
                WizardPage.feature("rectangle.stack", L("Вкладки, адресная строка и панель команд, как в Windows 11")),
                WizardPage.feature("desktopcomputer", L("Свой рабочий стол и режим «вместо Finder»")),
                WizardPage.feature("keyboard", L("Клавиши Windows и вызов окна из любой программы")),
            ])
        case .language:
            let group = WizardChoiceGroup(options: Localization.Language.allCases.map { language in
                (symbol: language == .system ? "globe" : "character.bubble", title: language.title,
                 detail: language == .system ? L("Русский, если macOS на русском, иначе английский") : nil)
            }, selected: Localization.Language.allCases.firstIndex(of: language) ?? 0) { [weak self] in
                self?.language = Localization.Language.allCases[$0]
            }
            return WizardPage(symbol: "globe", colors: [.systemTeal, .systemBlue], title: L("Язык"),
                              text: L("Если язык сменится, WinEx перезапустится и продолжит с этого места."), content: [group])
        case .access:
            let icon = NSImageView()
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 14, weight: .semibold)
            accessIcon = icon
            accessStatus = status
            let row = NSStackView(views: [icon, status])
            row.spacing = 8
            // A stack in a centred column spreads its views out: keep this row as narrow as its content
            row.distribution = .fill
            row.setHuggingPriority(.required, for: .horizontal)
            let centred = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            centred.addSubview(row)
            NSLayoutConstraint.activate([
                row.centerXAnchor.constraint(equalTo: centred.centerXAnchor),
                row.topAnchor.constraint(equalTo: centred.topAnchor),
                row.bottomAnchor.constraint(equalTo: centred.bottomAnchor),
                centred.widthAnchor.constraint(equalToConstant: 520),
            ])
            let open = NSButton(title: L("Открыть настройки «Полный доступ к диску»…"), target: self, action: #selector(openAccess(_:)))
            open.controlSize = .large
            let steps = WizardPage.note(L("Включите WinEx в списке. Если его там нет — перетащите значок ниже прямо в список (или нажмите «+» и выберите WinEx). Если macOS предложит «Закрыть и открыть снова» — согласитесь: мастер продолжит с этого шага."))
            updateAccess()
            return WizardPage(symbol: "lock.shield.fill", colors: [.systemGreen, .systemTeal], title: L("Доступ к файлам"),
                              text: L("С «Полным доступом к диску» открывается Корзина, а macOS не спрашивает отдельно про Рабочий стол, Документы, Загрузки и каждый сетевой диск."),
                              content: [centred, open, WizardAppDrag(), steps])
        case .finder:
            let group = WizardChoiceGroup(options: [
                ("macwindow", L("Только окна"), L("Finder остаётся; WinEx — обычная программа со своими окнами.")),
                ("menubar.dock.rectangle", L("Окна и рабочий стол"), L("Рабочий стол рисует WinEx, «Показать в Finder» в других программах открывает WinEx. Значки встанут как у Finder.")),
            ], selected: replaceFinder ? 1 : 0) { [weak self] in self?.replaceFinder = $0 == 1 }
            return WizardPage(symbol: "arrow.triangle.swap", colors: [.systemOrange, .systemPink], title: L("WinEx вместо Finder?"),
                              text: L("«Выйти» в строке меню всегда возвращает всё Finder."), content: [group])
        case .keys:
            let keys = WizardChoiceGroup(options: [
                ("apple.logo", L("Как в Finder"), L("Enter — переименовать, ⌘↓ — открыть, ⌘↑ — наверх")),
                ("keyboard", L("Как в Windows"), L("Enter — открыть, F2 — переименовать, Backspace — наверх, Delete — в Корзину")),
            ], selected: windowsKeys ? 1 : 0) { [weak self] in self?.windowsKeys = $0 == 1 }
            let presets = GlobalHotKey.Preset.allCases
            let hotKeyRow = WizardPage.popupRow(L("Окно WinEx из любой программы (как Win+E):"), presets.map(\.title),
                                                selected: presets.firstIndex(of: hotKey) ?? 0) { [weak self] in self?.hotKey = presets[$0] }
            return WizardPage(symbol: "keyboard.fill", colors: [.systemPurple, .systemIndigo], title: L("Клавиши"),
                              text: nil, content: [keys, hotKeyRow])
        case .look:
            let modes: [ViewMode] = [.mediumIcons, .list, .details]
            let group = WizardChoiceGroup(options: [
                (ViewMode.mediumIcons.symbol, ViewMode.mediumIcons.title, nil),
                (ViewMode.list.symbol, ViewMode.list.title, nil),
                (ViewMode.details.symbol, ViewMode.details.title, nil),
            ], selected: modes.firstIndex(of: viewMode) ?? 0, horizontal: true) { [weak self] in self?.viewMode = modes[$0] }
            return WizardPage(symbol: "square.grid.2x2.fill", colors: [.systemIndigo, .systemBlue], title: L("Вид папок"),
                              text: L("Вид запоминается для каждой папки; это — вид по умолчанию."), content: [
                group,
                WizardToggle(L("Панель команд под адресной строкой"), L("Создать, вырезать, копировать, сортировать, вид…"), on: commandBar) { [weak self] in self?.commandBar = $0 },
                WizardToggle(L("Показывать скрытые файлы"), nil, on: showHidden) { [weak self] in self?.showHidden = $0 },
            ])
        case .startup:
            let folders = [("home", L("Домашняя папка")), ("desktop", L("Рабочий стол")), ("downloads", L("Загрузки")), ("documents", L("Документы"))]
            let folderRow = WizardPage.popupRow(L("Новые окна открываются в:"), folders.map(\.1),
                                                selected: folders.firstIndex { $0.0 == startFolder } ?? 0) { [weak self] in self?.startFolder = folders[$0].0 }
            if replaceFinder && !LoginItem.isEnabled { openAtLogin = true }
            return WizardPage(symbol: "power", colors: [.systemRed, .systemOrange], title: L("Запуск"), text: nil, content: [
                WizardToggle(L("Открывать WinEx при входе в систему"),
                             replaceFinder ? L("Нужно для рабочего стола WinEx после перезагрузки") : L("Без окна: значок в строке меню"),
                             on: openAtLogin) { [weak self] in self?.openAtLogin = $0 },
                WizardToggle(L("Проверять обновления автоматически"), L("Раз в сутки; разрешения сохраняются"), on: checkUpdates) { [weak self] in self?.checkUpdates = $0 },
                folderRow,
            ])
        case .done:
            return WizardPage(symbol: "checkmark", colors: [.systemGreen, .systemMint], title: L("Готово!"),
                              text: L("Всё можно поменять в «Настройки» (⌘,). Мастер можно пройти снова оттуда же."), content: [
                WizardPage.feature("sidebar.left", L("Перетащите папку в «Избранное», чтобы закрепить")),
                WizardPage.feature("cursorarrow.click.2", L("Правый щелчок — меню в стиле Windows 11")),
                WizardPage.feature("tag", L("Теги, программы и боковое меню — в настройках")),
            ])
        }
    }

    private func updateAccess() {
        guard let accessStatus, let accessIcon else { return }
        let granted = (try? FileManager.default.contentsOfDirectory(atPath: Places.trashURL.path)) != nil
        accessIcon.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        accessIcon.contentTintColor = granted ? .systemGreen : .systemOrange
        accessStatus.stringValue = granted ? L("Доступ выдан") : L("Доступ ещё не выдан")
    }

    @objc private func openAccess(_ sender: Any?) {
        AppDefaults.store.set(Step.access.rawValue, forKey: Self.resumeKey)  // if macOS restarts WinEx
        // Knock on protected places first: macOS then lists WinEx under Full Disk Access (switched off)
        for path in [Places.trashURL.path, NSHomeDirectory() + "/Library/Safari", NSHomeDirectory() + "/Library/Mail"] {
            _ = try? FileManager.default.contentsOfDirectory(atPath: path)
        }
        Places.openFullDiskAccessSettings()
    }
}

// MARK: - Building blocks

/// A page: a coloured tile with a symbol, a title, a line of text, then its controls.
private final class WizardPage: NSView {
    init(symbol: String, colors: [NSColor], title: String, text: String?, content: [NSView]) {
        super.init(frame: .zero)
        let tile = WizardTile(symbol: symbol, colors: colors)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        heading.alignment = .center
        var views: [NSView] = [tile, heading]
        if let text {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 14)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.preferredMaxLayoutWidth = 520
            views.append(label)
        }
        let body = NSStackView(views: content)
        body.orientation = .vertical
        body.alignment = .centerX
        body.spacing = 10
        views.append(body)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: tile)
        stack.setCustomSpacing(24, after: views[views.count - 2])
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
        ])
        for view in content { view.widthAnchor.constraint(lessThanOrEqualToConstant: 560).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    static func feature(_ symbol: String, _ text: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium)) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        let row = NSStackView(views: [icon, label])
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: 470).isActive = true
        return row
    }

    static func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = 480
        return label
    }

    static func popupRow(_ title: String, _ items: [String], selected: Int, onChange: @escaping (Int) -> Void) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        let popup = ClosurePopUp(items: items, selected: selected, onChange: onChange)
        let row = NSStackView(views: [label, popup])
        row.spacing = 10
        return row
    }
}

private final class ClosurePopUp: NSPopUpButton {
    private var onChange: ((Int) -> Void)?

    convenience init(items: [String], selected: Int, onChange: @escaping (Int) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items)
        selectItem(at: selected)
        self.onChange = onChange
        target = self
        action = #selector(changed(_:))
    }

    @objc private func changed(_ sender: Any?) { onChange?(indexOfSelectedItem) }
}

/// The step's symbol on a rounded tile with a gradient and a soft glow.
private final class WizardTile: NSView {
    private let symbol: String
    private let colors: [NSColor]

    init(symbol: String, colors: [NSColor]) {
        self.symbol = symbol
        self.colors = colors
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: 92).isActive = true
        heightAnchor.constraint(equalToConstant: 92).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = (colors.first ?? .controlAccentColor).withAlphaComponent(0.45)
        glow.shadowBlurRadius = 14
        glow.shadowOffset = NSSize(width: 0, height: -3)
        glow.set()
        (colors.first ?? .controlAccentColor).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: colors)?.draw(in: path, angle: -60)
        NSColor.white.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .semibold)) else { return }
        let size = image.size
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        let white = NSImage(size: size, flipped: false) { area in
            image.draw(in: area)
            NSColor.white.set()
            area.fill(using: .sourceAtop)
            return true
        }
        white.draw(in: target)
    }
}

/// Cards to pick one of; the chosen one is outlined in the accent colour.
private final class WizardChoiceGroup: NSStackView {
    private var cards: [WizardCard] = []
    private let onSelect: (Int) -> Void

    init(options: [(symbol: String, title: String, detail: String?)], selected: Int, horizontal: Bool = false, onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        orientation = horizontal ? .horizontal : .vertical
        spacing = 10
        distribution = horizontal ? .fillEqually : .fill
        for (index, option) in options.enumerated() {
            let card = WizardCard(symbol: option.symbol, title: option.title, detail: option.detail, compact: horizontal)
            card.isChosen = index == selected
            card.onClick = { [weak self] in self?.select(index) }
            addArrangedSubview(card)
            card.widthAnchor.constraint(equalToConstant: horizontal ? 170 : 520).isActive = true
            cards.append(card)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func select(_ index: Int) {
        for (i, card) in cards.enumerated() { card.isChosen = i == index }
        onSelect(index)
    }
}

private final class WizardCard: NSView {
    var onClick: (() -> Void)?
    var isChosen = false { didSet { animateLook() } }
    private var hovering = false { didSet { animateLook() } }
    private let check = NSImageView()

    init(symbol: String, title: String, detail: String?, compact: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1.5
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: compact ? 26 : 20, weight: .medium)) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        check.contentTintColor = .controlAccentColor
        var texts: [NSView] = [name]
        if let detail {
            let small = NSTextField(wrappingLabelWithString: detail)
            small.font = .systemFont(ofSize: 12)
            small.textColor = .secondaryLabelColor
            small.preferredMaxLayoutWidth = 390
            texts.append(small)
        }
        let textStack = NSStackView(views: texts)
        textStack.orientation = .vertical
        textStack.alignment = compact ? .centerX : .leading
        textStack.spacing = 3
        let content: NSStackView
        if compact {
            content = NSStackView(views: [icon, textStack])
            content.orientation = .vertical
            content.spacing = 8
        } else {
            icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            content = NSStackView(views: [icon, textStack, spacer, check])
            content.spacing = 14
            content.alignment = .centerY
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let inset: CGFloat = compact ? 16 : 14
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        if compact {
            addSubview(check)
            check.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                check.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ])
        }
        animateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private func animateLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            let fill = isChosen ? accent.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(hovering ? 0.09 : 0.05)
            let border = isChosen ? accent : NSColor.labelColor.withAlphaComponent(0.08)
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = border.cgColor
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            check.animator().alphaValue = isChosen ? 1 : 0
        }
    }
}

/// A switch on a card, with a title and a grey line under it.
private final class WizardToggle: NSView {
    private let onChange: (Bool) -> Void
    private let toggle = NSSwitch()

    init(_ title: String, _ detail: String?, on: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        var texts: [NSView] = [name]
        if let detail {
            let small = NSTextField(labelWithString: detail)
            small.font = .systemFont(ofSize: 12)
            small.textColor = .secondaryLabelColor
            texts.append(small)
        }
        let textStack = NSStackView(views: texts)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        toggle.state = on ? .on : .off
        toggle.target = self
        toggle.action = #selector(changed(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [textStack, spacer, toggle])
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            widthAnchor.constraint(equalToConstant: 520),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    @objc private func changed(_ sender: Any?) { onChange(toggle.state == .on) }
}

/// The steps as dots; the current one is a wider capsule (animated).
private final class WizardDots: NSView {
    var count = 0 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var current = 0 {
        didSet {
            let from = CGFloat(oldValue), to = CGFloat(current)
            let start = CACurrentMediaTime()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { return timer.invalidate() }
                    let t = min(1, (CACurrentMediaTime() - start) / 0.3)
                    let eased = 1 - pow(1 - t, 3)
                    self.position = from + (to - from) * eased
                    self.needsDisplay = true
                    if t >= 1 { timer.invalidate() }
                }
            }
        }
    }
    private var position: CGFloat = 0
    private var timer: Timer?
    private static let dot: CGFloat = 7, gap: CGFloat = 8, wide: CGFloat = 22

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(max(count - 1, 0)) * (Self.dot + Self.gap) + Self.wide, height: Self.dot)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for i in 0..<count {
            // How much this dot is the current one (0…1): it widens and takes the accent colour
            let weight = max(0, 1 - abs(CGFloat(i) - position))
            let width = Self.dot + (Self.wide - Self.dot) * weight
            let rect = NSRect(x: x, y: 0, width: width, height: Self.dot)
            NSColor.labelColor.withAlphaComponent(0.2).blended(withFraction: weight, of: .controlAccentColor)?.setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.dot / 2, yRadius: Self.dot / 2).fill()
            x += width + Self.gap
        }
    }
}

/// WinEx's icon and name to drag into System Settings' Full Disk Access list (when it's not there).
private final class WizardAppDrag: NSView, NSDraggingSource {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let name = NSTextField(labelWithString: "WinEx")
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        let hint = NSTextField(labelWithString: L("перетащите в список"))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [name, hint])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let hand = NSImageView(image: NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) ?? NSImage())
        hand.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, texts, hand])
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        toolTip = Bundle.main.bundleURL.path
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        let icon = NSApp.applicationIconImage ?? NSImage()
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
