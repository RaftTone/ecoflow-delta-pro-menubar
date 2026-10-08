// Мінімальна двомовність: англійська (типово) і українська (за мовою системи).
// Для прев'ю/тестів мову можна примусити змінною середовища ECOFLOWBAR_LANG=uk|en.

import Foundation

enum L {
    static let isUk: Bool = {
        if let o = ProcessInfo.processInfo.environment["ECOFLOWBAR_LANG"] { return o.hasPrefix("uk") }
        return Locale.preferredLanguages.first?.hasPrefix("uk") ?? false
    }()
    static func t(_ en: String, _ uk: String) -> String { isUk ? uk : en }

    static let w = t("W", "Вт")
    static let hour = t("h", "год")
    static let minute = t("min", "хв")
}
