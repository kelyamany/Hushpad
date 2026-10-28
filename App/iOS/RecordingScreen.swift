#if os(iOS)
import HushpadKit
import HushpadUI
import SwiftUI

/// Full-screen while recording: big timer, live waveform, your own notes, camera for slides.
/// Swipe down (or the chevron) to minimise; recording continues and a bar shows on the home screen.
struct RecordingScreen: View {
    /// The big timer grows with the user's text size.
    @ScaledMetric(relativeTo: .largeTitle) private var timerScale = 1.0
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onFinish: (UUID) -> Void

    @State private var title = ""
    @State private var showCamera = false
    @State private var stopping = false
    @FocusState private var focus: Field?

    private enum Field { case title, notes }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: focus == .notes ? Space.m : Space.xl) {
                    TextField("Title", text: $title)
                        .font(.displaySmall)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .focused($focus, equals: .title)
                        .submitLabel(.done)
                        .onSubmit { model.renameLiveRecording(title) }
                        .padding(.top, Space.s)

                    if let start = model.recordingStartedAt {
                        ElapsedTime(since: start)
                            .font(.system(size: (focus == .notes ? 34 : 64) * timerScale, weight: .light, design: .rounded))
                            .foregroundStyle(Theme.ink)
                    }

                    LiveWaveform(bars: 40, color: Theme.record) { model.session?.micLevel ?? 0 }
                        .frame(height: focus == .notes ? 34 : 88)
                        .padding(.horizontal, 8)

                    if focus != .notes, model.settings.liveTranscript {
                        LiveTranscriptView(transcript: model.session?.live?.transcript, paused: model.isPaused)
                            .frame(height: 170)
                            .background(Theme.paperRaised, in: Radius.shape(Radius.l))
                            .overlay { Radius.shape(Radius.l).strokeBorder(Theme.hairline) }
                            .accessibilityLabel("Live captions")
                    }

                    notesCard(text: $model.liveNotes)

                    if model.livePhotoCount > 0 {
                        Label(model.livePhotoCount == 1 ? "1 photo" : "\(model.livePhotoCount) photos", systemImage: "photo.on.rectangle")
                            .font(.label.weight(.medium))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                .padding(.horizontal, Space.l + Space.xs)
                .padding(.bottom, Space.xl)
                .animation(.smooth, value: focus)
            }
            .scrollDismissesKeyboard(.interactively)

            if focus == nil {
                VStack(spacing: 8) {
                    RecordButton(isRecording: true, diameter: 80) { stop() }
                        .disabled(stopping)
                    Text("Tap to stop").font(.label).foregroundStyle(Theme.inkSecondary)
                }
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .paperBackground()
        .onAppear { title = model.session?.recording.title ?? "" }
        .onChange(of: focus) { old, _ in if old == .title { model.renameLiveRecording(title) } }
        .onChange(of: model.isRecording) { _, recording in
            // Stopped from the Lock Screen or Dynamic Island.
            if !recording && !stopping { dismiss() }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { model.addPhoto($0) }.ignoresSafeArea()
        }
        .toolbar {
            // The big Stop button makes way for the keyboard, so Stop moves up here: always one tap away.
            ToolbarItemGroup(placement: .keyboard) {
                Button { stop() } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
                .tint(Theme.record)
                .disabled(stopping)
                Spacer()
                Button("Done") { focus = nil }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.base.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Minimise")
            Spacer()
            StatusPill(.recording)
            Spacer()
            Button { showCamera = true } label: {
                Image(systemName: "camera").font(.base.weight(.semibold)).frame(width: 44, height: 44)
            }
            .opacity(cameraAvailable ? 1 : 0)
            .disabled(!cameraAvailable)
            .accessibilityHidden(!cameraAvailable)
            .accessibilityLabel("Take a photo of the slides")
        }
        .padding(.horizontal, 8)
    }

    private func notesCard(text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Your notes")
                .font(.small.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("Jot down what matters. Your notes are kept with the transcript.")
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.top, Space.s)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .focused($focus, equals: .notes)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: focus == .notes ? 220 : 130)
            }
        }
        .card()
    }

    private var cameraAvailable: Bool { model.settings.screenshotMode != .off && CameraPicker.isAvailable }

    private func stop() {
        stopping = true
        focus = nil
        Task {
            let finished = await model.stopRecording()
            if let finished { onFinish(finished.id) } else { dismiss() }
        }
    }
}
#endif
