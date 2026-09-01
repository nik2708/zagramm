import Foundation

/// Менеджер для сохранения удалённых сообщений
/// Перехватывает сообщения перед удалением и архивирует их локально
public final class AntiDeleteManager {

    public static let shared = AntiDeleteManager()

    // MARK: - Settings

    private let defaults = UserDefaults.standard
    private let enabledKey = "antiDelete.enabled"
    private let archiveMediaKey = "antiDelete.archiveMedia"
    private let fetchMissingMediaKey = "antiDelete.fetchMissingMedia"
    private let deletedMessageTransparencyKey = "antiDelete.deletedMessageTransparency"
    private let deletedMarkKey = "antiDelete.deletedMarkText"

    /// Включено ли сохранение удалённых сообщений
    public var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Сохранять ли медиа-контент
    public var archiveMedia: Bool {
        get { defaults.bool(forKey: archiveMediaKey) }
        set { defaults.set(newValue, forKey: archiveMediaKey) }
    }

    /// Докачивать ли ещё не скачанное медиа удаляемого сообщения (как в AyuGram)
    public var fetchMissingMedia: Bool {
        get {
            if defaults.object(forKey: fetchMissingMediaKey) == nil {
                return true
            }
            return defaults.bool(forKey: fetchMissingMediaKey)
        }
        set { defaults.set(newValue, forKey: fetchMissingMediaKey) }
    }

    /// Минимальное значение прозрачности удалённого сообщения
    public static let minDeletedMessageTransparency: Double = 0.0

    /// Максимальное значение прозрачности удалённого сообщения
    public static let maxDeletedMessageTransparency: Double = 0.8

    /// Значение прозрачности удалённого сообщения по умолчанию
    public static let defaultDeletedMessageTransparency: Double = 0.45

    /// Прозрачность удалённых сообщений (0.0 = непрозрачно, 0.8 = максимально прозрачно)
    public var deletedMessageTransparency: Double {
        get {
            let value = defaults.object(forKey: deletedMessageTransparencyKey) as? NSNumber
            let resolvedValue = value?.doubleValue ?? Self.defaultDeletedMessageTransparency
            return max(Self.minDeletedMessageTransparency, min(Self.maxDeletedMessageTransparency, resolvedValue))
        }
        set {
            let clampedValue = max(Self.minDeletedMessageTransparency, min(Self.maxDeletedMessageTransparency, newValue))
            defaults.set(clampedValue, forKey: deletedMessageTransparencyKey)
        }
    }

    /// Альфа для отображения удалённых сообщений
    public var deletedMessageDisplayAlpha: Double {
        return 1.0 - self.deletedMessageTransparency
    }

    /// Настраиваемая метка удалённого сообщения (как в AyuGram "кастомные метки")
    public static let defaultDeletedMarkText = "🗑️"

