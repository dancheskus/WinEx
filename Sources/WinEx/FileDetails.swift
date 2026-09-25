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
        var picture = Section(title: "Изображение", rows: [])
        if let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let megapixels = Double(width * height) / 1_000_000
            picture.rows.append(Row(label: "Размеры", value: "\(width) × \(height) пикселей"
                + (megapixels >= 0.95 ? String(format: " (%.1f Мп)", locale: .current, megapixels) : "")))
        }
        if let dpi = properties[kCGImagePropertyDPIWidth] as? Double {
            picture.rows.append(Row(label: "Разрешение", value: "\(Int(dpi.rounded())) точек на дюйм"))
        }
        if let depth = properties[kCGImagePropertyDepth] as? Int {
            picture.rows.append(Row(label: "Глубина цвета", value: "\(depth) бит на канал"))
        }
        if let model = properties[kCGImagePropertyColorModel] as? String {
            let profile = properties[kCGImagePropertyProfileName] as? String
            picture.rows.append(Row(label: "Цвет", value: model + (profile.map { " · \($0)" } ?? "")))
        }
        if let alpha = properties[kCGImagePropertyHasAlpha] as? Bool {
            picture.rows.append(Row(label: "Прозрачность", value: alpha ? "Есть" : "Нет"))
        }
        let frames = CGImageSourceGetCount(source)
        if frames > 1 { picture.rows.append(Row(label: "Кадров", value: "\(frames)")) }

        var camera = Section(title: "Съёмка", rows: [])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let date = exifDate(taken) {
            camera.rows.append(Row(label: "Дата съёмки", value: longDate(date)))
        }
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) {
            // "Canon Canon EOS R6" → "Canon EOS R6"
            let name = make.map { model.hasPrefix($0) ? model : "\($0) \(model)" } ?? model
            camera.rows.append(Row(label: "Камера", value: name))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String {
            camera.rows.append(Row(label: "Объектив", value: lens))
        }
        var exposure: [String] = []
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            exposure.append(time >= 1 ? String(format: "%.1f с", locale: .current, time) : "1/\(Int((1 / time).rounded())) с")
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "ƒ/%.1f", locale: .current, aperture)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if !exposure.isEmpty { camera.rows.append(Row(label: "Экспозиция", value: exposure.joined(separator: " · "))) }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
            camera.rows.append(Row(label: "Фокусное расстояние", value: String(format: "%.0f мм", locale: .current, focal)
                + (equivalent.map { " (\($0) мм экв.)" } ?? "")))
        }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int {
            camera.rows.append(Row(label: "Вспышка", value: flash & 1 == 1 ? "Сработала" : "Не сработала"))
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            let longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            camera.rows.append(Row(label: "Место", value: String(format: "%.5f, %.5f", latitude, longitude),
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
        var general = Section(title: "Запись", rows: [])
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
            general.rows.append(Row(label: "Длительность", value: clock(duration.seconds)))
        }
        if let metadata = try? await asset.load(.commonMetadata) {
            for (key, label) in [(AVMetadataKey.commonKeyTitle, "Название"), (.commonKeyArtist, "Исполнитель"),
                                 (.commonKeyAlbumName, "Альбом"), (.commonKeyCreationDate, "Дата")] {
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
                    var video = Section(title: "Видео", rows: [])
                    if let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                        let shown = size.applying(transform)
                        video.rows.append(Row(label: "Размер кадра", value: "\(Int(abs(shown.width))) × \(Int(abs(shown.height)))"))
                    }
                    if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                        video.rows.append(Row(label: "Частота кадров", value: String(format: rate.rounded() == rate ? "%.0f к/с" : "%.2f к/с", locale: .current, rate)))
                    }
                    if let codec = await codec(of: track) { video.rows.append(Row(label: "Кодек", value: codec)) }
                    if let bitrate = try? await track.load(.estimatedDataRate), bitrate > 0 {
                        video.rows.append(Row(label: "Битрейт", value: bitRate(Double(bitrate))))
                    }
                    if !video.rows.isEmpty { sections.append(video) }
                } else if type == .audio, !sections.contains(where: { $0.title == "Звук" }) {
                    var audio = Section(title: "Звук", rows: [])
                    if let codec = await codec(of: track) { audio.rows.append(Row(label: "Кодек", value: codec)) }
                    if let description = (try? await track.load(.formatDescriptions))?.first,
                       let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                        if basic.mSampleRate > 0 {
                            audio.rows.append(Row(label: "Частота", value: String(format: "%.1f кГц", locale: .current, basic.mSampleRate / 1000)))
                        }
                        let channels = Int(basic.mChannelsPerFrame)
                        if channels > 0 {
                            audio.rows.append(Row(label: "Каналы", value: channels == 1 ? "Моно" : channels == 2 ? "Стерео" : "\(channels)"))
                        }
                    }
                    if let bitrate = try? await track.load(.estimatedDataRate), bitrate > 0 {
                        audio.rows.append(Row(label: "Битрейт", value: bitRate(Double(bitrate))))
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
        bits >= 1_000_000 ? String(format: "%.1f Мбит/с", locale: .current, bits / 1_000_000) : String(format: "%.0f кбит/с", locale: .current, bits / 1000)
    }

    // MARK: Documents

    private static func pdf(_ url: URL) -> [Section] {
        guard let document = PDFDocument(url: url) else { return [] }
        var section = Section(title: "Документ", rows: [Row(label: "Страниц", value: "\(document.pageCount)")])
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            let mm = { (points: CGFloat) in Int((points / 72 * 25.4).rounded()) }
            section.rows.append(Row(label: "Размер страницы", value: "\(mm(box.width)) × \(mm(box.height)) мм" + paperName(mm(box.width), mm(box.height))))
        }
        let attributes = document.documentAttributes ?? [:]
        for (key, label) in [(PDFDocumentAttribute.titleAttribute, "Заголовок"), (.authorAttribute, "Автор"),
                             (.creatorAttribute, "Создано в"), (.producerAttribute, "Программа PDF")] {
            if let value = attributes[key] as? String, !value.isEmpty { section.rows.append(Row(label: label, value: value)) }
        }
        section.rows.append(Row(label: "Версия PDF", value: "\(document.majorVersion).\(document.minorVersion)"))
        if document.isEncrypted { section.rows.append(Row(label: "Защита", value: document.isLocked ? "Требуется пароль" : "Зашифрован")) }
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
        return [Section(title: "Текст", rows: [
            Row(label: "Строк", value: number(lines)),
            Row(label: "Слов", value: number(words)),
            Row(label: "Символов", value: number(text.count)),
            Row(label: "Кодировка", value: names[encoding] ?? String.localizedName(of: encoding)),
        ])]
    }

    // MARK: Programs

    private static func app(_ url: URL) -> [Section] {
        guard let bundle = Bundle(url: url) else { return [] }
        let info = bundle.infoDictionary ?? [:]
        var section = Section(title: "Программа", rows: [])
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        if let version {
            section.rows.append(Row(label: "Версия", value: version + (build.map { $0 != version ? " (\($0))" : "" } ?? "")))
        }
        if let identifier = bundle.bundleIdentifier { section.rows.append(Row(label: "Идентификатор", value: identifier)) }
        if let architectures = bundle.executableArchitectures?.map(\.intValue) {
            let names = architectures.compactMap { [NSBundleExecutableArchitectureARM64: "Apple Silicon", NSBundleExecutableArchitectureX86_64: "Intel"][$0] }
            if !names.isEmpty { section.rows.append(Row(label: "Процессоры", value: names.joined(separator: ", "))) }
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            section.rows.append(Row(label: "Нужна macOS", value: minimum + " или новее"))
        }
        if let copyright = info["NSHumanReadableCopyright"] as? String, !copyright.isEmpty {
            section.rows.append(Row(label: "Авторские права", value: copyright))
        }
        return section.rows.isEmpty ? [] : [section]
    }

    // MARK: Downloads

    /// "Откуда": the page a download came from (Safari, Chrome and others record it).
    private static func whereFrom(_ url: URL) -> Section? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let sources = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String], !sources.isEmpty else { return nil }
        var section = Section(title: "Загрузка", rows: [])
        for (index, source) in sources.prefix(2).enumerated() {
            section.rows.append(Row(label: index == 0 ? "Откуда" : "Страница", value: source, link: URL(string: source)))
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
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
