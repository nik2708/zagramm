import Foundation

/// Менеджер для сохранения удалённых сообщений
/// Перехватывает сообщения перед удалением и архивирует их локально
public final class AntiDeleteManager {

    public static let shared = AntiDeleteManager()

    // MARK: - Settings

    private let defaults = UserDefaults.standard
    private let enabledKey = "antiDelete.enabled"
    private let archiveMediaKey = "antiDelete.archiveMedia"
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

    // MARK: - Deleted Message IDs Storage

    private var deletedMessageIds: Set<String> = []
    private let deletedIdsLock = NSLock()

    /// Пометить сообщение как удалённое
    public func markAsDeleted(peerId: Int64, messageId: Int32) {
        let key = "\(peerId)_\(messageId)"
        deletedIdsLock.lock()
        deletedMessageIds.insert(key)
        deletedIdsLock.unlock()
        persistStorage()
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

    // MARK: - File-backed storage

    /// Всё хранится в JSON-файле, а не в UserDefaults:
    /// UserDefaults плохо переносит мегабайты данных, а история удалённых растёт неограниченно.
    private struct Storage: Codable {
        var archive: [ArchivedMessage] = []
        var deletedIds: [String] = []
    }

    private let storageLock = NSLock()
    private var storage = Storage()
    private let storageURL: URL
    private let mediaDirectory: URL

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

    private init() {
        // Set default values
        if defaults.object(forKey: enabledKey) == nil {
            defaults.set(true, forKey: enabledKey)
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
        self.storageURL = rootDirectory.appendingPathComponent("archive.json")
        self.mediaDirectory = rootDirectory.appendingPathComponent("media", isDirectory: true)

        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.mediaDirectory, withIntermediateDirectories: true)

        loadStorage()
        migrateFromUserDefaultsIfNeeded()
    }

    // MARK: - Persistence

    private let storageQueue = DispatchQueue(label: "com.ghostgram.antiDelete.storage", qos: .utility)
    private var persistScheduled = false

    private func loadStorage() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            storage = try JSONDecoder().decode(Storage.self, from: data)
        } catch {
            print("[AntiDelete] Failed to load storage: \(error)")
            storage = Storage()
        }
    }

    /// Записывает хранилище на диск. Дебаунится, чтобы массовое удаление
    /// (тысячи сообщений) не приводило к перезаписи всего файла на каждое сообщение.
    private func persistStorage() {
        storageLock.lock()
        if persistScheduled {
            storageLock.unlock()
            return
        }
        persistScheduled = true
        storageLock.unlock()

        storageQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.flushStorage()
        }
    }

    /// Немедленная запись (для операций, результат которых нельзя терять)
    private func flushStorage() {
        storageLock.lock()
        persistScheduled = false
        let data: Data?
        do {
            data = try JSONEncoder().encode(storage)
        } catch {
            data = nil
            print("[AntiDelete] Failed to encode storage: \(error)")
        }
        storageLock.unlock()

        if let data = data {
            do {
                try data.write(to: storageURL, options: .atomic)
            } catch {
                print("[AntiDelete] Failed to save storage: \(error)")
            }
        }
    }

    /// Одноразовая миграция старого хранилища из UserDefaults
    private let legacyArchiveKey = "antiDelete.archive"
    private let legacyDeletedIdsKey = "antiDelete.deletedIds"

    private func migrateFromUserDefaultsIfNeeded() {
        var migrated = false
        if let data = defaults.data(forKey: legacyArchiveKey),
           let legacyArchive = try? JSONDecoder().decode([ArchivedMessage].self, from: data) {
            storageLock.lock()
            let existing = Set(storage.archive.map { $0.globalId })
            storage.archive.append(contentsOf: legacyArchive.filter { !existing.contains($0.globalId) })
            storageLock.unlock()
            defaults.removeObject(forKey: legacyArchiveKey)
            migrated = true
        }
        if let ids = defaults.stringArray(forKey: legacyDeletedIdsKey) {
            storageLock.lock()
            let existing = Set(storage.deletedIds)
            storage.deletedIds.append(contentsOf: ids.filter { !existing.contains($0) })
            storageLock.unlock()
            defaults.removeObject(forKey: legacyDeletedIdsKey)
            migrated = true
        }
        if migrated {
            flushStorage()
        }
        storageLock.lock()
        deletedMessageIds = Set(storage.deletedIds)
        storageLock.unlock()
    }

    // MARK: - Media Archival

    /// Максимальный размер копируемого файла (1 ГБ), чтобы не забивать диск патологическими случаями
    private static let maxArchivedMediaFileSize: Int64 = 1_000_000_000

    /// Копирует уже скачанный медиа-файл в архив, защищённый от очистки кэша.
    /// - Returns: имя файла внутри архива, либо nil
    public func archiveMediaFile(sourcePath: String, peerId: Int64, messageId: Int32, fileExtension: String?) -> String? {
        guard isEnabled, archiveMedia else { return nil }
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
        let name = "\(peerId)_\(messageId).\(ext)"
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
    /// - Parameters:
    ///   - globalId: Глобальный ID сообщения
    ///   - peerId: ID чата
    ///   - messageId: Локальный ID сообщения
    ///   - timestamp: Время отправки
    ///   - authorId: ID автора
    ///   - text: Текст сообщения
    ///   - forwardAuthorId: ID автора пересланного сообщения
    ///   - mediaDescription: Описание медиа (тип, размер)
    ///   - mediaPath: Имя архивированного медиа-файла
    ///   - mediaKind: Тип архивированного медиа
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

        storageLock.lock()
        defer { storageLock.unlock() }

        // Avoid duplicates
        if !storage.archive.contains(where: { $0.globalId == globalId && $0.peerId == peerId }) {
            storage.archive.append(archived)
            persistStorage()
        }
    }

    /// Получить все архивированные сообщения
    public func getAllArchivedMessages() -> [ArchivedMessage] {
        storageLock.lock()
        defer { storageLock.unlock() }
        return storage.archive.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Получить архивированные сообщения для конкретного чата
    /// - Parameter peerId: ID чата
    public func getArchivedMessages(forPeerId peerId: Int64) -> [ArchivedMessage] {
        storageLock.lock()
        defer { storageLock.unlock() }
        return storage.archive
            .filter { $0.peerId == peerId }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Количество архивированных сообщений
    public var archivedCount: Int {
        storageLock.lock()
        defer { storageLock.unlock() }
        return storage.archive.count
    }

    /// Получить данные архивированных сообщений для удаления из диалогов
    /// Возвращает массив (peerId, messageId)
    public func getArchivedMessageData() -> [(peerId: Int64, messageId: Int32)] {
        storageLock.lock()
        defer { storageLock.unlock() }
        return storage.archive.map { (peerId: $0.peerId, messageId: $0.messageId) }
    }

    /// Очистить архив
    public func clearArchive() {
        storageLock.lock()
        let mediaPaths = storage.archive.map { $0.mediaPath }
        storage.archive.removeAll()
        storage.deletedIds.removeAll()
        deletedIdsLock.lock()
        deletedMessageIds.removeAll()
        deletedIdsLock.unlock()
        storageLock.unlock()

        for path in mediaPaths {
            removeArchivedMediaFile(path)
        }
        flushStorage()
    }

    /// Удалить конкретное сообщение из архива
    public func removeFromArchive(globalId: Int32) {
        storageLock.lock()
        let mediaPath = storage.archive.first(where: { $0.globalId == globalId })?.mediaPath
        storage.archive.removeAll { $0.globalId == globalId }
        storageLock.unlock()

        removeArchivedMediaFile(mediaPath)
        flushStorage()
    }
}
