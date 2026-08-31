import Foundation

/// Local Telegram Premium (как в AyuGram): приложение считает текущий аккаунт премиумным,
/// даже если сервер не подтвердил подписку. Разблокирует только клиентские премиум-функции —
/// серверные ограничения (например, лимит папок) не обходятся.
public final class LocalPremiumManager {

    public static let shared = LocalPremiumManager()

    private let defaults = UserDefaults.standard
    private static let enabledKey = "localPremium.enabled"

    /// Последнее известное серверное значение премиума (обновляется из AccountContext)
    public private(set) var serverIsPremium: Bool = false

    /// Включён ли локальный премиум
    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            notifySettingsChanged()
        }
    }

    /// Итоговый флаг: серверный или локальный
    public var effectiveIsPremium: Bool {
        return serverIsPremium || isEnabled
    }

    /// Вызывается AccountContext после получения серверного значения
    public func updateServerIsPremium(_ value: Bool) {
        self.serverIsPremium = value
    }

    // MARK: - Notifications

    public static let settingsChangedNotification = Notification.Name("LocalPremiumSettingsChanged")

    private func notifySettingsChanged() {
        NotificationCenter.default.post(name: Self.settingsChangedNotification, object: nil)
    }
}
