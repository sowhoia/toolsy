import SwiftUI

extension View {
    /// Names this view for the debug script (`--script`), which clicks it by sending mouse events
    /// to the panel window. Release builds compile it away.
    func debugAnchor(_ name: @autoclosure () -> String) -> some View {
        #if DEBUG
        modifier(DebugAnchorModifier(name: name()))
        #else
        self
        #endif
    }
}

#if DEBUG
/// Frames of the named views, in the coordinates of the panel's hosting view (top-left origin).
enum DebugAnchors {
    /// Only a scripted run records anything; a normal debug run pays nothing.
    static var isRecording = false
    /// Every view on screen under each name, in the order they appeared, with its latest frame.
    /// During a page transition both pages are on screen and both keep reporting; the newer one wins.
    static var entries: [String: [(owner: UUID, frame: CGRect)]] = [:]

    static func frame(_ name: String) -> CGRect? {
        entries[name]?.last?.frame
    }

    static func report(_ name: String, owner: UUID, frame: CGRect) {
        var list = entries[name, default: []]
        if let index = list.firstIndex(where: { $0.owner == owner }) {
            list[index].frame = frame
        } else {
            list.append((owner, frame))
        }
        entries[name] = list
    }

    static func remove(_ name: String, owner: UUID) {
        entries[name]?.removeAll { $0.owner == owner }
        if entries[name]?.isEmpty == true { entries[name] = nil }
    }
}

private struct DebugAnchorModifier: ViewModifier {
    let name: String
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        if DebugAnchors.isRecording {
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                    DebugAnchors.report(name, owner: owner, frame: $0)
                }
                .onDisappear { DebugAnchors.remove(name, owner: owner) }
        } else {
            content
        }
    }
}
#endif
