import Testing

@main
struct GeminiWhisperCoreTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
