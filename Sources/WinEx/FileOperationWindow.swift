import AppKit

/// Copy / move / Trash / delete with Explorer-style windows: a progress window (percentage,
/// pause, cancel, speed graph, time and items remaining) that appears when the work takes more
/// than a moment, and a "Replace or skip files" dialog when names clash.
@MainActor
enum FileOperations {
    private static var running: [FileOperationWindowController] = []

    static func start(_ kind: FileOperation.Kind, _ urls: [URL], to destination: URL? = nil) {
        let urls = urls.filter { (try? $0.checkResourceIsReachable()) == true }
        guard !urls.isEmpty else { return }
        let operation = FileOperation(kind: kind, sources: urls, destination: destination)
        let controller = FileOperationWindowController(operation: operation)
        running.append(controller)

        operation.decideConflicts = { conflicts in
            waitForMain { answer in
                ConflictWindowController.ask(title: controller.headline, conflicts: conflicts, near: controller.window, answer: answer)
            }
        }
        operation.onError = { error, url in
            waitForMain { answer in
                let alert = NSAlert()
                alert.messageText = "Не удалось обработать «\(url.lastPathComponent)»"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Пропустить")
                alert.addButton(withTitle: "Отмена")
                answer(alert.runModal() == .alertFirstButtonReturn ? .skip : .cancel)
            }
        }
        operation.onFinish = { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    recordUndo(kind, result)
                    // Finder's sounds, once something was actually done
                    if !result.done.isEmpty {
                        switch kind {
                        case .copy: FileSounds.play(.copy)
                        case .move: FileSounds.play(.move)
                        case .trash: FileSounds.play(.trash)
                        case .delete: FileSounds.play(.delete)
                        }
                    }
                    controller.finish()
                    running.removeAll { $0 === controller }
                }
            }
        }
        controller.startShowingSoon()
        operation.start()
    }

    /// Runs `ask` on the main thread and blocks the calling (worker) thread until it answers.
    nonisolated private static func waitForMain<T: Sendable>(_ ask: @escaping @MainActor (@escaping (T) -> Void) -> Void) -> T {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ask { value in
                    box.value = value
                    done.signal()
                }
            }
        }
        done.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    /// One undo step for everything that got done (also when the rest was cancelled).
    private static func recordUndo(_ kind: FileOperation.Kind, _ result: FileOperation.Result) {
        switch kind {
        case .copy: FileUndo.recordCopy(result.done)
        case .move: FileUndo.recordMove(result.done)
        case .trash: FileUndo.recordTrash(Dictionary(result.done.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a }))
        case .delete: break
        }
    }

    /// "Копирование 3 элементов из [Загрузки] в [Temp]" — folder names are links.
    static func headline(_ kind: FileOperation.Kind, count: Int, from: URL?, to: URL?) -> [(text: String, link: URL?)] {
        let items = "\(count) \(plural(count, "элемента", "элементов", "элементов"))"
        var parts: [(String, URL?)]
        switch kind {
        case .copy: parts = [("Копирование \(items)", nil)]
        case .move: parts = [("Перемещение \(items)", nil)]
        case .trash: parts = [("Перемещение \(items)", nil)]
        case .delete: parts = [("Удаление \(items)", nil)]
        }
        if let from { parts += [(" из ", nil), (from.displayName, from)] }
        if kind == .trash { parts.append((" в Корзину", nil)) }
        if let to { parts += [(" в ", nil), (to.displayName, to)] }
        return parts
    }
}

// MARK: - Progress window

@MainActor
final class FileOperationWindowController: NSWindowController, NSWindowDelegate {
    private let operation: FileOperation
    private let percentLabel = NSTextField(labelWithString: "Подготовка…")
    private let pauseButton = NSButton()
    private let cancelButton = NSButton()
    private let graph = SpeedGraphView()
    private let nameValue = NSTextField(labelWithString: "")
    private let timeValue = NSTextField(labelWithString: "")
    private let itemsValue = NSTextField(labelWithString: "")
    private let details = NSStackView()
    private let detailsToggle = NSButton()
    private var timer: Timer?
    private var finished = false
    private var lastSample: (time: Date, bytes: Int64, items: Int)?
    private var speed: Double = 0  // bytes (or items) per second, smoothed

