#if os(macOS)
import HushpadKit
import HushpadUI
import SwiftUI

/// Under the notes: screenshots taken while recording plus images you add (e.g. ones saved from another app).
/// Browse, select, save and delete them; dropping files on the meeting page is handled by `MacDetailView`.
struct MacAttachmentsView: View {
    @Environment(AppModel.self) private var model
    let recording: Recording
    let detail: MeetingDetailModel
    let isLive: Bool
    @Binding var enlarged: Screenshot?
    @Binding var addingImages: Bool

    @State private var selecting = false
    @State private var selected: Set<Screenshot.ID> = []
    /// The screenshots to save once a folder is picked; non-empty opens the folder picker.
    @State private var saving: [Screenshot] = []
    @State private var confirmDeleteSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            bar
            if detail.screenshots.isEmpty {
                Button { addingImages = true } label: {
                    VStack(spacing: Space.xs) {
                        Image(systemName: "photo.on.rectangle.angled").font(.displaySmall)
                        Text(isLive ? "Screenshots you take appear here" : "Drop screenshots here, or click to add")
                            .font(.meta)
                    }
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .background(Radius.shape(Radius.l)
                        .strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLive)
            } else {
                // Added images have no place in the audio, so only show times when there is audio to match.
                ScreensGrid(screenshots: detail.screenshots, minimumWidth: 180, maxPixels: 600, showsTime: recording.hasAudio,
                            selection: selecting ? $selected : nil, open: { enlarged = $0 }) { shot in
                    Button("Open") { enlarged = shot }
                    ShareLink(item: shot.url)
                    Button("Save…") { saving = [shot] }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
                    if !isLive {
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(shot, in: recording) }
                    }
                }
            }
        }
        // A deleted or re-listed image can't stay selected; a different meeting starts fresh.
        .onChange(of: detail.screenshots) { _, shots in
            selected.formIntersection(shots.map(\.id))
            if shots.isEmpty { selecting = false }
        }
        .onChange(of: recording.id) { selecting = false; selected = [] }
        .fileImporter(isPresented: Binding(get: { !saving.isEmpty }, set: { if !$0 { saving = [] } }),
                      allowedContentTypes: [.folder]) { result in
            let shots = saving
            saving = []
            guard case .success(let directory) = result else { return }
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
            do {
                let folder = try model.saveScreenshots(shots, of: recording, to: directory)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                model.errorMessage = "Couldn't save the screenshots: \(error.localizedDescription)"
            }
        }
        .confirmationDialog("Delete \(selected.count) screenshot\(selected.count == 1 ? "" : "s")?",
                            isPresented: $confirmDeleteSelected) {
            Button("Delete", role: .destructive) {
                model.delete(detail.screenshots.filter { selected.contains($0.id) }, in: recording)
                selected = []
            }
        } message: {
            Text("You can undo this from the banner right after.")
        }
    }

    /// Normally: title, count, Select, Save All…, Add Images…. While selecting: what's picked and what to do with it.
    private var bar: some View {
        let shots = detail.screenshots
        return HStack(spacing: Space.s) {
            Text("Attachments").font(.heading)
            if selecting {
                Text("\(selected.count) selected").font(.meta).foregroundStyle(Theme.inkSecondary)
            } else if !shots.isEmpty {
                Text("\(shots.count)").font(.meta).foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            if selecting {
                Button(selected.count == shots.count ? "Deselect All" : "Select All") {
                    selected = selected.count == shots.count ? [] : Set(shots.map(\.id))
                }
                Button("Save…", systemImage: "square.and.arrow.down") { saving = shots.filter { selected.contains($0.id) } }
                    .disabled(selected.isEmpty)
                if !isLive {
                    Button("Delete…", systemImage: "trash", role: .destructive) { confirmDeleteSelected = true }
                        .disabled(selected.isEmpty)
                }
                Button("Done") { selecting = false; selected = [] }
                    .keyboardShortcut(.cancelAction)
            } else {
                if !shots.isEmpty {
                    Button("Select") { selecting = true }
                        .help("Pick screenshots to save or delete")
                    Button("Save All…", systemImage: "square.and.arrow.down") { saving = shots }
                        .help("Save every screenshot to a folder")
                }
                if !isLive {
                    Button("Add Images…", systemImage: "plus") { addingImages = true }
                        .help("Add screenshots or other images to this meeting")
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
#endif
