import AppKit
import SwiftUI

/// The About window (app menu → About StudyO Player).
enum AboutPanel {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView().environmentObject(Lang.shared))
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.isRestorable = false // never reopen where it was last time
            window = w
        }
        // Size to the content first, then centre: otherwise the position is worked out for an
        // empty window and it lands off-centre.
        if let w = window, let content = w.contentView {
            content.layoutSubtreeIfNeeded()
            w.setContentSize(content.fittingSize)
            w.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AboutView: View {
    @EnvironmentObject var lang: Lang

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 34) { // icon centred on the text, so neither end looks heavier
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 172, height: 172)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Text("MT TECHNOLOGIES")
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(1.6)
                        .foregroundStyle(.secondary)
                    Text("by Mohamed Talaat")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                
                Text("StudyO Player")
                    .font(.system(size: 28, weight: .regular))
                    .padding(.top, 14)
                
                Text(L("Version") + " " + version + "  ·  " + L("Free Edition"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                Spacer().frame(height: 22)

                // تنسيق حقوق الملكية على الشمال تماماً وتحت بعض (زي تصميم أبل بالضبط)
                VStack(alignment: .leading, spacing: 4) {
                    Text("© 2026 MT Technologies. " + L("All rights reserved."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    
                    Text(L("StudyO Player collects no data."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Spacer()
                    Button(L("Contact Support…")) { AppInfo.contactSupport() }
                }
                .controlSize(.regular)
                .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 40)
        .padding(.trailing, 26)
        // The title bar already adds about 28 pt above the content, so the top padding is smaller
        // than the bottom one: the space above and below the content then looks the same.
        .padding(.top, 8)
        .padding(.bottom, 34)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true) // as tall as the content, no empty gap
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .environment(\.layoutDirection, lang.direction)
    }
}

/// Put in a window's content to centre that window on screen each time it appears.
struct CenterWindowOnAppear: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isRestorable = false
            // After layout, so the final size is known.
            DispatchQueue.main.async { window.center() }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}
