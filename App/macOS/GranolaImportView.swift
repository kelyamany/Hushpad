#if os(macOS)
import LocalScribeKit
import LocalScribeUI
import SwiftUI
import UniformTypeIdentifiers

/// File › Import from Granola…: pick the export (.zip or .csv), review, import.
struct GranolaImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meetings: [GranolaMeeting]

    @State private var selected: Set<UUID> = []
    @State private var done: Int?

    private var existing: Set<UUID> { Set(model.recordings.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.displayMedium)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from Granola").font(.displaySmall)
                    Text("Each meeting keeps its title, your notes, Granola's summary and the transcript.")
                        .foregroundStyle(.secondary)
                }
            }

            List(meetings) { meeting in
                let already = existing.contains(meeting.id)
                Toggle(isOn: Binding(get: { selected.contains(meeting.id) },
                                     set: { if $0 { selected.insert(meeting.id) } else { selected.remove(meeting.id) } })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.title).font(.base.weight(.medium))
                        HStack(spacing: 6) {
                            Text(meeting.createdAt, format: .dateTime.day().month().year().hour().minute())
                            if meeting.transcript != nil { Text("· transcript") }
                            if !meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("· your notes") }
                            if already { Text("· already imported") }
                        }
                        .font(.label)
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(already)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 260)

            if let done {
                Label(done == 1 ? "Imported 1 meeting." : "Imported \(done) meetings.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            }

            HStack {
                Button(selected.count == importable.count ? "Select None" : "Select All") {
                    selected = selected.count == importable.count ? [] : Set(importable.map(\.id))
                }
                .disabled(importable.isEmpty)
                Spacer()
                Button(done == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if done == nil {
                    Button("Import \(selected.count)") {
                        done = model.importGranola(meetings.filter { selected.contains($0.id) })
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .onAppear { selected = Set(importable.map(\.id)) }
    }

    private var importable: [GranolaMeeting] { meetings.filter { !existing.contains($0.id) } }
}

/// Holds the file picker + preview sheet so it can be triggered from the menu bar command.
struct GranolaImportModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var isPicking: Bool
    @State private var meetings: [GranolaMeeting]?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPicking, allowedContentTypes: [.zip, .commaSeparatedText]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    meetings = try GranolaImporter.meetings(from: url)
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: Binding(get: { meetings != nil }, set: { if !$0 { meetings = nil } })) {
                if let meetings { GranolaImportView(meetings: meetings) }
            }
    }
}
#endif
