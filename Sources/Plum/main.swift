import PlumKit

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--terminal-host"), arguments.indices.contains(flag + 1) {
    TerminalHost.run(socketPath: arguments[flag + 1])
} else if arguments.contains("--print-shader") {
    print(RenderContext.shaderSource)
} else {
    MainActor.assumeIsolated { runApp() }
}