    let headline: [(text: String, link: URL?)]

    init(operation: FileOperation) {
        self.operation = operation
        let from = operation.sources.first?.deletingLastPathComponent()
        headline = FileOperations.headline(operation.kind, count: operation.sources.count, from: from, to: operation.destination)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = "Подготовка…"
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        let header = FileOperationUI.headlineView(headline)

        percentLabel.font = .systemFont(ofSize: 18)
        for (button, symbol, tip) in [(pauseButton, "pause.fill", "Приостановить"), (cancelButton, "xmark", "Отмена")] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.toolTip = tip
            button.target = self
        }
        pauseButton.action = #selector(togglePause(_:))
        cancelButton.action = #selector(cancelTransfer(_:))
        let titleRow = NSStackView(views: [percentLabel, NSView(), pauseButton, cancelButton])
        titleRow.spacing = 10

        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 96).isActive = true
        func row(_ title: String, _ value: NSTextField) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            value.lineBreakMode = .byTruncatingMiddle
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [label, value])
            row.spacing = 4
            return row
        }
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        for view in [graph, row("Имя:", nameValue), row("Осталось времени:", timeValue), row("Осталось элементов:", itemsValue)] {
            details.addArrangedSubview(view)
        }
        graph.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true

        detailsToggle.bezelStyle = .accessoryBarAction
        detailsToggle.isBordered = false
        detailsToggle.imagePosition = .imageLeading
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails(_:))
        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [header, titleRow, details, separator, detailsToggle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 12, right: 20)
        for view in [titleRow, details, separator] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        window.contentView = stack
        showDetails(UserDefaults.standard.object(forKey: "operationDetails") as? Bool ?? true)
    }

    // MARK: Showing

    /// Quick operations never show a window; it appears after half a second of work.
    func startShowingSoon() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !finished, operation.progress.phase != .waiting else {
                // Asking about conflicts: show the progress once the answer is in
                if let self, !self.finished { self.showWhenWorking() }
                return
            }
            show()
        }
    }

    private func showWhenWorking() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !finished else { return }
            if operation.progress.phase == .waiting { showWhenWorking() } else { show() }
        }
    }

    private func show() {
        guard let window, !window.isVisible else { return }
        fitToContent()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func finish() {
        finished = true
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
    }

    // MARK: Updates

    private func tick() {
        let progress = operation.progress
        let percent = Int(progress.fraction * 100)
        let title: String
        switch progress.phase {
        case .counting: title = "Подготовка…"
        case .waiting: title = "Ожидание ответа…"
        case .working, .finished: title = progress.paused ? "Приостановлено — \(percent)%" : "\(percent)% выполнено"
        }
        percentLabel.stringValue = title
        window?.title = title
        pauseButton.image = NSImage(systemSymbolName: progress.paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        pauseButton.toolTip = progress.paused ? "Продолжить" : "Приостановить"

        // Speed: smoothed over the last samples
        let now = Date()
        let amount = progress.byBytes ? Double(progress.doneBytes) : Double(progress.doneItems)
        if let last = lastSample, progress.phase == .working, !progress.paused {
            let elapsed = now.timeIntervalSince(last.time)
            let lastAmount = progress.byBytes ? Double(last.bytes) : Double(last.items)
            if elapsed > 0 {
                let current = max(0, amount - lastAmount) / elapsed
                speed = speed == 0 ? current : speed * 0.7 + current * 0.3
            }
            graph.add(fraction: progress.fraction, speed: progress.byBytes ? speed : 0)
        }
        lastSample = (now, progress.doneBytes, progress.doneItems)
        graph.fraction = progress.fraction
        graph.speedText = progress.byBytes && speed > 0
            ? "Скорость: \(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/с" : ""

        nameValue.stringValue = progress.currentName
        let remainingItems = max(0, progress.totalItems - progress.doneItems)
        let remainingBytes = max(0, progress.totalBytes - progress.doneBytes)
        itemsValue.stringValue = progress.byBytes
            ? "\(remainingItems) (\(ByteCountFormatter.string(fromByteCount: remainingBytes, countStyle: .file)))"
            : "\(remainingItems)"
        let left = progress.byBytes ? Double(remainingBytes) : Double(remainingItems)
        timeValue.stringValue = speed > 0 && progress.phase == .working && !progress.paused
            ? Self.duration(left / speed) : "Вычисление…"
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        formatter.calendar?.locale = Locale(identifier: "ru_RU")
        return "около " + (formatter.string(from: max(1, seconds.rounded())) ?? "")
    }

    // MARK: Actions

    @objc private func togglePause(_ sender: Any?) {
        if operation.progress.paused { operation.resume() } else { operation.pause() }
        tick()
    }

    @objc private func cancelTransfer(_ sender: Any?) {
        operation.cancel()
        percentLabel.stringValue = "Отмена…"
    }

    @objc private func toggleDetails(_ sender: Any?) {
        showDetails(details.isHidden)
    }

    private func showDetails(_ show: Bool) {
        details.isHidden = !show
        UserDefaults.standard.set(show, forKey: "operationDetails")
        detailsToggle.title = show ? "Меньше подробностей" : "Больше подробностей"
        detailsToggle.image = NSImage(systemSymbolName: show ? "chevron.up.circle" : "chevron.down.circle", accessibilityDescription: nil)
        fitToContent()
    }

    /// The window is as tall as what it shows (details or not); the top edge stays put.
    private func fitToContent() {
        guard let window, let content = window.contentView else { return }
        let top = window.frame.maxY
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 460, height: content.fittingSize.height))
        if window.isVisible { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top)) }
    }

    /// Closing the window cancels the operation, like in Explorer.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finished { return true }
        operation.cancel()
        return false
    }
}