    public var deletedMarkText: String {
        get {
            let value = defaults.string(forKey: deletedMarkKey) ?? Self.defaultDeletedMarkText
            return value.isEmpty ? Self.defaultDeletedMarkText : value
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? Self.defaultDeletedMarkText : trimmed, forKey: deletedMarkKey)
        }
    }

    // MARK: - SQLite storage

    private let storage: AntiDeleteStorage?
    private var deletedMessageIds: Set<String> = []
    private let deletedIdsLock = NSLock()

    /// Пометить сообщение как удалённое
    public func markAsDeleted(peerId: Int64, messageId: Int32) {
        let key = "\(peerId)_\(messageId)"
        deletedIdsLock.lock()
        deletedMessageIds.insert(key)
        deletedIdsLock.unlock()
        storage?.insertDeletedId(key: key)
    }

    /// Проверить, является ли сообщение удалённым
    public func isMessageDeleted(peerId: Int64, messageId: Int32) -> Bool {
        guard isEnabled else { return false }
        let key = "\(peerId)_\(messageId)"
        deletedIdsLock.lock()
        defer { deletedIdsLock.unlock() }
        return deletedMessageIds.contains(key)
    }

    /// Проверить, является ли сообщение удалённым (по тексту - legacy)
    public func isMessageDeleted(text: String) -> Bool {
        guard isEnabled else { return false }
        // Legacy: проверяем наличие префикса-метки для обратной совместимости
        return text.hasPrefix("\(deletedMarkText) ")
    }

    // MARK: - Legacy JSON migration

    private struct LegacyStorage: Codable {
        var archive: [ArchivedMessage] = []
        var deletedIds: [String] = []
    }

    /// Структура архивированного сообщения
    public struct ArchivedMessage: Codable {
        public let globalId: Int32
        public let peerId: Int64
        public let messageId: Int32
        public let timestamp: Int32
        public let deletedAt: Int32
        public let authorId: Int64?
        public let text: String
        public let forwardAuthorId: Int64?
        public let mediaDescription: String?
        public let mediaPath: String?
        public let mediaKind: String?

        public init(
            globalId: Int32,
            peerId: Int64,
            messageId: Int32,
            timestamp: Int32,
            deletedAt: Int32,
            authorId: Int64?,
            text: String,
            forwardAuthorId: Int64?,
            mediaDescription: String?,
            mediaPath: String? = nil,
            mediaKind: String? = nil
        ) {
            self.globalId = globalId
            self.peerId = peerId
            self.messageId = messageId
            self.timestamp = timestamp
            self.deletedAt = deletedAt
            self.authorId = authorId
            self.text = text
            self.forwardAuthorId = forwardAuthorId
            self.mediaDescription = mediaDescription
            self.mediaPath = mediaPath
            self.mediaKind = mediaKind
        }
    }

    /// Тип архивируемого медиа
    public enum ArchivedMediaKind: String {
        case photo
        case video
        case voice
        case videoMessage
        case sticker
        case animation
        case file

        var defaultFileExtension: String {
            switch self {
            case .photo: return "jpg"
            case .video, .videoMessage, .animation: return "mp4"
            case .voice: return "ogg"
            case .sticker: return "webp"
            case .file: return "bin"
            }
        }
    }

    private let mediaDirectory: URL

    private init() {
        // Set default values
        // Bisect build: anti-delete hook disabled by default (enable in Ghostgram settings
        // after confirming the app launches) to rule out the state-replay interception
        // as the cause of the startup black screen
        if defaults.object(forKey: enabledKey) == nil {
            defaults.set(false, forKey: enabledKey)
        }
        if defaults.object(forKey: archiveMediaKey) == nil {
            defaults.set(true, forKey: archiveMediaKey)
        }
        if defaults.object(forKey: deletedMessageTransparencyKey) == nil {
            defaults.set(Self.defaultDeletedMessageTransparency, forKey: deletedMessageTransparencyKey)
        }

        let supportDirectory: URL
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            supportDirectory = appSupport
        } else {
            supportDirectory = FileManager.default.temporaryDirectory
        }
        let rootDirectory = supportDirectory.appendingPathComponent("GhostgramArchive", isDirectory: true)
        self.mediaDirectory = rootDirectory.appendingPathComponent("media", isDirectory: true)

        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.mediaDirectory, withIntermediateDirectories: true)

        self.storage = AntiDeleteStorage(directory: rootDirectory)
        if let storage = storage {
            deletedIdsLock.lock()
            deletedMessageIds = storage.deletedIds()
            deletedIdsLock.unlock()
            migrateLegacyJSON(from: rootDirectory.appendingPathComponent("archive.json"))
            migrateLegacyUserDefaults()
        } else {
            // БД не открылась — деградируем до пустого архива, приложение продолжает работать
            print("[AntiDelete] storage unavailable, anti-delete archive disabled until restart")
        }
    }

    /// Одноразовая миграция JSON-хранилища фазы 2а в SQLite
    private func migrateLegacyJSON(from url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let legacy = try JSONDecoder().decode(LegacyStorage.self, from: data)
            for message in legacy.archive {
                storage?.insertArchived(message)
            }
            for key in legacy.deletedIds {
                deletedIdsLock.lock()
                deletedMessageIds.insert(key)
                deletedIdsLock.unlock()
                storage?.insertDeletedId(key: key)
            }
            try? FileManager.default.removeItem(at: url)
            print("[AntiDelete] migrated \(legacy.archive.count) messages from JSON store")
        } catch {
            print("[AntiDelete] legacy JSON migration failed: \(error)")
        }
    }

    /// Одноразовая миграция самого старого хранилища (UserDefaults)
    private let legacyArchiveKey = "antiDelete.archive"
    private let legacyDeletedIdsKey = "antiDelete.deletedIds"

    private func migrateLegacyUserDefaults() {
        if let data = defaults.data(forKey: legacyArchiveKey),
           let legacyArchive = try? JSONDecoder().decode([ArchivedMessage].self, from: data) {
            for message in legacyArchive {
                storage?.insertArchived(message)
            }
            defaults.removeObject(forKey: legacyArchiveKey)
        }
        if let ids = defaults.stringArray(forKey: legacyDeletedIdsKey) {
            for key in ids {
                deletedIdsLock.lock()
                deletedMessageIds.insert(key)
                deletedIdsLock.unlock()
                storage?.insertDeletedId(key: key)
            }
            defaults.removeObject(forKey: legacyDeletedIdsKey)
        }
    }

    // MARK: - Media Archival

    /// Максимальный размер копируемого файла (1 ГБ), чтобы не забивать диск патологическими случаями
    private static let maxArchivedMediaFileSize: Int64 = 1_000_000_000

    /// Копирует уже скачанный медиа-файл в архив, защищённый от очистки кэша.
    /// - Returns: имя файла внутри архива, либо nil
    public func archiveMediaFile(sourcePath: String, peerId: Int64, messageId: Int32, fileExtension: String?) -> String? {
        guard isEnabled, archiveMedia else { return nil }
        let name = "\(peerId)_\(messageId)"
        return copyMediaFileToArchive(sourcePath: sourcePath, baseName: name, fileExtension: fileExtension)
    }

    /// Прикрепляет докачанный файл к уже архивированной записи (отложенная архивация).
    /// Имя строится от globalId, чтобы избежать коллизий с мгновенными копиями.
    public func attachArchivedMedia(globalId: Int32, peerId: Int64, sourcePath: String, fileExtension: String?, kind: ArchivedMediaKind) {
        guard isEnabled, archiveMedia else { return }
        let name = "g\(globalId)_\(peerId)"
        guard let archivedName = copyMediaFileToArchive(sourcePath: sourcePath, baseName: name, fileExtension: fileExtension ?? kind.defaultFileExtension) else {
            return
        }
        storage?.updateMedia(globalId: globalId, peerId: peerId, mediaPath: archivedName, mediaKind: kind.rawValue)
    }

    private func copyMediaFileToArchive(sourcePath: String, baseName: String, fileExtension: String?) -> String? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourcePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        if let attrs = try? fm.attributesOfItem(atPath: sourcePath),
           let size = attrs[.size] as? NSNumber, size.int64Value > Self.maxArchivedMediaFileSize {
            return nil
        }
        var ext = (fileExtension ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if ext.isEmpty {
            ext = (sourcePath as NSString).pathExtension
        }
        if ext.isEmpty {
            ext = ArchivedMediaKind.file.defaultFileExtension
        }
        let name = "\(baseName).\(ext)"
        let destination = mediaDirectory.appendingPathComponent(name)
        if fm.fileExists(atPath: destination.path) {
            return name
        }
        do {
            try fm.copyItem(atPath: sourcePath, toPath: destination.path)
            return name
        } catch {
            print("[AntiDelete] Failed to archive media: \(error)")
            return nil
        }
    }

    /// URL сохранённого медиа-файла, если он есть
    public func archivedMediaURL(for message: ArchivedMessage) -> URL? {
        guard let path = message.mediaPath, !path.isEmpty else { return nil }
        let url = mediaDirectory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func removeArchivedMediaFile(_ path: String?) {
        guard let path = path, !path.isEmpty else { return }
        let url = mediaDirectory.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Archive Operations

    /// Архивировать сообщение перед удалением
    public func archiveMessage(
        globalId: Int32,
        peerId: Int64,
        messageId: Int32,
        timestamp: Int32,
        authorId: Int64?,
        text: String,
        forwardAuthorId: Int64? = nil,
        mediaDescription: String? = nil,
        mediaPath: String? = nil,
        mediaKind: String? = nil
    ) {
        guard isEnabled else { return }

        let archived = ArchivedMessage(
            globalId: globalId,
            peerId: peerId,
            messageId: messageId,
            timestamp: timestamp,
            deletedAt: Int32(Date().timeIntervalSince1970),
            authorId: authorId,
            text: text,
            forwardAuthorId: forwardAuthorId,
            mediaDescription: mediaDescription,
            mediaPath: mediaPath,
            mediaKind: mediaKind
        )

        storage?.insertArchived(archived)
    }

    /// Получить все архивированные сообщения
    public func getAllArchivedMessages() -> [ArchivedMessage] {
        return storage?.allArchived() ?? []
    }

    /// Получить архивированные сообщения для конкретного чата
    /// - Parameter peerId: ID чата
    public func getArchivedMessages(forPeerId peerId: Int64) -> [ArchivedMessage] {
        return storage?.archived(peerId: peerId) ?? []
    }

    /// Количество архивированных сообщений
    public var archivedCount: Int {
        return storage?.count() ?? 0
    }

    /// Получить данные архивированных сообщений для удаления из диалогов
    /// Возвращает массив (peerId, messageId)
    public func getArchivedMessageData() -> [(peerId: Int64, messageId: Int32)] {
        return storage?.archivedIds() ?? []
    }

    /// Очистить архив
    public func clearArchive() {
        let mediaPaths = storage?.clear() ?? []
        for path in mediaPaths {
            removeArchivedMediaFile(path)
        }
        deletedIdsLock.lock()
        deletedMessageIds.removeAll()
        deletedIdsLock.unlock()
    }

    /// Удалить конкретное сообщение из архива
    public func removeFromArchive(globalId: Int32) {
        if let mediaPath = storage?.deleteArchived(globalId: globalId) {
            removeArchivedMediaFile(mediaPath)
        }
    }
}
