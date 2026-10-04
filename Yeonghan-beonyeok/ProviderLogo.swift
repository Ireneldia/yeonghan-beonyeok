import SwiftUI

// Official assets, preserved without redrawing:
// Claude: https://claude.ai/favicon.svg
// Ollama: https://github.com/ollama/ollama/blob/main/docs/ollama-logo.svg
// Codex / OpenAI knot: https://openai.com/brand/ — ChatGPT 26.930.21537's
// Contents/Resources/chatgptTemplate.png and chatgptTemplate@2x.png (menu-bar glyphs).
struct ProviderLogo: View {
    let provider: TranslationProvider

    var body: some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
    }

    private var assetName: String {
        switch provider {
        case .codex: "ProviderCodex"
        case .claude: "ProviderClaude"
        case .local: "ProviderOllama"
        }
    }
}
