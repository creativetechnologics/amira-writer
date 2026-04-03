import Foundation
import Network
import ProjectKit

@main
struct SyncTest {
    static func main() async {
        let defaultProjectPath = ProjectServerRegistry.defaultProjectsRootURL()
            .appendingPathComponent("Amira.owp", isDirectory: true)
            .path
        let projectPath = CommandLine.arguments.dropFirst().first ?? defaultProjectPath
        let projectURL = URL(fileURLWithPath: projectPath)
        
        print("--- Project Sync Test ---")
        print("Project Path: \(projectURL.path)")
        
        guard let token = ProjectServiceConfiguration.loadAuthToken(), !token.isEmpty else {
            print("❌ ERROR: Missing Auth Token in ProjectServiceConfiguration")
            exit(1)
        }
        print("✅ Found Auth Token (Length: \(token.count))")
        
        // 1. Manually try to connect to GaryServer.local:19847
        print("\n--- Testing Explicit Endpoint 127.0.0.1:19847 ---")
        let hostEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 19847)
        let manualClient = ProjectRemoteClient.connect(
            endpoint: hostEndpoint,
            projectURL: projectURL,
            authToken: token
        )
        
        do {
            print("Pinging...")
            try await manualClient.pingServer()
            print("✅ Explicit ping succeeded!")
            
            print("Ensuring current index (checking DB lock)...")
            try await manualClient.ensureCurrentIndex() 
            print("✅ Ensure index succeeded!")
            
            let summary = try await manualClient.summarizeProjectAssets()
            print("✅ Summarized Assets: \(summary.assetCount) files, \(summary.totalBytes) bytes")
        } catch {
            print("❌ Explicit connection failed: \(error)")
        }
        
        // 2. Test Discovery
        print("\n--- Testing ProjectRemoteClient.discover ---")
        do {
            let discoveredClient = try await ProjectRemoteClient.discover(projectURL: projectURL)
            print("✅ Discovery succeeded!")
            let summary = try await discoveredClient.summarizeProjectAssets()
            print("✅ Summarized Assets: \(summary.assetCount) files, \(summary.totalBytes) bytes")
        } catch {
            print("❌ Discovery failed: \(error)")
        }
        
        print("\n--- Test Complete ---")
    }
}
