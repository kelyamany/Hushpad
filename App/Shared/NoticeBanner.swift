import HushpadKit
import HushpadUI
import SwiftUI

extension View {
    /// Shows `model.notice` as a banner at the top of the window.
    func noticeBanner() -> some View { modifier(NoticeBannerModifier()) }
}

private struct NoticeBannerModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = model.notice {
                    NoticeBanner(notice: notice) { model.notice = nil }
                        .padding(Space.m)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: notice.id) {
                            // Plain information goes away by itself; anything with an action waits for you.
                            guard notice.action == nil || notice.action == .undoScreenshotDelete else { return }
                            try? await Task.sleep(for: .seconds(9))
                            if model.notice?.id == notice.id { model.notice = nil }
                        }
                }
            }
            .animation(Motion.smooth, value: model.notice?.id)
    }
}

private struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    let notice: AppModel.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text(notice.text)
                .font(.small)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            switch notice.action {
            case .permission(let permission)?:
                Button("Open Settings") {
                    Permissions.openSettings(for: permission)
                    dismiss()
                }
                .fontWeight(.semibold)
            case .settings?:
                #if os(macOS)
                SettingsLink { Text("Open Settings") }.fontWeight(.semibold).simultaneousGesture(TapGesture().onEnded(dismiss))
                #else
                Button("Open Settings") {
                    model.showSettings = true
                    dismiss()
                }
                .fontWeight(.semibold)
                #endif
            case .undoScreenshotDelete?:
                Button("Undo") {
                    model.undoScreenshotDelete()
                    dismiss()
                }
                .fontWeight(.semibold)
            case nil:
                EmptyView()
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: Radius.shape(Radius.m))
        .overlay(Radius.shape(Radius.m).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
    }
}
