import Foundation

/// A user folder for meetings (Apple Notes style). A meeting is in at most one folder,
/// recorded as `Recording.folderID`; the folder list itself lives in `folders.json` at the library root,
/// so it syncs with the library.
public struct Folder: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    /// Index into the shared palette (`Theme.folderColor`).
    public var colorIndex: Int
    public var createdAt: Date
    /// Custom notes instructions for meetings in this folder; nil uses the app's.
    public var notesPrompt: String?

    public init(id: UUID = UUID(), name: String, symbol: String = "folder", colorIndex: Int = 0, createdAt: Date = Date(),
                notesPrompt: String? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorIndex = colorIndex
        self.createdAt = createdAt
        self.notesPrompt = notesPrompt
    }

    /// Symbols offered when creating or editing a folder.
    public static let symbols = ["folder", "person.2", "briefcase", "building.2", "person.crop.circle", "star",
                                 "lightbulb", "graduationcap", "heart", "flag", "chart.bar", "hammer"]

    private enum CodingKeys: String, CodingKey { case id, name, symbol, colorIndex, createdAt, notesPrompt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Folder"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "folder"
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        notesPrompt = try? c.decodeIfPresent(String.self, forKey: .notesPrompt)
    }
}
