import SwiftUI

/// The production mail interaction wiring, also hosted without launch UI in tests.
struct MailLinkPresentation: ViewModifier {
    let appState: AppState
    @State private var displayedChoice: AppState.PendingMailLink?
    @State private var choiceIsPresented = false

    func body(content: Content) -> some View {
        let choice = displayedChoice
        content.sheet(isPresented: Binding(
            get: { !appState.isLocked && choiceIsPresented },
            set: { shown in
                guard !shown, let choice, displayedChoice?.id == choice.id else { return }
                choiceIsPresented = false
                appState.cancelMailLink(choice.id)
            }
        ), onDismiss: {
            // Retain the old identity until native dismissal finishes. A yield
            // can merge hide/show into one update and cancel the next request.
            guard let choice, displayedChoice?.id == choice.id else { return }
            choiceIsPresented = false
            displayedChoice = nil
            showPendingChoice()
        }) {
            if !appState.isLocked, let choice {
                MailServiceChooser(request: choice).environment(appState)
            }
        }
        .onChange(of: appState.pendingMailLink?.id, initial: true) {
            if let displayedChoice {
                if displayedChoice.id != appState.pendingMailLink?.id {
                    choiceIsPresented = false
                }
            } else {
                showPendingChoice()
            }
        }
        .modifier(MailLinkErrorPresentation(appState: appState))
        .modifier(MailHandlerApprovalPresentation(appState: appState))
    }

    private func showPendingChoice() {
        guard displayedChoice == nil, !appState.isLocked,
              let choice = appState.pendingMailLink else { return }
        displayedChoice = choice
        choiceIsPresented = true
    }
}

/// Keeps the displayed error separate from the next queued interaction, so
/// SwiftUI can close one alert before presenting another.
struct MailLinkErrorPresentation: ViewModifier {
    let appState: AppState
    @State private var displayedError: AppState.MailLinkError?

    func body(content: Content) -> some View {
        let error = displayedError
        content.alert(
            "Mail link unavailable",
            isPresented: Binding(
                get: { !appState.isLocked && displayedError != nil },
                set: { shown in
                    guard !shown, let error, displayedError?.id == error.id else { return }
                    displayedError = nil
                    appState.dismissMailLinkError(error.id)
                }
            ),
            presenting: error
        ) { _ in
            // The presentation binding is the only completion path, including
            // Return/Escape. Its captured identity makes late delivery harmless.
            Button("OK", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { error in
            Text(error.message)
        }
        .task(id: appState.mailLinkError?.id) {
            displayedError = nil
            // Give the dismissed presentation a separate SwiftUI update before
            // making the next error visible, even when its message is identical.
            await Task.yield()
            guard !Task.isCancelled else { return }
            displayedError = appState.mailLinkError
        }
    }
}

private struct MailHandlerApprovalPresentation: ViewModifier {
    let appState: AppState
    @State private var displayed: AppState.MailHandlerApproval?

    func body(content: Content) -> some View {
        let approval = displayed
        content.alert("Use this service for mail links?", isPresented: Binding(
            get: { !appState.isLocked && displayed != nil },
            set: { shown in
                guard !shown, let approval, displayed?.id == approval.id else { return }
                displayed = nil
                appState.answerMailHandlerApproval(approval.id, allow: false)
            }
        ), presenting: approval) { approval in
            Button("Allow") { appState.answerMailHandlerApproval(approval.id, allow: true) }
            Button("Not now", role: .cancel) { appState.answerMailHandlerApproval(approval.id, allow: false) }
        } message: { approval in
            let path = URL(string: approval.handler.template.replacingOccurrences(of: "%s", with: "mail"))?.path ?? ""
            Text("\(approval.serviceLabel) wants to open mail drafts at \(approval.handler.declaringOrigin)\(path).")
        }
        .task(id: appState.pendingMailHandlerApproval?.id) {
            displayed = nil
            await Task.yield()
            guard !Task.isCancelled else { return }
            displayed = appState.pendingMailHandlerApproval
        }
    }
}

private struct MailServiceChooser: View {
    @Environment(AppState.self) private var appState
    let request: AppState.PendingMailLink

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Write email with")
                .font(.headline)
            Text("Choose the signed-in service that should open this draft.")
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(request.candidates) { candidate in
                    Button {
                        appState.chooseMailService(candidate.serviceID, requestID: request.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.label)
                                if !candidate.chooserSubtitle.isEmpty {
                                    Text(candidate.chooserSubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(candidate.chooserSubtitle.isEmpty
                        ? candidate.label
                        : "\(candidate.label), \(candidate.chooserSubtitle)")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    appState.cancelMailLink(request.id)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
