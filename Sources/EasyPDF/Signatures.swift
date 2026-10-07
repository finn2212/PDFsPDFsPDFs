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

// MARK: - Picker (popover)

/// Quick pick: every saved signature and its initials as large tiles.
struct SignaturePicker: View {
    @EnvironmentObject var doc: DocumentModel
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(store.persons) { person in
                        PersonTiles(person: person,
                                    place: place,
                                    placeEverywhere: placeEverywhere,
                                    edit: { edit(person, kind: $0) },
                                    delete: { store.remove(person) })
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button {
                edit(Person(), kind: .signature)
            } label: {
                Label(loc("signature.new"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 380)
    }

    private func place(_ person: Person, _ kind: AssetKind) {
        guard let image = kind == .signature ? person.signatureImage : person.initialsImage else { return }
        doc.showSignaturePicker = false
        let label = kind == .signature
            ? loc("signature.placeLabel", person.displayName)
            : loc("initials.placeLabel", person.displayName)
        doc.startPlacing(image: image, defaultWidth: kind == .signature ? 170 : 56, label: label)
    }

    private func placeEverywhere(_ person: Person) {
        guard let image = person.initialsImage else { return }
        doc.showSignaturePicker = false
        doc.placeOnEveryPage(image: image, width: 46)
    }

    private func edit(_ person: Person, kind: AssetKind) {
        doc.showSignaturePicker = false
        // One modal at a time: let the popover close before the sheet opens.
        DispatchQueue.main.async {
            doc.signatureEditor = SignatureEditorRequest(person: person, kind: kind,
                                                         placeAfterSave: person.signaturePNG == nil)
        }
    }
}

private struct PersonTiles: View {
    let person: Person
    let place: (Person, AssetKind) -> Void
    let placeEverywhere: (Person) -> Void
    let edit: (AssetKind) -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(person.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button(loc("person.edit")) { edit(.signature) }
                    Button(loc("person.delete"), role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(loc("signature.more"))
            }
            HStack(alignment: .top, spacing: 10) {
                AssetTile(image: person.signatureImage,
                          caption: loc("person.signature"),
                          emptyLabel: loc("signature.addSignature"),
                          width: 220) {
                    person.signatureImage != nil ? place(person, .signature) : edit(.signature)
                }
                .uiTestTarget("tile.signature.\(person.id)")
                VStack(spacing: 6) {
                    AssetTile(image: person.initialsImage,
                              caption: loc("person.initials"),
                              emptyLabel: loc("signature.addInitials"),
                              width: 110) {
                        person.initialsImage != nil ? place(person, .initials) : edit(.initials)
                    }
                    if person.initialsImage != nil {
                        Button(loc("initials.everyPage")) { placeEverywhere(person) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help(loc("initials.everyPage.help"))
                    }
                }
            }
        }
    }
}

private struct AssetTile: View {
    let image: NSImage?
    let caption: String
    let emptyLabel: String
    let width: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(10)
                    } else {
                        Label(emptyLabel, systemImage: "plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: width, height: 76)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.12),
                                      style: StrokeStyle(lineWidth: hovering ? 2 : 1,
                                                         dash: image == nil ? [5, 4] : []))
                )
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(image == nil ? emptyLabel : loc("signature.clickToPlace"))
    }
}

// MARK: - Editor (sheet)

/// One sheet for creating or editing a signature and initials: draw, type
/// or import an image. No nested sheets; the name is optional.
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
