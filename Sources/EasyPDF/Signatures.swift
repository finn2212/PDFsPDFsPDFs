import SwiftUI

/// Opens the signature editor for `person`, starting on `kind`.
struct SignatureEditorRequest: Identifiable {
    let id = UUID()
    var person: Person
    var kind: AssetKind
    /// Start placing the result right after saving (first signature).
    var placeAfterSave = true
    var method: InputMethod = .draw
}

extension Person {
    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? loc("signature.unnamed") : name
    }
}

// MARK: - Actions

/// Starting a signature: one click places the default signature; the menu
/// next to the button offers initials, other people and editing.
@MainActor
enum SignatureActions {
    private static let lastUsedKey = "lastSignaturePerson"

    /// The signature used last, else the first one that exists.
    static func defaultPerson(in store: ProfileStore) -> Person? {
        let last = UserDefaults.standard.string(forKey: lastUsedKey)
        return store.persons.first { $0.id.uuidString == last && $0.signatureImage != nil }
            ?? store.persons.first { $0.signatureImage != nil }
    }

    /// "Sign": place the default signature, or create the first one.
    static func sign(doc: DocumentModel, store: ProfileStore) {
        doc.mode = .document
        if let person = defaultPerson(in: store) {
            place(person, .signature, doc: doc)
        } else {
            Log.ui.notice("sign: no signature yet, opening the editor")
            doc.signatureEditor = SignatureEditorRequest(person: Person(), kind: .signature)
        }
    }

    static func place(_ person: Person, _ kind: AssetKind, doc: DocumentModel) {
        guard let image = kind == .signature ? person.signatureImage : person.initialsImage else { return }
        UserDefaults.standard.set(person.id.uuidString, forKey: lastUsedKey)
        let label = kind == .signature
            ? loc("signature.placeLabel", person.displayName)
            : loc("initials.placeLabel", person.displayName)
        Log.ui.notice("sign: start placing \(kind == .signature ? "signature" : "initials", privacy: .public)")
        doc.startPlacing(image: image, defaultWidth: kind == .signature ? 170 : 56, label: label)
    }

    static func placeEverywhere(_ person: Person, doc: DocumentModel) {
        guard let image = person.initialsImage else { return }
        doc.placeOnEveryPage(image: image, width: 46)
    }

    static func edit(_ person: Person, kind: AssetKind, doc: DocumentModel) {
        doc.signatureEditor = SignatureEditorRequest(person: person, kind: kind,
                                                     placeAfterSave: person.signaturePNG == nil)
    }
}

/// Menu next to "Sign": every signature and initials with a small preview.
@MainActor
struct SignatureMenuItems: View {
    @EnvironmentObject var doc: DocumentModel
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        ForEach(store.persons) { person in
            Section(person.displayName) {
                if let image = person.signatureImage {
                    Button {
                        SignatureActions.place(person, .signature, doc: doc)
                    } label: {
                        Label { Text(loc("person.signature")) } icon: { Image(nsImage: Self.thumbnail(image)) }
                    }
                }
                if let image = person.initialsImage {
                    Button {
                        SignatureActions.place(person, .initials, doc: doc)
                    } label: {
                        Label { Text(loc("person.initials")) } icon: { Image(nsImage: Self.thumbnail(image)) }
                    }
                    Button(loc("initials.everyPage")) {
                        SignatureActions.placeEverywhere(person, doc: doc)
                    }
                    .help(loc("initials.everyPage.help"))
                }
                Button(loc("person.edit") + " …") {
                    SignatureActions.edit(person, kind: .signature, doc: doc)
                }
                Button(loc("person.delete"), role: .destructive) { store.remove(person) }
            }
        }
        Divider()
        Button(loc("signature.new")) {
            SignatureActions.edit(Person(), kind: .signature, doc: doc)
        }
    }

    /// Menu items show images at their own size: scale to text height.
    static func thumbnail(_ image: NSImage) -> NSImage {
        let height: CGFloat = 18
        let width = min(72, image.size.height > 0 ? image.size.width * height / image.size.height : height)
        let result = NSImage(size: NSSize(width: width, height: height))
        result.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        result.unlockFocus()
        return result
    }
}

// MARK: - Editor (sheet)

