import AppKit

final class SettingsWindowController: NSWindowController {
    private let replaceCheckbox = NSButton(checkboxWithTitle: "Использовать WinEx вместо Finder", target: nil, action: nil)
    private let hiddenCheckbox = NSButton(checkboxWithTitle: "Показывать скрытые файлы", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Настройки WinEx"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        replaceCheckbox.target = self
        replaceCheckbox.action = #selector(toggleReplace(_:))
        hiddenCheckbox.target = self
        hiddenCheckbox.action = #selector(toggleHidden(_:))

        let explanation = NSTextField(wrappingLabelWithString: """
            • Рабочий стол рисует WinEx: папки с рабочего стола открываются в WinEx.
            • «Показать в Finder» в других приложениях показывает файл в WinEx.
            • Папки, которые другие приложения открывают напрямую, по-прежнему открываются в Finder — macOS не даёт сменить программу для папок.
            • При выходе из WinEx (строка меню → «Выйти») всё возвращается Finder.
            """)
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 420

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [replaceCheckbox, explanation, separator, hiddenCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: replaceCheckbox)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 480).isActive = true
        window.center()
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    func sync() {
        replaceCheckbox.state = Settings.replaceFinder ? .on : .off
        hiddenCheckbox.state = Settings.showHidden ? .on : .off
    }

    @objc private func toggleReplace(_ sender: NSButton) {
        AppDelegate.shared.setReplaceFinder(sender.state == .on)
    }

    @objc private func toggleHidden(_ sender: NSButton) {
        AppDelegate.shared.setShowHidden(sender.state == .on)
    }
}
