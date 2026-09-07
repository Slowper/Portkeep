import SwiftUI

enum ProjectKind: String, Sendable, CaseIterable {
    case next, nuxt, vite, astro, remix, sveltekit, node
    case rust, go, python, ruby, swift, php, java, elixir, dotnet
    case generic

    var label: String {
        switch self {
        case .next: "Next.js"
        case .nuxt: "Nuxt"
        case .vite: "Vite"
        case .astro: "Astro"
        case .remix: "Remix"
        case .sveltekit: "SvelteKit"
        case .node: "Node"
        case .rust: "Rust"
        case .go: "Go"
        case .python: "Python"
        case .ruby: "Ruby"
        case .swift: "Swift"
        case .php: "PHP"
        case .java: "JVM"
        case .elixir: "Elixir"
        case .dotnet: ".NET"
        case .generic: "Project"
        }
    }

    var symbol: String {
        switch self {
        case .next: "n.square.fill"
        case .nuxt: "triangle.fill"
        case .remix: "music.note"
        case .astro: "sparkles"
        case .sveltekit: "s.square.fill"
        case .vite: "bolt.fill"
        case .node: "hexagon.fill"
        case .rust: "gearshape.2.fill"
        case .go: "hare.fill"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .ruby: "diamond.fill"
        case .swift: "swift"
        case .php: "curlybraces"
        case .java: "cup.and.saucer.fill"
        case .elixir: "drop.fill"
        case .dotnet: "number"
        case .generic: "folder.fill"
        }
    }

    /// Brand-adjacent accent used for the project icon tile.
    var tint: Color {
        switch self {
        case .next: Color(red: 0.16, green: 0.16, blue: 0.18)
        case .nuxt: Color(red: 0.00, green: 0.86, blue: 0.51)
        case .vite: Color(red: 0.57, green: 0.36, blue: 1.00)
        case .astro: Color(red: 1.00, green: 0.36, blue: 0.24)
        case .remix: Color(red: 0.25, green: 0.51, blue: 0.96)
        case .sveltekit: Color(red: 1.00, green: 0.24, blue: 0.00)
        case .node: Color(red: 0.31, green: 0.63, blue: 0.31)
        case .rust: Color(red: 0.87, green: 0.46, blue: 0.22)
        case .go: Color(red: 0.00, green: 0.68, blue: 0.85)
        case .python: Color(red: 0.22, green: 0.44, blue: 0.69)
        case .ruby: Color(red: 0.80, green: 0.10, blue: 0.13)
        case .swift: Color(red: 0.94, green: 0.32, blue: 0.20)
        case .php: Color(red: 0.47, green: 0.48, blue: 0.70)
        case .java: Color(red: 0.93, green: 0.45, blue: 0.13)
        case .elixir: Color(red: 0.43, green: 0.24, blue: 0.56)
        case .dotnet: Color(red: 0.32, green: 0.20, blue: 0.75)
        case .generic: Color(red: 0.55, green: 0.55, blue: 0.60)
        }
    }

    /// Process names that plausibly serve this kind of project. Used so a
    /// stray `ollama` started from a Next.js folder isn't shown as that app.
    var runtimeNames: [String] {
        switch self {
        case .next, .nuxt, .vite, .astro, .remix, .sveltekit, .node:
            ["node", "bun", "deno", "next-server", "npm", "pnpm", "yarn", "vite", "esbuild", "tsx", "ts-node", "nodemon", "turbo", "webpack", "nuxt", "astro", "remix"]
        case .rust: ["cargo", "cargo-watch", "trunk", "bacon"]
        case .go: ["go", "air", "gow", "reflex"]
        case .python: ["python", "python3", "uvicorn", "gunicorn", "flask", "django", "fastapi", "streamlit", "hypercorn", "daphne"]
        case .ruby: ["ruby", "puma", "rails", "unicorn", "falcon", "jekyll"]
        case .swift: ["swift", "swift-frontend", "vapor"]
        case .php: ["php", "php-fpm", "artisan", "caddy", "frankenphp"]
        case .java: ["java", "gradle", "kotlin", "mvn"]
        case .elixir: ["beam.smp", "beam", "erl", "mix", "elixir"]
        case .dotnet: ["dotnet"]
        case .generic: []
        }
    }

    static var allRuntimeNames: Set<String> {
        Set(allCases.flatMap(\.runtimeNames))
    }
}

struct ProjectInfo: Hashable, Sendable {
    let directory: URL
    let name: String
    let kind: ProjectKind

    var abbreviatedPath: String {
        (directory.path as NSString).abbreviatingWithTildeInPath
    }
}
