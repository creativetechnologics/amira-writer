#if os(macOS)
import NovotroScoreUI

@main
@available(macOS 26.0, *)
struct NovotroScoreMain {
    @MainActor
    static func main() {
        NovotroScoreBootstrap.main()
    }
}

#elseif os(iOS)
import NovotroScoreUI

@main
@available(iOS 26.0, *)
struct NovotroScoreMain {
    @MainActor
    static func main() {
        NovotroScoreBootstrap.main()
    }
}
#endif
