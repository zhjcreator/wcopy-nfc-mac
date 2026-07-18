import Darwin
import Foundation
import SwiftUI

let processArguments = Array(CommandLine.arguments.dropFirst())
let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let directCLI = executableName == "wcopy-nfc"

if directCLI || processArguments.first == "cli" {
    let cliArguments = directCLI ? processArguments : Array(processArguments.dropFirst())
    Darwin.signal(SIGINT, SIG_IGN)
    Darwin.signal(SIGTERM, SIG_IGN)
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    interruptSource.setEventHandler { WCopyCLI.cancel() }
    terminateSource.setEventHandler { WCopyCLI.cancel() }
    interruptSource.resume()
    terminateSource.resume()
    DispatchQueue.global(qos: .userInitiated).async {
        let status = WCopyCLI.run(arguments: cliArguments)
        DispatchQueue.main.async { exit(status) }
    }
    RunLoop.main.run()
} else {
    WCopyNFCMacApp.main()
}