/// One sheet for creating or editing a signature and initials: draw, type
/// or import an image. No nested sheets; the name is optional.
@MainActor
struct SignatureEditorSheet: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var doc: DocumentModel
    @Environment(\.dismiss) private var dismiss

    let request: SignatureEditorRequest
    @State private var name: String
    @State private var kind: AssetKind
    @State private var signature: AssetDraft
    @State private var initials: AssetDraft

    init(request: SignatureEditorRequest) {
        self.request = request
        _name = State(initialValue: request.person.name)
        _kind = State(initialValue: request.kind)
        _signature = State(initialValue: AssetDraft(existing: request.person.signaturePNG,
                                                     method: request.method,
                                                     typedText: request.method == .type ? request.person.name : ""))
        _initials = State(initialValue: AssetDraft(existing: request.person.initialsPNG,
                                                    method: request.method))
    }

    private var isNew: Bool { request.person.signaturePNG == nil && request.person.initialsPNG == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? loc("editor.titleNew") : loc("editor.title"))
                .font(.title2.bold())

            Picker("", selection: $kind) {
                Text(loc("person.signature")).tag(AssetKind.signature)
                Text(loc("person.initials")).tag(AssetKind.initials)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)

            AssetEditor(draft: kind == .signature ? $signature : $initials,
                        kind: kind,
                        suggestedText: suggestedText)
                .id(kind)

            HStack(spacing: 10) {
                Text(loc("editor.name"))
                    .foregroundStyle(.secondary)
                TextField(loc("editor.namePlaceholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }

            HStack {
                Text(loc("editor.storedLocally"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(loc("editor.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(loc("editor.save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(signature.result == nil && initials.result == nil)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    /// Text prefilled when typing: the name for the signature, its initials otherwise.
    private var suggestedText: String {
        let source = name.trimmingCharacters(in: .whitespaces).isEmpty ? signature.typedText : name
        if kind == .signature { return source }
        return source.split(separator: " ").compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private func save() {
        var person = request.person
        person.name = name.trimmingCharacters(in: .whitespaces)
        person.signaturePNG = signature.result
        person.initialsPNG = initials.result
        store.update(person)
        dismiss()
        guard request.placeAfterSave, doc.document != nil else { return }
        let placeKind: AssetKind = person.signaturePNG != nil ? .signature : .initials
        guard let image = placeKind == .signature ? person.signatureImage : person.initialsImage else { return }
        DispatchQueue.main.async {
            doc.startPlacing(image: image,
                             defaultWidth: placeKind == .signature ? 170 : 56,
                             label: placeKind == .signature
                                ? loc("signature.placeLabel", person.displayName)
                                : loc("initials.placeLabel", person.displayName))
        }
    }
}

enum InputMethod: String, CaseIterable, Identifiable {
    case draw, type, image
    var id: String { rawValue }
    var title: String { loc("editor.method.\(rawValue)") }
    var icon: String {
        switch self {
        case .draw: return "scribble"
        case .type: return "keyboard"
        case .image: return "photo"
        }
    }
}

/// Work-in-progress state of one asset (signature or initials).
struct AssetDraft {
    var existing: Data?
    var method: InputMethod = .draw
    var strokes: [[CGPoint]] = []
    var typedText = ""
    var fontName = ImageUtils.signatureFonts.first ?? "SnellRoundhand"
    var imageData: Data?
    var removeWhite = true

    static let canvasSize = CGSize(width: 552, height: 190)

    /// PNG to store; falls back to the existing asset when nothing new was made.
    var result: Data? {
        switch method {
        case .draw:
            return strokes.isEmpty ? existing : ImageUtils.renderStrokes(strokes, canvasSize: Self.canvasSize)
        case .type:
            return typedText.trimmingCharacters(in: .whitespaces).isEmpty
                ? existing : ImageUtils.renderSignature(typedText, fontName: fontName)
        case .image:
            return imageData ?? existing
        }
    }
}

@MainActor
private struct AssetEditor: View {
    @Binding var draft: AssetDraft
    let kind: AssetKind
    let suggestedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $draft.method) {
                ForEach(InputMethod.allCases) { method in
                    Label(method.title, systemImage: method.icon).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)

            switch draft.method {
            case .draw: drawArea
            case .type: typeArea
            case .image: imageArea
            }
        }
        .onChange(of: draft.method) { method in
            if method == .type, draft.typedText.isEmpty { draft.typedText = suggestedText }
        }
    }

    private var drawArea: some View {
        VStack(alignment: .trailing, spacing: 6) {
            SignatureCanvas(strokes: $draft.strokes,
                            existing: draft.existing.flatMap { NSImage(data: $0) },
                            size: AssetDraft.canvasSize,
                            hint: kind == .signature ? loc("draw.hint") : loc("draw.hintInitials"))
            Button(loc("draw.clear")) {
                draft.strokes = []
                draft.existing = nil
            }
            .disabled(draft.strokes.isEmpty && draft.existing == nil)
        }
    }

    private var typeArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(kind == .signature ? loc("editor.typePlaceholder") : loc("editor.typeInitialsPlaceholder"),
                      text: $draft.typedText)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            HStack(spacing: 8) {
                ForEach(ImageUtils.signatureFonts, id: \.self) { font in
                    Button {
                        draft.fontName = font
                    } label: {
                        Text(draft.typedText.isEmpty ? loc("editor.typeSample") : draft.typedText)
                            .font(.custom(font, size: 24))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .padding(.horizontal, 10)
                            .frame(width: 128, height: 64)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(draft.fontName == font ? Color.accentColor : Color.primary.opacity(0.12),
                                                  lineWidth: draft.fontName == font ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: AssetDraft.canvasSize.height + 26, alignment: .top)
    }

    private var imageArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white)
                if let data = draft.imageData ?? draft.existing, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().padding(14)
                } else {
                    Text(loc("editor.imageHint"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: AssetDraft.canvasSize.width, height: 150)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Button(loc("editor.importImage")) {
                    if let png = SignatureImport.importImage(removeWhite: draft.removeWhite) {
                        draft.imageData = png
                    }
                }
                Toggle(loc("import.removeWhite"), isOn: $draft.removeWhite)
                    .font(.callout)
            }
        }
        .frame(height: AssetDraft.canvasSize.height + 26, alignment: .top)
    }
}
