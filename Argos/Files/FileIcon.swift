//
//  FileIcon.swift
//  Argos
//
//  Icono y color de cada carpeta/archivo del explorador, al estilo de los editores:
//  `src` con llaves, `docs` con un libro, `tests` con un sello, `.github` con una rama…
//  Lógica pura (SF Symbol + tono); la vista solo la pinta.
//

import Foundation

struct FileIcon: Equatable, Sendable {
    /// Tono semántico (la vista lo traduce a `Color`).
    enum Tint: String, Sendable {
        case blue, orange, yellow, green, mint, teal, purple, pink, red, gray, brown, indigo
    }

    let symbol: String
    let tint: Tint

    // MARK: - Carpetas

    private static let folderRules: [(names: Set<String>, icon: FileIcon)] = [
        (["src", "source", "sources", "lib"], FileIcon(symbol: "curlybraces", tint: .blue)),
        (["app", "apps"], FileIcon(symbol: "app.badge", tint: .indigo)),
        (["components", "ui", "widgets"], FileIcon(symbol: "square.stack.3d.up.fill", tint: .teal)),
        (["pages", "views", "screens", "templates", "layouts"], FileIcon(symbol: "rectangle.stack.fill", tint: .purple)),
        (["api", "routes", "server", "backend", "controllers", "handlers"], FileIcon(symbol: "server.rack", tint: .green)),
        (["public", "static", "assets", "images", "img", "media", "icons", "fonts"], FileIcon(symbol: "photo.on.rectangle.angled", tint: .pink)),
        (["docs", "doc", "documentation", "wiki"], FileIcon(symbol: "book.closed.fill", tint: .brown)),
        (["test", "tests", "__tests__", "spec", "specs", "e2e", "cypress", "playwright"], FileIcon(symbol: "checkmark.seal.fill", tint: .green)),
        (["scripts", "bin", "tools", "cli"], FileIcon(symbol: "terminal.fill", tint: .gray)),
        (["config", "configs", "settings", ".config"], FileIcon(symbol: "gearshape.fill", tint: .gray)),
        ([".github", ".gitlab", ".circleci", "workflows"], FileIcon(symbol: "arrow.triangle.branch", tint: .indigo)),
        ([".git"], FileIcon(symbol: "arrow.triangle.branch", tint: .gray)),
        (["node_modules", "vendor", "packages", ".venv", "venv", "Pods"], FileIcon(symbol: "shippingbox.fill", tint: .brown)),
        (["dist", "build", "out", ".next", ".nuxt", "target", "release"], FileIcon(symbol: "hammer.fill", tint: .orange)),
        (["styles", "css", "scss", "theme", "themes"], FileIcon(symbol: "paintpalette.fill", tint: .pink)),
        (["hooks"], FileIcon(symbol: "link", tint: .teal)),
        (["utils", "helpers", "common", "shared", "core"], FileIcon(symbol: "wrench.and.screwdriver.fill", tint: .gray)),
        (["models", "schemas", "types", "entities", "domain", "interfaces"], FileIcon(symbol: "cube.fill", tint: .orange)),
        (["db", "database", "migrations", "prisma", "sql", "seeds"], FileIcon(symbol: "cylinder.split.1x2.fill", tint: .yellow)),
        (["locales", "i18n", "lang", "translations"], FileIcon(symbol: "globe", tint: .blue)),
        (["store", "stores", "state", "redux", "context"], FileIcon(symbol: "tray.full.fill", tint: .purple)),
        (["services", "providers", "clients"], FileIcon(symbol: "bolt.horizontal.fill", tint: .yellow)),
        ([".vscode", ".idea"], FileIcon(symbol: "chevron.left.forwardslash.chevron.right", tint: .blue)),
        ([".claude"], FileIcon(symbol: "sparkles", tint: .orange)),
        (["docker", ".docker", "deploy", "infra", "k8s", "terraform"], FileIcon(symbol: "shippingbox.circle.fill", tint: .teal)),
        (["logs", "log", "tmp", "temp"], FileIcon(symbol: "clock.fill", tint: .gray)),
    ]

    static let genericFolder = FileIcon(symbol: "folder.fill", tint: .blue)

    static func folder(named name: String) -> FileIcon {
        let key = name.lowercased()
        return folderRules.first { $0.names.contains(key) || $0.names.contains(name) }?.icon ?? genericFolder
    }

    // MARK: - Archivos

