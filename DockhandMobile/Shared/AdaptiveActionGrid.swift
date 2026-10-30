import SwiftUI

/// Lays out action buttons in a single row when the measured width fits them all,
/// otherwise in a fixed number of columns. Driven by the real width, not the size
/// class, so split columns and iPhone Duo panes get the right layout.
struct AdaptiveActionGrid<Content: View>: View {
    let itemCount: Int
    var minimumItemWidth: CGFloat = 100
    var compactColumns = 3
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    @State private var width: CGFloat = 0

    private var columnCount: Int {
        guard width > 0 else { return compactColumns }
        let fitting = Int((width + spacing) / (minimumItemWidth + spacing))
        return fitting >= itemCount ? itemCount : min(max(fitting, 1), compactColumns)
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount),
            spacing: spacing
        ) {
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
