import SwiftUI

@available(macOS 26.0, *)
struct AnimatePageView: View {
    @Bindable var store: AnimateStore

    var body: some View {
        VStack(spacing: 0) {
            CanvasRepresentable(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            TransportBar(store: store)
        }
    }
}
