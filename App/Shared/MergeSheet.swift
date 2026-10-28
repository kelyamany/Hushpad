import HushpadKit
import HushpadUI
import SwiftUI

/// "Merge With…": pick the other meeting, choose which comes first, name the result.
struct MergeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let start: Recording
    var onMerged: (Recording) -> Void = { _ in }

    @State private var otherID: UUID?
    @State private var startIsFirst = true
    @State private var title = ""
    @State private var titleEdited = false
    @State private var deleteOriginals = false
    @State private var merging = false
    @State private var failure: String?
    /// Counted when the pair changes, not while rendering (it reads the disk).
    @State private var shotCount = 0

    private var other: Recording? { model.recordings.first { $0.id == otherID } }
    private var first: Recording? { startIsFirst ? start : other }
    private var second: Recording? { startIsFirst ? other : start }

    /// Closest in time first: a meeting split in two is usually recorded minutes apart.
    private var candidates: [Recording] {
        model.recordings
            .filter { $0.id != start.id && model.canMerge($0) }
            .sorted { abs($0.createdAt.timeIntervalSince(start.createdAt)) < abs($1.createdAt.timeIntervalSince(start.createdAt)) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if candidates.isEmpty {
                        Text("There's no other meeting to merge with yet.").foregroundStyle(.secondary)
                    }
                    Picker("Merge with", selection: $otherID) {
                        Text("Choose a meeting…").tag(UUID?.none)
                        ForEach(candidates) { recording in
                            Text("\(recording.title) · \(recording.createdAt.formatted(.dateTime.day().month().hour().minute()))")
                                .tag(Optional(recording.id))
                        }
                    }
                    #if os(iOS)
                    .pickerStyle(.navigationLink)
                    #endif
                }

                if let first, let second {
                    Section {
                        PartRow(number: 1, recording: first)
                        Button {
                            withAnimation(.smooth) { startIsFirst.toggle() }
                        } label: {
                            Label("Swap Order", systemImage: "arrow.up.arrow.down")
                        }
                        PartRow(number: 2, recording: second)
                    } header: {
                        Text("Order")
                    } footer: {
                        Text("The second meeting continues right where the first one ends.")
                    }

                    Section {
                        TextField("Title", text: Binding(get: { title }, set: { title = $0; titleEdited = true }))
                        Toggle("Delete the two originals afterwards", isOn: $deleteOriginals)
                    } header: {
                        Text("Merged meeting")
                    } footer: {
                        Text(deleteOriginals
                             ? "The originals will be deleted\(model.libraryIsCustom ? " on all your devices" : "") once the merge succeeds."
                             : "The originals are kept, so you can compare or delete them later.")
                    }

                    Section("What gets merged") {
                        summary(first, second)
                    }
                    if let failure {
                        Section { InlineBanner("Couldn't merge these meetings", detail: failure) { merge() } }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Merge Meetings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if merging {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Merge") { merge() }.disabled(other == nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onChange(of: otherID) {
                updateTitle()
                shotCount = [start, other].compactMap { $0 }.map { model.screenshots(for: $0).count }.reduce(0, +)
            }
            .onChange(of: startIsFirst) { updateTitle() }
            .interactiveDismissDisabled(merging)
        }
        #if os(macOS)
        .frame(width: 520, height: 600)
        #endif
    }

    @ViewBuilder private func summary(_ first: Recording, _ second: Recording) -> some View {
        let audio = [first, second].filter(\.hasAudio)
        if !audio.isEmpty {
            Label("Audio: \(first.durationText.isEmpty ? "–" : first.durationText) + \(second.durationText.isEmpty ? "–" : second.durationText)",
                  systemImage: "waveform")
        }
        Label("Transcripts joined; people with the same name become one speaker", systemImage: "text.bubble")
        Label("Your notes and meeting notes combined, one section per part", systemImage: "note.text")
        let shots = shotCount
        if shots > 0 { Label("\(shots) screenshot\(shots == 1 ? "" : "s") kept in place", systemImage: "photo.on.rectangle") }
        #if os(macOS)
        Label("Tip: regenerate notes afterwards for one combined summary", systemImage: "sparkles").foregroundStyle(.secondary)
        #endif
    }

    private func updateTitle() {
        guard !titleEdited, let first, let second else { return }
        title = first.title == second.title ? first.title : "\(first.title) + \(second.title)"
    }

    private func merge() {
        guard let first, let second else { return }
        merging = true
        failure = nil
        Task {
            let merged = await model.merge(first: first, second: second,
                                           title: title.trimmingCharacters(in: .whitespaces), deleteOriginals: deleteOriginals)
            merging = false
            if let merged {
                dismiss()
                onMerged(merged)
            } else {
                failure = model.errorMessage
                model.errorMessage = nil
            }
        }
    }
}

private struct PartRow: View {
    @Environment(AppModel.self) private var model
    let number: Int
    let recording: Recording

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.base.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).font(.base.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    SourceBadge(source: recording.source)
                    Text(recording.createdAt, format: .dateTime.weekday().day().month().hour().minute())
                    if !recording.durationText.isEmpty { Text("· \(recording.durationText)") }
                }
                .font(.label)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
