import SwiftTerm
import SwiftUI
import UIKit

struct SwiftTermContainerView: UIViewRepresentable {
    var feedEvent: TerminalFeedEvent?
    var fontSize: CGFloat
    var onInput: (String) -> Void
    var onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeUIView(context: Context) -> TerminalView {
        let terminalView = TerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        )
        terminalView.terminalDelegate = context.coordinator
        terminalView.backgroundColor = .black
        terminalView.autocorrectionType = .no
        terminalView.autocapitalizationType = .none
        terminalView.smartQuotesType = .no
        terminalView.smartDashesType = .no
        context.coordinator.terminalView = terminalView
        return terminalView
    }

    func updateUIView(_ terminalView: TerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize

        let desiredFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if terminalView.font.pointSize != desiredFont.pointSize {
            terminalView.font = desiredFont
        }

        if let feedEvent, context.coordinator.lastFeedID != feedEvent.id {
            context.coordinator.lastFeedID = feedEvent.id
            terminalView.feed(text: feedEvent.text)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        weak var terminalView: TerminalView?
        var lastFeedID: UUID?
        var onInput: (String) -> Void
        var onResize: (Int, Int) -> Void

        init(onInput: @escaping (String) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(String(decoding: data, as: UTF8.self))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            Task { @MainActor in
                UIApplication.shared.open(url)
            }
        }

        func bell(source: TerminalView) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
        }

        func clipboardRead(source: TerminalView) -> Data? {
            UIPasteboard.general.string?.data(using: .utf8)
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