/// Explorer's graph: the done part in light green, the speed over time as a dark green area.
final class SpeedGraphView: NSView {
    private var samples: [(fraction: Double, speed: Double)] = []
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var speedText = "" { didSet { needsDisplay = true } }

    func add(fraction: Double, speed: Double) {
        samples.append((fraction, speed))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        let green = NSColor(srgbRed: 0.02, green: 0.69, blue: 0.13, alpha: 1)

        // Done part
        green.withAlphaComponent(0.35).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height).fill()

        // Grid
        green.withAlphaComponent(0.25).setStroke()
        let grid = NSBezierPath()
        for i in 1..<10 { grid.move(to: NSPoint(x: rect.minX + rect.width * CGFloat(i) / 10, y: rect.minY)); grid.line(to: NSPoint(x: rect.minX + rect.width * CGFloat(i) / 10, y: rect.maxY)) }
        for i in 1..<4 { grid.move(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * CGFloat(i) / 4)); grid.line(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * CGFloat(i) / 4)) }
        grid.lineWidth = 0.5
        grid.stroke()

        // Speed over the progress
        let top = samples.map(\.speed).max() ?? 0
        if top > 0, samples.count > 1 {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: rect.minX + rect.width * samples[0].fraction, y: rect.minY))
            for sample in samples {
                area.line(to: NSPoint(x: rect.minX + rect.width * sample.fraction, y: rect.minY + rect.height * 0.8 * sample.speed / top))
            }
            area.line(to: NSPoint(x: rect.minX + rect.width * (samples.last?.fraction ?? 0), y: rect.minY))
            area.close()
            green.setFill()
            area.fill()
            // Current speed as a line across
            let y = rect.minY + rect.height * 0.8 * (samples.last?.speed ?? 0) / top
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: y))
            line.line(to: NSPoint(x: rect.maxX, y: y))
            line.lineWidth = 1
            line.stroke()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: rect).stroke()

        if !speedText.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
            let size = speedText.size(withAttributes: attributes)
            let textRect = NSRect(x: rect.maxX - size.width - 6, y: rect.minY + 3, width: size.width + 4, height: size.height)
            NSColor.textBackgroundColor.withAlphaComponent(0.8).setFill()
            textRect.insetBy(dx: -2, dy: 0).fill()
            speedText.draw(at: NSPoint(x: textRect.minX + 2, y: textRect.minY), withAttributes: attributes)
        }
    }
}

