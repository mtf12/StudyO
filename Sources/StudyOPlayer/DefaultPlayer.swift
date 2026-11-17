import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Making StudyO the app that opens video files when they are double-clicked in Finder.
enum DefaultPlayer {
    /// The three most common video formats only. Since macOS 26.4 the user confirms each format
    /// in its own system prompt, so the list is kept short: three prompts, not fifteen.
    /// Other formats still open in StudyO through "Open With" or drag and drop.
    private static let extensions = ["mp4", "mkv", "mov"]

    /// The system type of each format, without repeats ("mpg" and "mpeg" are one type).
    private static var types: [UTType] {
        var seen = Set<String>()
        return extensions.compactMap { UTType(filenameExtension: $0) }.filter { seen.insert($0.identifier).inserted }
    }

    /// True when StudyO already opens the common formats (MP4, MOV and MKV).
    static var isDefault: Bool {
        let me = Bundle.main.bundleURL.standardizedFileURL
        return ["mp4", "mov", "mkv"].allSatisfy { ext in
            UTType(filenameExtension: ext).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }?
                .standardizedFileURL == me
        }
    }

    /// Asks macOS to open every video format with StudyO. Formats StudyO already opens are skipped,
    /// so nobody is asked twice. `progress(done, total)` reports each step while macOS asks the user
    /// to confirm the formats one by one. Returns false if any format was refused.
    @MainActor static func makeDefault(progress: (Int, Int) -> Void = { _, _ in }) async -> Bool {
        let me = Bundle.main.bundleURL.standardizedFileURL
        let pending = types.filter { NSWorkspace.shared.urlForApplication(toOpen: $0)?.standardizedFileURL != me }
        var ok = true
        for (i, type) in pending.enumerated() {
            progress(i + 1, pending.count)
            // Waits for the user's answer in macOS's confirmation window before asking about the next format.
            let error: Error? = await withCheckedContinuation { done in
                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { done.resume(returning: $0) }
            }
            if error != nil { ok = false }
        }
        return ok
    }
}

/// A small notch that drops from the top of the window once, right after the welcome tour,
/// and asks whether StudyO should open videos by default. Never shown again once answered.
struct DefaultPlayerPrompt: View {
    @EnvironmentObject var lang: Lang
    @AppStorage("onboardingDone") private var onboardingDone = false
    @AppStorage("defaultPlayerAsked") private var asked = false
    @State private var shown = false
    @State private var working = false
    @State private var result: String?
    @State private var step: (done: Int, total: Int)?

    var body: some View {
        ZStack {
            if shown {
                notch.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: shown)
        .animation(Theme.spring, value: result)
        .task(id: onboardingDone) { await showIfNeeded() }
    }

    private var notch: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 26, height: 26)
            if let result {
                Text(result).font(.system(size: 12.5, weight: .medium))
            } else if let step {
                // macOS shows its own confirmation for each format; this says why, and how far along.
                ProgressView().controlSize(.small)
                Text(String(format: L("Confirm each format in the macOS window (%d of %d)"), step.done, step.total))
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
            } else {
                Text(L("Open videos with StudyO by default?"))
                    .font(.system(size: 12.5, weight: .medium))
                Button(L("Not Now")) { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .disabled(working)
                Button {
                    Task { await accept() }
                } label: {
                    Text(L("Make Default"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 5)
                        .background(Theme.accentGradient, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(working)
            }
        }
        // Wider, not taller: roomier sides and gaps, same height.
        .padding(.leading, 14).padding(.trailing, 14).padding(.vertical, 7)
        .glassPanel(cornerRadius: 22)
        .environment(\.layoutDirection, lang.direction)
        .padding(.top, 8)
    }

    /// Only after the tour, only once, and not when StudyO is already the default.
    private func showIfNeeded() async {
        guard onboardingDone, !asked, !shown else { return }
        try? await Task.sleep(nanoseconds: 700_000_000) // let the tour sheet finish closing
        guard !Task.isCancelled else { return }
        if DefaultPlayer.isDefault { asked = true } else { shown = true }
    }

    private func accept() async {
        working = true
        let ok = await DefaultPlayer.makeDefault { done, total in step = (done, total) }
        working = false
        step = nil
        result = ok ? L("StudyO now opens your videos.") : L("Some formats could not be changed. Try again from Settings.")
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        finish()
    }

    private func finish() {
        asked = true
        shown = false
    }
}

/// The same choice in Settings → General, for anyone who said "Not Now".
struct DefaultPlayerRow: View {
    @State private var isDefault = DefaultPlayer.isDefault
    @State private var working = false

    var body: some View {
        LabeledContent(L("Default video player")) {
            if isDefault {
                Label(L("StudyO"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button(L("Make Default")) {
                    working = true
                    Task {
                        _ = await DefaultPlayer.makeDefault()
                        isDefault = DefaultPlayer.isDefault
                        working = false
                    }
                }
                .disabled(working)
            }
        }
    }
}
