import PlumKit

if CommandLine.arguments.contains("--print-shader") {
    print(RenderContext.shaderSource)
} else {
    MainActor.assumeIsolated { runApp() }
}
