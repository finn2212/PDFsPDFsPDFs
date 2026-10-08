import Foundation

/// The lproj bundle matching the user's languages. Resolved explicitly so
/// unbundled builds (swift run, snapshots) pick the same language as the app.
private let localizedBundle: Bundle = {
    let preferred = Bundle.preferredLocalizations(from: Bundle.module.localizations,
                                                  forPreferences: Locale.preferredLanguages)
    if let language = preferred.first,
       let path = Bundle.module.path(forResource: language, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle
    }
    return .module
}()

func loc(_ key: String) -> String {
    NSLocalizedString(key, bundle: localizedBundle, comment: "")
}

func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: localizedBundle, comment: ""), arguments: args)
}

/// Count-dependent string: uses "<key>.one" for exactly one, "<key>" otherwise.
func locCount(_ key: String, _ count: Int) -> String {
    let singular = key + ".one"
    if count == 1, NSLocalizedString(singular, bundle: localizedBundle, comment: "") != singular {
        return loc(singular, count)
    }
    return loc(key, count)
}