    private static let exactFileNames: [String: FileIcon] = [
        "package.json": FileIcon(symbol: "shippingbox.fill", tint: .red),
        "package-lock.json": FileIcon(symbol: "lock.fill", tint: .gray),
        "pnpm-lock.yaml": FileIcon(symbol: "lock.fill", tint: .gray),
        "yarn.lock": FileIcon(symbol: "lock.fill", tint: .gray),
        "bun.lockb": FileIcon(symbol: "lock.fill", tint: .gray),
        "dockerfile": FileIcon(symbol: "shippingbox.circle.fill", tint: .blue),
        "docker-compose.yml": FileIcon(symbol: "shippingbox.circle.fill", tint: .blue),
        "compose.yml": FileIcon(symbol: "shippingbox.circle.fill", tint: .blue),
        "makefile": FileIcon(symbol: "hammer.fill", tint: .orange),
        ".gitignore": FileIcon(symbol: "eye.slash", tint: .gray),
        "license": FileIcon(symbol: "checkmark.shield.fill", tint: .yellow),
        "readme.md": FileIcon(symbol: "book.fill", tint: .blue),
        "claude.md": FileIcon(symbol: "sparkles", tint: .orange),
        "agents.md": FileIcon(symbol: "sparkles", tint: .orange),
    ]

    private static let extensionRules: [(extensions: Set<String>, icon: FileIcon)] = [
        (["md", "mdx", "markdown"], FileIcon(symbol: "doc.richtext.fill", tint: .blue)),
        (["swift"], FileIcon(symbol: "swift", tint: .orange)),
        (["ts", "tsx"], FileIcon(symbol: "chevron.left.forwardslash.chevron.right", tint: .blue)),
        (["js", "jsx", "mjs", "cjs"], FileIcon(symbol: "chevron.left.forwardslash.chevron.right", tint: .yellow)),
        (["py"], FileIcon(symbol: "chevron.left.forwardslash.chevron.right", tint: .green)),
        (["go"], FileIcon(symbol: "chevron.left.forwardslash.chevron.right", tint: .teal)),
        (["rs"], FileIcon(symbol: "chevron.left.forwardslash.chevron.right", tint: .brown)),
        (["php", "rb", "java", "kt", "c", "h", "cpp", "cs", "dart", "vue", "svelte"],
         FileIcon(symbol: "chevron.left.forwardslash.chevron.right", tint: .purple)),
        (["html", "htm"], FileIcon(symbol: "globe", tint: .orange)),
        (["css", "scss", "sass", "less"], FileIcon(symbol: "paintbrush.fill", tint: .pink)),
        (["json", "jsonc"], FileIcon(symbol: "curlybraces.square.fill", tint: .yellow)),
        (["yml", "yaml", "toml", "ini", "conf", "cfg", "xml", "plist"], FileIcon(symbol: "gearshape.fill", tint: .gray)),
        (["env"], FileIcon(symbol: "key.fill", tint: .yellow)),
        (["sh", "bash", "zsh", "fish"], FileIcon(symbol: "terminal.fill", tint: .green)),
        (["sql", "db", "sqlite", "prisma"], FileIcon(symbol: "cylinder.split.1x2.fill", tint: .yellow)),
        (["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "heic", "bmp", "avif"], FileIcon(symbol: "photo.fill", tint: .pink)),
        (["pdf"], FileIcon(symbol: "doc.text.fill", tint: .red)),
        (["zip", "gz", "tgz", "tar", "rar", "7z"], FileIcon(symbol: "doc.zipper", tint: .gray)),
        (["mp4", "mov", "webm", "mp3", "wav", "m4a"], FileIcon(symbol: "play.rectangle.fill", tint: .purple)),
        (["txt", "log", "csv"], FileIcon(symbol: "doc.text", tint: .gray)),
        (["lock"], FileIcon(symbol: "lock.fill", tint: .gray)),
    ]

    static let genericFile = FileIcon(symbol: "doc", tint: .gray)

    static func file(named name: String) -> FileIcon {
        let lower = name.lowercased()
        if let exact = exactFileNames[lower] { return exact }
        if lower.hasPrefix(".env") { return FileIcon(symbol: "key.fill", tint: .yellow) }
        if lower.hasPrefix("dockerfile") { return FileIcon(symbol: "shippingbox.circle.fill", tint: .blue) }
        let ext = RemotePath.fileExtension(lower)
        return extensionRules.first { $0.extensions.contains(ext) }?.icon ?? genericFile
    }

    static func icon(for entry: RemoteFileEntry) -> FileIcon {
        switch entry.kind {
        case .directory: return folder(named: entry.name)
        case .symlink: return FileIcon(symbol: "arrow.turn.up.right", tint: .gray)
        case .file: return file(named: entry.name)
        }
    }
}