// MARK: - Replace or skip files

@MainActor
final class ConflictWindowController: NSWindowController, NSWindowDelegate {
    private let conflicts: [FileOperation.Conflict]
    private var answer: (([URL: FileOperation.Resolution]?) -> Void)?
    private let headline: [(text: String, link: URL?)]
    private var choices: [NSPopUpButton] = []
    private static var open: [ConflictWindowController] = []

    static func ask(title: [(text: String, link: URL?)], conflicts: [FileOperation.Conflict], near: NSWindow?,
                    answer: @escaping ([URL: FileOperation.Resolution]?) -> Void) {
        let controller = ConflictWindowController(headline: title, conflicts: conflicts)
        controller.answer = answer
        open.append(controller)
        controller.window?.layoutIfNeeded()
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private init(headline: [(text: String, link: URL?)], conflicts: [FileOperation.Conflict]) {
        self.headline = headline
        self.conflicts = conflicts
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 280), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.title = "Замена или пропуск файлов"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        showChoices()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var question: String {
        let n = conflicts.count
        return "В папке назначения уже есть \(n) \(plural(n, "элемент", "элемента", "элементов")) с \(n == 1 ? "таким же именем" : "такими же именами")"
    }

    /// The three big choices, like Explorer.
    private func showChoices() {
        let title = NSTextField(wrappingLabelWithString: question)
        title.font = .systemFont(ofSize: 16)
        let replace = ChoiceButton(symbol: "checkmark", title: "Заменить файлы в папке назначения", target: self, action: #selector(replaceAll(_:)))
        let skip = ChoiceButton(symbol: "arrow.uturn.backward", title: "Пропустить эти файлы", target: self, action: #selector(skipAll(_:)))
        let decide = ChoiceButton(symbol: "arrow.triangle.branch", title: "Решить для каждого файла", target: self, action: #selector(decideEach(_:)))
        replace.keyEquivalent = "\r"
        let names = NSTextField(wrappingLabelWithString: conflicts.prefix(8).map(\.source.lastPathComponent).joined(separator: ", ")
                                + (conflicts.count > 8 ? " и ещё \(conflicts.count - 8)" : ""))
        names.textColor = .secondaryLabelColor
        names.font = .systemFont(ofSize: 11)
        setContent([FileOperationUI.headlineView(headline), title, replace, skip, decide, names], widths: [title, replace, skip, decide, names])
    }

    /// One row per clashing item: what's being copied, what's there, and what to do.
    @objc private func decideEach(_ sender: Any?) {
        let title = NSTextField(wrappingLabelWithString: "Выберите, что сделать с каждым элементом")
        title.font = .systemFont(ofSize: 16)
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        choices = []
        for conflict in conflicts {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: conflict.source.path))
            icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
            let name = NSTextField(labelWithString: conflict.source.lastPathComponent)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.lineBreakMode = .byTruncatingMiddle
            let info = NSTextField(labelWithString: "Новый: \(Self.describe(conflict.source))\nВ папке: \(Self.describe(conflict.existing))")
            info.font = .systemFont(ofSize: 11)
            info.textColor = .secondaryLabelColor
            let text = NSStackView(views: [name, info])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ["Заменить", "Пропустить", "Оставить оба"])
            popup.selectItem(at: 1)
            choices.append(popup)
            let row = NSStackView(views: [icon, text, NSView(), popup])
            row.spacing = 8
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        list.leadingAnchor.constraint(equalTo: clip.leadingAnchor).isActive = true
        list.trailingAnchor.constraint(equalTo: clip.trailingAnchor).isActive = true
        list.topAnchor.constraint(equalTo: clip.topAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(300, CGFloat(conflicts.count) * 52)).isActive = true

        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelAll(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let go = NSButton(title: "Продолжить", target: self, action: #selector(applyEach(_:)))
        go.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, go])
        setContent([FileOperationUI.headlineView(headline), title, scroll, buttons], widths: [title, scroll, buttons])
    }

    private static func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        let size = values?.isDirectory == true
            ? "папка" : ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        let date = values?.contentModificationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? ""
        return "\(size), изменён \(date)"
    }

    private func setContent(_ views: [NSView], widths: [NSView]) {
        guard let window else { return }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)
        for view in widths { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 450).isActive = true
        let top = window.frame.maxY
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        if window.isVisible { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top)) }
    }

    @objc private func replaceAll(_ sender: Any?) { finish(conflicts, .replace) }
    @objc private func skipAll(_ sender: Any?) { finish(conflicts, .skip) }
    @objc private func cancelAll(_ sender: Any?) { reply(nil) }

    @objc private func applyEach(_ sender: Any?) {
        let resolutions: [FileOperation.Resolution] = [.replace, .skip, .keepBoth]
        var result: [URL: FileOperation.Resolution] = [:]
        for (conflict, popup) in zip(conflicts, choices) { result[conflict.source] = resolutions[max(0, popup.indexOfSelectedItem)] }
        reply(result)
    }

    private func finish(_ conflicts: [FileOperation.Conflict], _ resolution: FileOperation.Resolution) {
        reply(Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, resolution) }))
    }

    private func reply(_ result: [URL: FileOperation.Resolution]?) {
        let answer = self.answer
        self.answer = nil
        window?.orderOut(nil)
        Self.open.removeAll { $0 === self }
        answer?(result)
    }

    /// Closing the dialog cancels the operation.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        reply(nil)
        return false
    }
}

