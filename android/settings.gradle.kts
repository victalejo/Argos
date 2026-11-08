pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "ArgosAndroid"

// core: Kotlin/JVM puro (modelo, validadores, protocolo). Prohibido depender de Android,
// igual que ArgosCore/ no importa AppKit: así sus tests corren en la JVM, rápidos.
include(":core")
include(":app")
