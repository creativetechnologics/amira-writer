import Foundation

enum ProjectAsyncTimeout {
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        description: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds > 0 else {
            return try await operation()
        }

        let timeoutNanoseconds = UInt64(seconds * 1_000_000_000)

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ProjectRemoteClientError.operationTimedOut(description)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

typealias NovotroProjectAsyncTimeout = ProjectAsyncTimeout
