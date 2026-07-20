import SwiftUI

struct PeopleSidebar: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var doc: DocumentModel
    @State private var editingPerson: Person?

    var body: some View {
        List {
            Section(loc("sidebar.people")) {
                if store.persons.isEmpty {
                    Text(loc("sidebar.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.persons) { person in
                    PersonRow(person: person, onEdit: { editingPerson = person })
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                editingPerson = Person(name: "")
            } label: {
                Label(loc("sidebar.addPerson"), systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(10)
        }
        .sheet(item: $editingPerson) { person in
            PersonEditorSheet(person: person)
        }
    }
}

private struct PersonRow: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var doc: DocumentModel
    let person: Person
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(person.name.isEmpty ? loc("person.new") : person.name)
                    .font(.headline)
                Spacer()
                Menu {
                    Button(loc("person.edit"), action: onEdit)
                    Button(loc("person.delete"), role: .destructive) {
                        store.remove(person)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            assetRow(label: loc("person.signature"),
                     image: person.signatureImage,
                     placeLabel: loc("person.place.signature"),
                     defaultWidth: 180)
            assetRow(label: loc("person.initials"),
                     image: person.initialsImage,
                     placeLabel: loc("person.place.initials"),
                     defaultWidth: 70)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func assetRow(label: String, image: NSImage?, placeLabel: String, defaultWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text(loc("editor.notSet"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 90, height: 32)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Button(placeLabel) {
                    guard let image else { return }
                    let name = person.name.isEmpty ? loc("person.new") : person.name
                    doc.pendingStamp = PendingStamp(
                        image: image,
                        defaultWidth: defaultWidth,
                        label: "\(label) – \(name)"
                    )
                }
                .font(.caption)
                .disabled(image == nil || doc.document == nil)
            }
            Spacer(minLength: 0)
        }
    }
}

struct PersonEditorSheet: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State var person: Person
    @State private var drawingKind: AssetKind?
    @State private var removeWhite = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(loc("editor.title")).font(.title3.bold())

            HStack {
                Text(loc("editor.name"))
                TextField(loc("editor.namePlaceholder"), text: $person.name)
                    .textFieldStyle(.roundedBorder)
            }

            assetEditor(kind: .signature,
                        title: loc("person.signature"),
                        data: $person.signaturePNG)
            assetEditor(kind: .initials,
                        title: loc("person.initials"),
                        data: $person.initialsPNG)

            Toggle(loc("import.removeWhite"), isOn: $removeWhite)
                .font(.callout)

            HStack {
                Spacer()
                Button(loc("editor.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(loc("editor.done")) {
                    store.update(person)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(person.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .sheet(item: $drawingKind) { kind in
            SignatureDrawingSheet(kind: kind) { png in
                switch kind {
                case .signature: person.signaturePNG = png
                case .initials: person.initialsPNG = png
                }
            }
        }
    }

    @ViewBuilder
    private func assetEditor(kind: AssetKind, title: String, data: Binding<Data?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack(spacing: 10) {
                Group {
                    if let d = data.wrappedValue, let image = NSImage(data: d) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Text(loc("editor.notSet"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 160, height: 56)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                VStack(alignment: .leading, spacing: 6) {
                    Button(loc("editor.draw")) { drawingKind = kind }
                    Button(loc("editor.importImage")) {
                        if let png = SignatureImport.importImage(removeWhite: removeWhite) {
                            data.wrappedValue = png
                        }
                    }
                    if data.wrappedValue != nil {
                        Button(loc("editor.remove"), role: .destructive) {
                            data.wrappedValue = nil
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

extension AssetKind: Identifiable {
    var id: String {
        switch self {
        case .signature: return "signature"
        case .initials: return "initials"
        }
    }
}
