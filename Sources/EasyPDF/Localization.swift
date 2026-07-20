import Foundation

func loc(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: .module, comment: ""), arguments: args)
}
