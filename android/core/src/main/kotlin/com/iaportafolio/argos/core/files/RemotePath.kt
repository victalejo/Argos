package com.iaportafolio.argos.core.files

/** Utilidades de rutas POSIX del servidor (no del dispositivo). */
object RemotePath {

    fun join(parent: String, name: String): String =
        if (parent.endsWith("/")) parent + name else "$parent/$name"

    /**
     * ¿[path] está dentro de [root] (o es [root])? Compara por componentes, así
     * "/srv/app-old" NO cuenta como dentro de "/srv/app".
     */
    fun isInside(path: String, root: String): Boolean {
        val normalizedRoot = if (root.endsWith("/") && root.length > 1) root.dropLast(1) else root
        val prefix = if (normalizedRoot == "/") "/" else "$normalizedRoot/"
        return path == normalizedRoot || path.startsWith(prefix)
    }

    /** Ruta relativa a [root] para mostrarla ("src/app/page.tsx"). */
    fun relative(path: String, root: String): String {
        if (!isInside(path, root) || path == root) return path
        val prefix = if (root.endsWith("/")) root else "$root/"
        return path.drop(prefix.length)
    }

    /**
     * Extensión en minúsculas, con las reglas de `NSString.pathExtension`: se ignoran las
     * barras finales, un punto inicial (".env") no inicia extensión y una extensión con
     * espacios no es válida.
     */
    fun fileExtension(name: String): String {
        val lastComponent = name.trimEnd('/').substringAfterLast('/')
        val dot = lastComponent.lastIndexOf('.')
        if (dot <= 0) return ""
        val ext = lastComponent.substring(dot + 1)
        return if (ext.contains(' ')) "" else ext.lowercase()
    }
}
