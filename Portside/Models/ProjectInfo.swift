import Foundation

enum ProjectKind: String, Sendable, CaseIterable {
    case next, nuxt, vite, astro, remix, node
    case rust, go, python, ruby, swift, php, java, elixir, dotnet
    case generic

    var label: String {
        switch self {
        case .next: "Next.js"
        case .nuxt: "Nuxt"
        case .vite: "Vite"
        case .astro: "Astro"
        case .remix: "Remix"
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
        case .next, .nuxt, .remix, .astro: "globe"
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
}

struct ProjectInfo: Hashable, Sendable {
    let directory: URL
    let name: String
    let kind: ProjectKind
}
