package com.iaportafolio.argos.core.files

/** Tono semántico de un icono (la vista lo traduce a un color del tema). */
enum class FileIconTint { BLUE, ORANGE, YELLOW, GREEN, MINT, TEAL, PURPLE, PINK, RED, GRAY, BROWN, INDIGO }

/**
 * Categoría de icono de cada carpeta/archivo del explorador (port de
 * `ArgosCore/Files/FileIcon.swift`). Sustituye al SF Symbol de Apple: la vista de
 * Android elige el dibujo por categoría y el color por [tint].
 */
enum class FileIcon(val tint: FileIconTint) {
    // Carpetas
    SOURCE_FOLDER(FileIconTint.BLUE),
    APP_FOLDER(FileIconTint.INDIGO),
    COMPONENTS_FOLDER(FileIconTint.TEAL),
    PAGES_FOLDER(FileIconTint.PURPLE),
    SERVER_FOLDER(FileIconTint.GREEN),
    ASSETS_FOLDER(FileIconTint.PINK),
    DOCS_FOLDER(FileIconTint.BROWN),
    TESTS_FOLDER(FileIconTint.GREEN),
    SCRIPTS_FOLDER(FileIconTint.GRAY),
    CONFIG_FOLDER(FileIconTint.GRAY),
    CI_FOLDER(FileIconTint.INDIGO),
    GIT_FOLDER(FileIconTint.GRAY),
    DEPENDENCIES_FOLDER(FileIconTint.BROWN),
    BUILD_OUTPUT_FOLDER(FileIconTint.ORANGE),
    STYLES_FOLDER(FileIconTint.PINK),
    HOOKS_FOLDER(FileIconTint.TEAL),
    UTILS_FOLDER(FileIconTint.GRAY),
    MODELS_FOLDER(FileIconTint.ORANGE),
    DATABASE_FOLDER(FileIconTint.YELLOW),
    LOCALES_FOLDER(FileIconTint.BLUE),
    STATE_FOLDER(FileIconTint.PURPLE),
    SERVICES_FOLDER(FileIconTint.YELLOW),
    EDITOR_FOLDER(FileIconTint.BLUE),
    CLAUDE_FOLDER(FileIconTint.ORANGE),
    INFRA_FOLDER(FileIconTint.TEAL),
    LOGS_FOLDER(FileIconTint.GRAY),
    GENERIC_FOLDER(FileIconTint.BLUE),

    // Archivos por nombre exacto
    PACKAGE_MANIFEST(FileIconTint.RED),
    LOCKFILE(FileIconTint.GRAY),
    DOCKER(FileIconTint.BLUE),
    MAKEFILE(FileIconTint.ORANGE),
    GITIGNORE(FileIconTint.GRAY),
    LICENSE(FileIconTint.YELLOW),
    README(FileIconTint.BLUE),
    AGENT_INSTRUCTIONS(FileIconTint.ORANGE),

    // Archivos por extensión
    MARKDOWN(FileIconTint.BLUE),
    SWIFT(FileIconTint.ORANGE),
    TYPESCRIPT(FileIconTint.BLUE),
    JAVASCRIPT(FileIconTint.YELLOW),
    PYTHON(FileIconTint.GREEN),
    GO(FileIconTint.TEAL),
    RUST(FileIconTint.BROWN),
    OTHER_CODE(FileIconTint.PURPLE),
    HTML(FileIconTint.ORANGE),
    STYLESHEET(FileIconTint.PINK),
    JSON(FileIconTint.YELLOW),
    CONFIG_FILE(FileIconTint.GRAY),
    ENV(FileIconTint.YELLOW),
    SHELL(FileIconTint.GREEN),
    DATABASE_FILE(FileIconTint.YELLOW),
    IMAGE(FileIconTint.PINK),
    PDF(FileIconTint.RED),
    ARCHIVE(FileIconTint.GRAY),
    MEDIA(FileIconTint.PURPLE),
    TEXT(FileIconTint.GRAY),
    GENERIC_FILE(FileIconTint.GRAY),

    SYMLINK(FileIconTint.GRAY),
    ;

