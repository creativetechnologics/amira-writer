import SwiftUI

@available(macOS 26.0, *)
struct TimelinePageView: View {
    @Bindable var store: AnimateStore

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(store: store)

            Divider()

            TimelineRepresentable(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
