import AppKit
import PDFKit
import SwiftUI

/// How the open document is protected.
enum ProtectionKind {
    /// Needed a password to open.
    case password
    /// Opens without a password but forbids printing, copying or changes.
    case restrictions
    /// Encrypted without visible restrictions.
    case encrypted
}

/// What the password sheet asks for.
struct PasswordRequest: Identifiable {
    enum Purpose {
        /// The password that opens a locked file.
        case open
        /// The owner password that lifts printing/copying/editing restrictions.
        case removeRestrictions
    }

    let id = UUID()
    let purpose: Purpose
    let fileName: String
    /// The locked document and its file, waiting for the password (`.open`).
    let pending: PDFDocument?
    let url: URL?
}

/// Password-protected PDFs: unlocking on open and removing the protection.
/// Passwords are only handed to PDFKit; they are never stored or logged.
enum PDFProtection {
    /// PDFKit's `write(to:)` keeps the original encryption even after
    /// unlocking, so an unprotected file needs a fresh document holding
    /// copies of the pages.
    static func unprotectedCopy(of doc: PDFDocument) -> PDFDocument {
        let out = PDFDocument()
        for index in 0..<doc.pageCount {
            if let page = doc.page(at: index)?.copy() as? PDFPage {
                out.insert(page, at: out.pageCount)
            }
        }
        out.documentAttributes = doc.documentAttributes
        return out
    }

    /// True if any permission (print, copy, change, …) is withheld.
    static func isRestricted(_ doc: PDFDocument) -> Bool {
        !(doc.allowsPrinting && doc.allowsCopying && doc.allowsDocumentChanges
          && doc.allowsDocumentAssembly && doc.allowsCommenting
          && doc.allowsFormFieldEntry && doc.allowsContentAccessibility)
    }

    /// Restrictions may only be removed with the owner password, as in
    /// Preview and Acrobat.
    static func needsOwnerPassword(_ doc: PDFDocument) -> Bool {
        doc.isEncrypted && doc.permissionsStatus != .owner && isRestricted(doc)
    }

    /// `unlock` also returns true for a wrong password on a document that is
    /// already open, so success means owner rights afterwards.
    static func unlockAsOwner(_ doc: PDFDocument, password: String) -> Bool {
        doc.unlock(withPassword: password) && doc.permissionsStatus == .owner
    }

    static func kind(of doc: PDFDocument, openedWithPassword: Bool) -> ProtectionKind? {
        guard doc.isEncrypted else { return nil }
        if openedWithPassword { return .password }
        return isRestricted(doc) ? .restrictions : .encrypted
    }
}

extension DocumentModel {
    var isProtected: Bool { document?.isEncrypted == true }

    /// Opening a locked file: ask for its password first.
    func askForOpenPassword(_ doc: PDFDocument, url: URL) {
        passwordRequest = PasswordRequest(purpose: .open, fileName: url.lastPathComponent,
                                          pending: doc, url: url)
    }

    /// Tries the password; false if it is wrong (the sheet stays up).
    @discardableResult
    func submitPassword(_ password: String, for request: PasswordRequest) -> Bool {
        switch request.purpose {
        case .open:
            guard let doc = request.pending, let url = request.url,
                  doc.unlock(withPassword: password) else { return false }
            passwordRequest = nil
            load(doc, url: url, untitledName: nil, mode: .document)
            protectionKind = .password
            RecentsStore.add(url)
        case .removeRestrictions:
            guard let doc = document, PDFProtection.unlockAsOwner(doc, password: password) else { return false }
            passwordRequest = nil
            // The confirmation follows once the sheet is gone (see passwordSheetDismissed).
            confirmAfterPasswordSheet = true
        }
        return true
    }

    func passwordSheetDismissed() {
        if confirmAfterPasswordSheet {
            confirmAfterPasswordSheet = false
            removeProtectionConfirm = true
        }
    }

    /// "Remove password…": asks for the owner password if restrictions need
    /// it, then where to save the unprotected PDF.
    func requestRemoveProtection() {
        guard let doc = document, doc.isEncrypted else { return }
        finishInlineEditing?(true)
        if PDFProtection.needsOwnerPassword(doc) {
            passwordRequest = PasswordRequest(purpose: .removeRestrictions, fileName: displayName,
                                              pending: nil, url: nil)
        } else {
            removeProtectionConfirm = true
        }
    }

    /// Overwrites the original with an unprotected version.
    func removeProtectionInPlace() {
        guard let url = fileURL else { removeProtectionAsCopy(); return }
        save(to: url, removingProtection: true)
    }

    /// Saves an unprotected copy next to the original; the open document
    /// stays as it is.
    func removeProtectionAsCopy() {
        guard document != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = baseName + loc("protection.copySuffix") + ".pdf"
        if let dir = fileURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportCurrentState(to: url, removingProtection: true)
            statusMessage = loc("status.unprotected", url.lastPathComponent)
        } catch {
            showError(error.localizedDescription, title: loc("alert.saveError"))
        }
    }
}

/// Asks for the password that opens a file or lifts its restrictions.
@MainActor
struct PasswordSheet: View {
    let request: PasswordRequest
    @EnvironmentObject var doc: DocumentModel
    @State private var password = ""
    @State private var wasWrong = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SecureField(loc("password.field"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .onChange(of: password) { value in
                        if !value.isEmpty { wasWrong = false }
                    }
                if wasWrong {
                    Label(loc("password.wrong"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .padding(.leading, 48)
            HStack {
                Spacer()
                Button(loc("action.cancel"), role: .cancel) { doc.passwordRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { fieldFocused = true }
    }

    private var title: String {
        switch request.purpose {
        case .open: return loc("password.open.title", request.fileName)
        case .removeRestrictions: return loc("password.owner.title")
        }
    }

    private var message: String {
        switch request.purpose {
        case .open: return loc("password.open.message")
        case .removeRestrictions: return loc("password.owner.message")
        }
    }

    private var confirmTitle: String {
        switch request.purpose {
        case .open: return loc("password.open.confirm")
        case .removeRestrictions: return loc("password.owner.confirm")
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let accepted = doc.submitPassword(password, for: request)
        password = ""
        if !accepted {
            wasWrong = true
            fieldFocused = true
        }
    }
}

/// Context-row note for protected PDFs, with the way out.
@MainActor
struct ProtectionHint: View {
    @EnvironmentObject var doc: DocumentModel

    var body: some View {
        Image(systemName: "lock.fill").foregroundStyle(Color.accentColor)
        Text(text)
        Button(loc("protection.remove")) { doc.requestRemoveProtection() }
            .controlSize(.small)
        BarIconButton(systemImage: "xmark", help: loc("action.dismiss")) {
            doc.protectionHintDismissed = true
        }
    }

    private var text: String {
        switch doc.protectionKind {
        case .password: return loc("protection.hint.password")
        case .restrictions: return loc("protection.hint.restrictions")
        case .encrypted, .none: return loc("protection.hint.encrypted")
        }
    }
}
