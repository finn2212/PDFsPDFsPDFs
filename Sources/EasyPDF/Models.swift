import Foundation
import AppKit

struct Person: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var signaturePNG: Data?
    var initialsPNG: Data?

    var signatureImage: NSImage? { signaturePNG.flatMap { NSImage(data: $0) } }
    var initialsImage: NSImage? { initialsPNG.flatMap { NSImage(data: $0) } }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published var persons: [Person] = [] {
        didSet { save() }
    }

    private let fileURL: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("PDFsPDFsPDFs", isDirectory: true)
        // Migrate data from the app's previous name.
        let legacyDir = support.appendingPathComponent("EasyPDF", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.moveItem(at: legacyDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("persons.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Person].self, from: data) else { return }
        persons = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(persons) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func update(_ person: Person) {
        if let idx = persons.firstIndex(where: { $0.id == person.id }) {
            persons[idx] = person
        } else {
            persons.append(person)
        }
    }

    func remove(_ person: Person) {
        persons.removeAll { $0.id == person.id }
    }
}
