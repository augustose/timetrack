import Cocoa
import SwiftUI

/// Small floating About panel: version, author, blog and license.
enum AboutWindow {
    private static var window: NSWindow?

    static let blogURL = "https://augustose.web.app"
    static let email = "augustose@senet.ca"

    static func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: AboutView())
        let size = hosting.fittingSize
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About \(appName)"
        win.contentView = hosting
        win.isReleasedWhenClosed = false
        win.center()
        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TimeTrackBar"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text(AboutWindow.appName)
                .font(.title2.bold())
            Text("Version \(AboutWindow.version)")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Made with love, for everyone, for free.\nBecause good tools should just exist.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)

            Text("MIT licensed — free for everyone, forever.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 14) {
                Link("Blog", destination: URL(string: AboutWindow.blogURL)!)
                Link(AboutWindow.email, destination: URL(string: "mailto:\(AboutWindow.email)")!)
            }
            .font(.system(size: 12))
        }
        .padding(24)
        .frame(width: 300)
    }
}
