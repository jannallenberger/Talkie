import Foundation

extension String {
    /// Looks this string up as a key in the app bundle's `Localizable.strings`,
    /// falling back to the string itself (the English source) when no
    /// translation exists.
    ///
    /// SwiftUI auto-localizes string *literals* in `Text`/`Label` (they become
    /// `LocalizedStringKey`), but NOT `String` values — so chrome whose source is
    /// a Swift `String` (enum `displayName`s, computed titles) is localized here.
    var loc: String { NSLocalizedString(self, bundle: .main, comment: "") }
}
