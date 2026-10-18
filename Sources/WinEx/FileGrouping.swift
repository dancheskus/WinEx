import AppKit

/// «Группировать по» — files in groups with a heading each, like Finder's «Использовать группы»
/// and Explorer's «Группировка». Each folder's own (kept with its sorting, see `FileItem.SortOrder`).
enum FileGrouping {
    /// What files can be grouped by (`FileColumn` raw values), in the sort menu's order.
    static let keys: [FileColumn] = [.type, .opened, .added, .date, .created, .size, .tags]

    /// The group `item` falls in: groups come in `rank` order, then by `title`.
    struct Group: Equatable {
        var rank: Int
        var title: String
    }

    static func group(of item: FileItem, by key: String, now: Date = Date(), calendar: Calendar = .current) -> Group {
        switch key {
        case "type": return Group(rank: 0, title: item.typeDescription)
        case "date": return dateGroup(item.modified, now: now, calendar: calendar)
        case "created": return dateGroup(item.created, now: now, calendar: calendar)
        case "added": return dateGroup(item.added, now: now, calendar: calendar)
        case "opened": return dateGroup(item.lastOpened, now: now, calendar: calendar)
        case "tags":
            // By the first tag, as sorting by tags; untagged last
            return item.tags.first.map { Group(rank: 0, title: $0.name) } ?? Group(rank: 1, title: L("Без тегов"))
        case "size": return sizeGroup(item.isFolder ? nil : item.size ?? 0)
        default: return Group(rank: 0, title: "")
        }
    }

    /// Finder's date groups, newest first: today, yesterday, the last 7 and 30 days, the months
    /// of this year, then earlier years.
    static func dateGroup(_ date: Date?, now: Date, calendar: Calendar) -> Group {
        guard let date else { return Group(rank: Int.max, title: L("Неизвестно")) }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        if days <= 0 { return Group(rank: 0, title: L("Сегодня")) }
        if days == 1 { return Group(rank: 1, title: L("Вчера")) }
        if days < 7 { return Group(rank: 2, title: L("Предыдущие 7 дней")) }
        if days < 30 { return Group(rank: 3, title: L("Предыдущие 30 дней")) }
        let year = calendar.component(.year, from: date), month = calendar.component(.month, from: date)
        if year == calendar.component(.year, from: now) {
            let locale = Locale(identifier: Localization.isEnglish ? "en_US" : "ru_RU")
            let formatter = DateFormatter()
            formatter.locale = locale
            return Group(rank: 100 - month, title: formatter.standaloneMonthSymbols[month - 1].capitalized(with: locale))
        }
        return Group(rank: 10_000 - year, title: String(year))
    }

    /// Explorer's size groups, small to big; folders last.
    static func sizeGroup(_ size: Int?) -> Group {
        guard let size else { return Group(rank: 100, title: L("Папки")) }
        let kb = 1024, mb = 1024 * kb, gb = 1024 * mb
        let groups: [(limit: Int, title: String)] = [
            (0, L("Пустые")), (16 * kb, L("Крошечные (до 16 КБ)")), (mb, L("Маленькие (16 КБ – 1 МБ)")),
            (128 * mb, L("Средние (1 – 128 МБ)")), (gb, L("Большие (128 МБ – 1 ГБ)")), (4 * gb, L("Огромные (1 – 4 ГБ)")),
        ]
        for (rank, group) in groups.enumerated() where size <= group.limit { return Group(rank: rank, title: group.title) }
        return Group(rank: groups.count, title: L("Гигантские (больше 4 ГБ)"))
    }

    /// Whether `a`'s group comes before `b`'s (nil: the same group).
    static func precedes(_ a: Group, _ b: Group) -> Bool? {
        if a.rank != b.rank { return a.rank < b.rank }
        let titles = a.title.localizedStandardCompare(b.title)
        return titles == .orderedSame ? nil : titles == .orderedAscending
    }
}

/// Where the groups of a sorted list start, and the table rows / grid sections that follow:
/// a table has a heading row before each group, a grid a section per group. Item indexes stay
/// those of the flat list everywhere else.
struct FileGroups {
    /// Item index each group starts at, ascending (empty: not grouped).
    private(set) var starts: [Int] = []
    private(set) var titles: [String] = []
    private var count = 0

    var isGrouped: Bool { !starts.isEmpty }

    init() {}

    /// The groups of `items`, sorted by `key` already (see `FileItem.sort`).
    init(_ items: [FileItem], by key: String, now: Date = Date()) {
        count = items.count
        guard !key.isEmpty else { return }
        var last: FileGrouping.Group?
        for (index, item) in items.enumerated() {
            let group = FileGrouping.group(of: item, by: key, now: now)
            guard group != last else { continue }
            starts.append(index)
            titles.append(group.title)
            last = group
        }
    }

    // MARK: Table: a heading row before each group

    var rowCount: Int { count + starts.count }

    /// The row an item is shown in.
    func row(for index: Int) -> Int { index + groupIndex(of: index) + (isGrouped ? 1 : 0) }

    /// The item shown in `row` (nil for a heading or past the end).
    func index(forRow row: Int) -> Int? {
        guard row >= 0, row < rowCount else { return nil }
        guard isGrouped else { return row }
        // The heading of group g is at row starts[g] + g
        var group = 0
        while group + 1 < starts.count && starts[group + 1] + group + 1 <= row { group += 1 }
        let index = row - group - 1
        return index >= starts[group] ? index : nil
    }

    /// The heading shown in `row`, if it's one.
    func title(forRow row: Int) -> String? {
        guard let group = starts.indices.first(where: { starts[$0] + $0 == row }) else { return nil }
        return titles[group]
    }

    func rows(for indexes: IndexSet) -> IndexSet { IndexSet(indexes.map(row(for:))) }
    func indexes(forRows rows: IndexSet) -> IndexSet { IndexSet(rows.compactMap(index(forRow:))) }

    // MARK: Grid: a section per group

    var sectionCount: Int { max(starts.count, 1) }

    func itemCount(inSection section: Int) -> Int {
        guard isGrouped else { return count }
        return (section + 1 < starts.count ? starts[section + 1] : count) - starts[section]
    }

    func indexPath(for index: Int) -> IndexPath {
        guard isGrouped else { return IndexPath(item: index, section: 0) }
        let group = groupIndex(of: index)
        return IndexPath(item: index - starts[group], section: group)
    }

    func index(of path: IndexPath) -> Int {
        isGrouped && starts.indices.contains(path.section) ? starts[path.section] + path.item : path.item
    }

    /// The group `index` is in.
    private func groupIndex(of index: Int) -> Int {
        guard isGrouped else { return 0 }
        // The last start at or before `index` (binary search: large folders)
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// A group's heading, as in Finder: its name in bold over a hairline. A table's heading row and a
/// grid's section header.
final class GroupHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GroupHeader")
    static let height: CGFloat = 26

    private let label = NSTextField(labelWithString: "")
    private let line = NSBox()

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(line)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -3),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// A heading row of `tableView`, reused.
    @MainActor static func make(in tableView: NSTableView, title: String) -> GroupHeaderView {
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? GroupHeaderView ?? GroupHeaderView(frame: .zero)
        view.title = title
        return view
    }
}