/// A big borderless choice with a symbol, highlighted under the mouse (Explorer's command links).
final class ChoiceButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(symbol: String, title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        contentTintColor = .controlAccentColor
        imagePosition = .imageLeading
        alignment = .left
        isBordered = false
        font = .systemFont(ofSize: 15)
        self.target = target
        self.action = action
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || keyEquivalent == "\r" {
            (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlAccentColor.withAlphaComponent(0.07)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let inset = NSRect(x: bounds.minX + 10, y: bounds.minY, width: bounds.width - 20, height: bounds.height)
        (cell as? NSButtonCell)?.drawInterior(withFrame: inset, in: self)
    }
}

@MainActor
enum FileOperationUI {
    /// "Копирование 3 элементов из [Загрузки] в [Temp]" with clickable folder names.
    static func headlineView(_ parts: [(text: String, link: URL?)]) -> NSView {
        let row = NSStackView()
        row.spacing = 0
        for part in parts {
            if let link = part.link {
                let button = LinkButton(title: part.text, url: link)
                row.addArrangedSubview(button)
            } else {
                row.addArrangedSubview(NSTextField(labelWithString: part.text))
            }
        }
        return row
    }
}

/// A folder name in link color; opens the folder in WinEx.
final class LinkButton: NSButton {
    private var url: URL?

    convenience init(title: String, url: URL) {
        self.init(frame: .zero)
        self.url = url
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        target = self
        action = #selector(openFolder(_:))
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func openFolder(_ sender: Any?) {
        if let url { MainActor.assumeIsolated { _ = AppDelegate.shared.openWindow(at: url) } }
    }
}
