#if os(macOS)
import ScoreUI

@main
@available(macOS 26.0, *)
struct ScoreMain {
    @MainActor
    static func main() {
        ScoreBootstrap.main()
    }
}

#elseif os(iOS)
import ScoreUI

@main
@available(iOS 26.0, *)
struct ScoreMain {
    @MainActor
    static func main() {
        ScoreBootstrap.main()
    }
}
#endif