    companion object {
        private val folderRules: List<Pair<Set<String>, FileIcon>> = listOf(
            setOf("src", "source", "sources", "lib") to SOURCE_FOLDER,
            setOf("app", "apps") to APP_FOLDER,
            setOf("components", "ui", "widgets") to COMPONENTS_FOLDER,
            setOf("pages", "views", "screens", "templates", "layouts") to PAGES_FOLDER,
            setOf("api", "routes", "server", "backend", "controllers", "handlers") to SERVER_FOLDER,
            setOf("public", "static", "assets", "images", "img", "media", "icons", "fonts") to ASSETS_FOLDER,
            setOf("docs", "doc", "documentation", "wiki") to DOCS_FOLDER,
            setOf("test", "tests", "__tests__", "spec", "specs", "e2e", "cypress", "playwright") to TESTS_FOLDER,
            setOf("scripts", "bin", "tools", "cli") to SCRIPTS_FOLDER,
            setOf("config", "configs", "settings", ".config") to CONFIG_FOLDER,
            setOf(".github", ".gitlab", ".circleci", "workflows") to CI_FOLDER,
            setOf(".git") to GIT_FOLDER,
            setOf("node_modules", "vendor", "packages", ".venv", "venv", "Pods") to DEPENDENCIES_FOLDER,
            setOf("dist", "build", "out", ".next", ".nuxt", "target", "release") to BUILD_OUTPUT_FOLDER,
            setOf("styles", "css", "scss", "theme", "themes") to STYLES_FOLDER,
            setOf("hooks") to HOOKS_FOLDER,
            setOf("utils", "helpers", "common", "shared", "core") to UTILS_FOLDER,
            setOf("models", "schemas", "types", "entities", "domain", "interfaces") to MODELS_FOLDER,
            setOf("db", "database", "migrations", "prisma", "sql", "seeds") to DATABASE_FOLDER,
            setOf("locales", "i18n", "lang", "translations") to LOCALES_FOLDER,
            setOf("store", "stores", "state", "redux", "context") to STATE_FOLDER,
            setOf("services", "providers", "clients") to SERVICES_FOLDER,
            setOf(".vscode", ".idea") to EDITOR_FOLDER,
            setOf(".claude") to CLAUDE_FOLDER,
            setOf("docker", ".docker", "deploy", "infra", "k8s", "terraform") to INFRA_FOLDER,
            setOf("logs", "log", "tmp", "temp") to LOGS_FOLDER,
        )

        private val exactFileNames: Map<String, FileIcon> = mapOf(
            "package.json" to PACKAGE_MANIFEST,
            "package-lock.json" to LOCKFILE,
            "pnpm-lock.yaml" to LOCKFILE,
            "yarn.lock" to LOCKFILE,
            "bun.lockb" to LOCKFILE,
            "dockerfile" to DOCKER,
            "docker-compose.yml" to DOCKER,
            "compose.yml" to DOCKER,
            "makefile" to MAKEFILE,
            ".gitignore" to GITIGNORE,
            "license" to LICENSE,
            "readme.md" to README,
            "claude.md" to AGENT_INSTRUCTIONS,
            "agents.md" to AGENT_INSTRUCTIONS,
        )

        private val extensionRules: List<Pair<Set<String>, FileIcon>> = listOf(
            setOf("md", "mdx", "markdown") to MARKDOWN,
            setOf("swift") to SWIFT,
            setOf("ts", "tsx") to TYPESCRIPT,
            setOf("js", "jsx", "mjs", "cjs") to JAVASCRIPT,
            setOf("py") to PYTHON,
            setOf("go") to GO,
            setOf("rs") to RUST,
            setOf("php", "rb", "java", "kt", "c", "h", "cpp", "cs", "dart", "vue", "svelte") to OTHER_CODE,
            setOf("html", "htm") to HTML,
            setOf("css", "scss", "sass", "less") to STYLESHEET,
            setOf("json", "jsonc") to JSON,
            setOf("yml", "yaml", "toml", "ini", "conf", "cfg", "xml", "plist") to CONFIG_FILE,
            setOf("env") to ENV,
            setOf("sh", "bash", "zsh", "fish") to SHELL,
            setOf("sql", "db", "sqlite", "prisma") to DATABASE_FILE,
            setOf("png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "heic", "bmp", "avif") to IMAGE,
            setOf("pdf") to PDF,
            setOf("zip", "gz", "tgz", "tar", "rar", "7z") to ARCHIVE,
            setOf("mp4", "mov", "webm", "mp3", "wav", "m4a") to MEDIA,
            setOf("txt", "log", "csv") to TEXT,
            setOf("lock") to LOCKFILE,
        )

        fun folder(name: String): FileIcon {
            val key = name.lowercase()
            return folderRules.firstOrNull { (names, _) -> key in names || name in names }?.second
                ?: GENERIC_FOLDER
        }

        fun file(name: String): FileIcon {
            val lower = name.lowercase()
            exactFileNames[lower]?.let { return it }
            if (lower.startsWith(".env")) return ENV
            if (lower.startsWith("dockerfile")) return DOCKER
            val ext = RemotePath.fileExtension(lower)
            return extensionRules.firstOrNull { (extensions, _) -> ext in extensions }?.second ?: GENERIC_FILE
        }

        fun of(entry: RemoteFileEntry): FileIcon = when (entry.kind) {
            RemoteFileEntry.Kind.DIRECTORY -> folder(entry.name)
            RemoteFileEntry.Kind.SYMLINK -> SYMLINK
            RemoteFileEntry.Kind.FILE -> file(entry.name)
        }
    }
}
