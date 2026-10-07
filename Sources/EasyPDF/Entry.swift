import Foundation

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
        #if DEBUG
        if CommandLine.arguments.contains("--snapshot") {
            MainActor.assumeIsolated { Snapshot.run(arguments: CommandLine.arguments) }
        }
        if CommandLine.arguments.contains("--uitest") {
            MainActor.assumeIsolated { UITest.run(arguments: CommandLine.arguments) }
        }
        #endif
        EasyPDFApp.main()
    }
}
