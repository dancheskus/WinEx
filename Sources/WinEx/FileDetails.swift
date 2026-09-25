import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// "Свойства ▸ Подробно": what matters for the kind of file — like Explorer's Details tab and
/// what Finder's Get Info no longer shows (picture dimensions, camera settings, durations, codecs,
/// pages, app versions…). Gathered in the background.
enum FileDetails {
    struct Section: Sendable {
        let title: String
        var rows: [Row]
    }

    struct Row: Sendable {
        let label: String
        let value: String
        /// Opened on click (a map, a web page).
        var link: URL?
    }

    /// Everything known about `url`, as titled groups of rows (empty: nothing beyond the basics).
    static func sections(for url: URL) async -> [Section] {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        var sections: [Section] = []
        if let type {
            if type.conforms(to: .image) { sections += image(url) }
            if type.conforms(to: .audiovisualContent) { sections += await media(url) }
            if type.conforms(to: .pdf) { sections += pdf(url) }
            if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { sections += app(url) }
            if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) { sections += text(url) }
        }
        if let from = whereFrom(url) { sections.append(from) }
        return sections
    }

    // MARK: Pictures

    private static func image(_ url: URL) -> [Section] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [] }
        var picture = Section(title: L("Изображение"), rows: [])
        if let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let megapixels = Double(width * height) / 1_000_000
            picture.rows.append(Row(label: L("Размеры"), value: L("%@ × %@ пикселей", width, height)
                + (megapixels >= 0.95 ? String(format: L(" (%.1f Мп)"), locale: Localization.locale, megapixels) : "")))
        }
        if let dpi = properties[kCGImagePropertyDPIWidth] as? Double {
            picture.rows.append(Row(label: L("Разрешение"), value: L("%@ точек на дюйм", Int(dpi.rounded()))))
        }
        if let depth = properties[kCGImagePropertyDepth] as? Int {
            picture.rows.append(Row(label: L("Глубина цвета"), value: L("%@ бит на канал", depth)))
        }
        if let model = properties[kCGImagePropertyColorModel] as? String {
            let profile = properties[kCGImagePropertyProfileName] as? String
            picture.rows.append(Row(label: L("Цвет"), value: model + (profile.map { " · \($0)" } ?? "")))
        }
        if let alpha = properties[kCGImagePropertyHasAlpha] as? Bool {
            picture.rows.append(Row(label: L("Прозрачность"), value: alpha ? L("Есть") : L("Нет")))
        }
        let frames = CGImageSourceGetCount(source)
        if frames > 1 { picture.rows.append(Row(label: L("Кадров"), value: "\(frames)")) }

        var camera = Section(title: L("Съёмка"), rows: [])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let date = exifDate(taken) {
            camera.rows.append(Row(label: L("Дата съёмки"), value: longDate(date)))
        }
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) {
            // "Canon Canon EOS R6" → "Canon EOS R6"
            let name = make.map { model.hasPrefix($0) ? model : "\($0) \(model)" } ?? model
            camera.rows.append(Row(label: L("Камера"), value: name))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String {
            camera.rows.append(Row(label: L("Объектив"), value: lens))
        }
        var exposure: [String] = []
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            exposure.append(time >= 1 ? String(format: L("%.1f с"), locale: Localization.locale, time) : L("1/%@ с", Int((1 / time).rounded())))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "ƒ/%.1f", locale: Localization.locale, aperture)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if !exposure.isEmpty { camera.rows.append(Row(label: L("Экспозиция"), value: exposure.joined(separator: " · "))) }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
            camera.rows.append(Row(label: L("Фокусное расстояние"), value: String(format: L("%.0f мм"), locale: Localization.locale, focal)
                + (equivalent.map { L(" (%@ мм экв.)", $0) } ?? "")))
        }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int {
            camera.rows.append(Row(label: L("Вспышка"), value: flash & 1 == 1 ? L("Сработала") : L("Не сработала")))
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            let longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            camera.rows.append(Row(label: L("Место"), value: String(format: "%.5f, %.5f", latitude, longitude),
                                   link: URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=%D0%A4%D0%BE%D1%82%D0%BE")))
        }
        return [picture, camera].filter { !$0.rows.isEmpty }
    }

    private static func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    // MARK: Sound and video

    private static func media(_ url: URL) async -> [Section] {
        let asset = AVURLAsset(url: url)
        var sections: [Section] = []
        var general = Section(title: L("Запись"), rows: [])
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
            general.rows.append(Row(label: L("Длительность"), value: clock(duration.seconds)))
        }
        if let metadata = try? await asset.load(.commonMetadata) {
            for (key, label) in [(AVMetadataKey.commonKeyTitle, L("Название")), (.commonKeyArtist, L("Исполнитель")),
                                 (.commonKeyAlbumName, L("Альбом")), (.commonKeyCreationDate, L("Дата"))] {
                if let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first,
                   let value = try? await item.load(.stringValue), !value.isEmpty {
                    general.rows.append(Row(label: label, value: value))
                }
            }
        }
        if !general.rows.isEmpty { sections.append(general) }

        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                guard let type = Optional(track.mediaType) else { continue }
                if type == .video {
                    var video = Section(title: L("Видео"), rows: [])
                    if let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                        let shown = size.applying(transform)
                        video.rows.append(Row(label: L("Размер кадра"), value: "\(Int(abs(shown.width))) × \(Int(abs(shown.height)))"))
                    }
                    if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                        video.rows.append(Row(label: L("Частота кадров"), value: String(format: rate.rounded() == rate ? L("%.0f к/с") : L("%.2f к/с"), locale: Localization.locale, rate)))
                    }
                    if let codec = await codec(of: track) { video.rows.append(Row(label: L("Кодек"), value: codec)) }
                    if let bitrate = try? await track.load(.estimatedDataRate), bitrate > 0 {
                        video.rows.append(Row(label: L("Битрейт"), value: bitRate(Double(bitrate))))
                    }
                    if !video.rows.isEmpty { sections.append(video) }
                } else if type == .audio, !sections.contains(where: { $0.title == L("Звук") }) {
                    var audio = Section(title: L("Звук"), rows: [])
                    if let codec = await codec(of: track) { audio.rows.append(Row(label: L("Кодек"), value: codec)) }
                    if let description = (try? await track.load(.formatDescriptions))?.first,
                       let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                        if basic.mSampleRate > 0 {
                            audio.rows.append(Row(label: L("Частота"), value: String(format: L("%.1f кГц"), locale: Localization.locale, basic.mSampleRate / 1000)))
                        }
                        let channels = Int(basic.mChannelsPerFrame)
                        if channels > 0 {
                            audio.rows.append(Row(label: L("Каналы"), value: channels == 1 ? L("Моно") : channels == 2 ? L("Стерео") : "\(channels)"))
                        }
                    }
                    if let bitrate = try? await track.load(.estimatedDataRate), bitrate > 0 {
                        audio.rows.append(Row(label: L("Битрейт"), value: bitRate(Double(bitrate))))
                    }
                    if !audio.rows.isEmpty { sections.append(audio) }
                }
            }
        }
        return sections
    }

    /// "H.264", "HEVC", "AAC"… from the track's four-character code.
    private static func codec(of track: AVAssetTrack) async -> String? {
        guard let description = (try? await track.load(.formatDescriptions))?.first else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(description)
        let known: [FourCharCode: String] = [
            0x61766331: "H.264", 0x68766331: "HEVC", 0x68657631: "HEVC", 0x61763031: "AV1", 0x76703039: "VP9",
            0x6170636E: "ProRes 422", 0x61703468: "ProRes 4444", 0x6D703461: "AAC", 0x2E6D7033: "MP3",
            0x616C6163: "Apple Lossless", 0x6C70636D: "PCM", 0x664C6143: "FLAC", 0x4F707573: "Opus", 0x61632D33: "AC-3",
        ]
        if let name = known[code] { return name }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func bitRate(_ bits: Double) -> String {
        bits >= 1_000_000 ? String(format: L("%.1f Мбит/с"), locale: Localization.locale, bits / 1_000_000) : String(format: L("%.0f кбит/с"), locale: Localization.locale, bits / 1000)
    }

    // MARK: Documents

    private static func pdf(_ url: URL) -> [Section] {
        guard let document = PDFDocument(url: url) else { return [] }
        var section = Section(title: L("Документ"), rows: [Row(label: L("Страниц"), value: "\(document.pageCount)")])
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            let mm = { (points: CGFloat) in Int((points / 72 * 25.4).rounded()) }
            section.rows.append(Row(label: L("Размер страницы"), value: L("%@ × %@ мм", mm(box.width), mm(box.height)) + paperName(mm(box.width), mm(box.height))))
        }
        let attributes = document.documentAttributes ?? [:]
        for (key, label) in [(PDFDocumentAttribute.titleAttribute, L("Заголовок")), (.authorAttribute, L("Автор")),
                             (.creatorAttribute, L("Создано в")), (.producerAttribute, L("Программа PDF"))] {
            if let value = attributes[key] as? String, !value.isEmpty { section.rows.append(Row(label: label, value: value)) }
        }
        section.rows.append(Row(label: L("Версия PDF"), value: "\(document.majorVersion).\(document.minorVersion)"))
        if document.isEncrypted { section.rows.append(Row(label: L("Защита"), value: document.isLocked ? L("Требуется пароль") : L("Зашифрован"))) }
        return [section]
    }

    private static func paperName(_ width: Int, _ height: Int) -> String {
        let (short, long) = (min(width, height), max(width, height))
        let papers: [(String, Int, Int)] = [("A4", 210, 297), ("A3", 297, 420), ("A5", 148, 210), ("Letter", 216, 279), ("Legal", 216, 356)]
        return papers.first { abs($0.1 - short) <= 2 && abs($0.2 - long) <= 2 }.map { " (\($0.0))" } ?? ""
    }

    private static func text(_ url: URL) -> [Section] {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 20_000_000 else { return [] }
        var encoding = String.Encoding.utf8
        guard let text = try? String(contentsOf: url, usedEncoding: &encoding) else { return [] }
        var lines = 0, words = 0
        text.enumerateLines { _, _ in lines += 1 }
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let names: [String.Encoding: String] = [.utf8: "UTF-8", .utf16: "UTF-16", .windowsCP1251: "Windows-1251",
                                                .macOSRoman: "Mac Roman", .isoLatin1: "ISO Latin 1", .ascii: "ASCII"]
        let number = { (n: Int) in NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
        return [Section(title: L("Текст"), rows: [
            Row(label: L("Строк"), value: number(lines)),
            Row(label: L("Слов"), value: number(words)),
            Row(label: L("Символов"), value: number(text.count)),
            Row(label: L("Кодировка"), value: names[encoding] ?? String.localizedName(of: encoding)),
        ])]
    }

    // MARK: Programs

    private static func app(_ url: URL) -> [Section] {
        guard let bundle = Bundle(url: url) else { return [] }
        let info = bundle.infoDictionary ?? [:]
        var section = Section(title: L("Программа"), rows: [])
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        if let version {
            section.rows.append(Row(label: L("Версия"), value: version + (build.map { $0 != version ? " (\($0))" : "" } ?? "")))
        }
        if let identifier = bundle.bundleIdentifier { section.rows.append(Row(label: L("Идентификатор"), value: identifier)) }
        if let architectures = bundle.executableArchitectures?.map(\.intValue) {
            let names = architectures.compactMap { [NSBundleExecutableArchitectureARM64: "Apple Silicon", NSBundleExecutableArchitectureX86_64: "Intel"][$0] }
            if !names.isEmpty { section.rows.append(Row(label: L("Процессоры"), value: names.joined(separator: ", "))) }
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            section.rows.append(Row(label: L("Нужна macOS"), value: minimum + L(" или новее")))
        }
        if let copyright = info["NSHumanReadableCopyright"] as? String, !copyright.isEmpty {
            section.rows.append(Row(label: L("Авторские права"), value: copyright))
        }
        return section.rows.isEmpty ? [] : [section]
    }

    // MARK: Downloads

    /// "Откуда": the page a download came from (Safari, Chrome and others record it).
    private static func whereFrom(_ url: URL) -> Section? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let sources = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String], !sources.isEmpty else { return nil }
        var section = Section(title: L("Загрузка"), rows: [])
        for (index, source) in sources.prefix(2).enumerated() {
            section.rows.append(Row(label: index == 0 ? L("Откуда") : L("Страница"), value: source, link: URL(string: source)))
        }
        return section
    }

    // MARK: Checksums

    /// SHA-256 and MD5 in one pass over the file.
    static func checksums(of url: URL, cancelled: @escaping @Sendable () -> Bool) -> (sha256: String, md5: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            if cancelled() { return nil }
            sha.update(data: chunk)
            md5.update(data: chunk)
        }
        let hex = { (digest: any Digest) in digest.map { String(format: "%02x", $0) }.joined() }
        return (hex(sha.finalize()), hex(md5.finalize()))
    }

    static func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
