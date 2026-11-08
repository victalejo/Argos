import com.github.triplet.gradle.androidpublisher.ReleaseStatus
import java.util.regex.Pattern

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    // Rutas tipadas de Navigation Compose (@Serializable).
    alias(libs.plugins.kotlin.serialization)
    // «Licencias de código abierto»: genera R.raw.aboutlibraries con las dependencias reales.
    alias(libs.plugins.aboutlibraries.android)
    // Ficha y subida a Google Play (src/main/play/). Ver android/README.md → Publicación.
    alias(libs.plugins.play.publisher)
}

/**
 * Valor de firma/publicación: primero propiedad de Gradle (`-P…` o `~/.gradle/gradle.properties`,
 * NUNCA el gradle.properties del repo) y si no, variable de entorno (CI). Vacío = ausente.
 */
fun releaseSetting(name: String): String? =
    providers.gradleProperty(name).orElse(providers.environmentVariable(name)).orNull?.takeIf { it.isNotBlank() }

val uploadSigning: Map<String, String?> = listOf(
    "ARGOS_UPLOAD_STORE_FILE",
    "ARGOS_UPLOAD_STORE_PASSWORD",
    "ARGOS_UPLOAD_KEY_ALIAS",
    "ARGOS_UPLOAD_KEY_PASSWORD",
).associateWith(::releaseSetting)
val missingUploadSigning: List<String> = uploadSigning.filterValues { it == null }.keys.toList()
val uploadStoreFile: File? = uploadSigning["ARGOS_UPLOAD_STORE_FILE"]?.let { rootProject.file(it) }
if (missingUploadSigning.size in 1..3) {
    // Configuración a medias: casi seguro un error (un secreto mal escrito en la CI).
    throw GradleException("Firma de release incompleta: faltan ${missingUploadSigning.joinToString()}. Define las cuatro o ninguna.")
}
if (uploadStoreFile != null && !uploadStoreFile.isFile) {
    throw GradleException("ARGOS_UPLOAD_STORE_FILE apunta a un archivo que no existe: $uploadStoreFile")
}
val releaseSigned: Boolean = missingUploadSigning.isEmpty()

/** `versionName`/`versionCode` salen de android/gradle.properties (ver README → Publicación). */
val argosVersionName: String = providers.gradleProperty("ARGOS_VERSION_NAME").get()
val argosVersionCode: Int = providers.gradleProperty("ARGOS_VERSION_CODE").get().toIntOrNull()
    ?.takeIf { it in 1..2_100_000_000 }
    ?: throw GradleException("ARGOS_VERSION_CODE debe ser un entero entre 1 y 2100000000 (límite de Play).")

android {
    namespace = "com.iaportafolio.argos"
    compileSdk = 37

    defaultConfig {
        // Mismo identificador que en Apple: una sola identidad de producto.
        applicationId = "com.iaportafolio.argos"
        minSdk = 29 // Android 10: ~95 % del parque, Keystore y SAF modernos.
        targetSdk = 37
        versionCode = argosVersionCode
        versionName = argosVersionName
    }

    // Clave de SUBIDA (upload key): Play App Signing re-firma con la clave de la app que custodia
    // Google. Sin las cuatro variables, el release se construye SIN firmar (CI de PR) y
    // bundleRelease lo avisa.
    signingConfigs {
        if (releaseSigned) {
            create("release") {
                storeFile = uploadStoreFile
                storePassword = uploadSigning.getValue("ARGOS_UPLOAD_STORE_PASSWORD")
                keyAlias = uploadSigning.getValue("ARGOS_UPLOAD_KEY_ALIAS")
                keyPassword = uploadSigning.getValue("ARGOS_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (releaseSigned) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        // BuildConfig.VERSION_NAME/VERSION_CODE para «Acerca de».
        buildConfig = true
    }

    // sshj, BouncyCastle y slf4j traen licencias y manifiestos duplicados en META-INF.
    packaging {
        // terminal-emulator trae libtermux.so (JNI para lanzar un proceso LOCAL). Argos alimenta
        // el emulador con bytes del PTY remoto y nunca carga esa librería: fuera del APK (sin
        // código nativo, sin requisitos de alineación de 16 KB).
        jniLibs {
            excludes += "**/libtermux.so"
        }
        resources {
            excludes += setOf(
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/DEPENDENCIES",
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
            )
        }
    }

    testOptions {
        unitTests.all { it.useJUnitPlatform() }
        // android.util.Log en los tests JVM: los stubs devuelven valores por defecto en vez de lanzar.
        unitTests.isReturnDefaultValues = true
    }

    // Lint como guardián: cualquier aviso nuevo rompe la build (y la CI).
    lint {
        warningsAsErrors = true
        abortOnError = true
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":core"))
    implementation(project(":ssh"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)
    // Emulador de terminal (Apache 2.0): TerminalEmulator + TerminalRenderer + KeyHandler.
    implementation(libs.termux.terminal.view)
    // Vista previa de Markdown (Apache 2.0, mikepenz). Sin imageTransformer: nunca carga imágenes remotas.
    implementation(libs.markdown.renderer.m3)
    // Escáner del QR del Mac (Apache 2.0): CameraX + ZXing core. Sin ML Kit ni servicios de Google.
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.zxing.core)
    // «Licencias de código abierto» (Apache 2.0, mikepenz): lista generada por el plugin.
    implementation(libs.aboutlibraries.compose.m3)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.core)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)

    testImplementation(kotlin("test"))
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.junit.jupiter.params)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.turbine)
    testRuntimeOnly(libs.junit.platform.launcher)
}

// Licencias: R.raw.aboutlibraries se genera en cada build a partir de las dependencias reales.
aboutLibraries {
    // Sin red durante la build (reproducible). En modo offline el plugin no descarga los textos:
    // van en config/licenses/ (Apache 2.0, MIT, BSD-3, Bouncy Castle). Una licencia nueva
    // necesita su JSON con el texto, además de figurar en allowedLicenses.
    offlineMode = true
    collect {
        // Definiciones manuales (p. ej. Termux, que llega de JitPack con licencia «Other»).
        configPath = file("config")
        // Solo lo que va en el APK de release (sin herramientas de test ni de debug).
        filterVariants.add("release")
    }
    export {
        // Ni desarrolladores ni financiación: menos tamaño y ninguna URL extra que abrir.
        excludeFields.addAll("developers", "funding")
    }
    license {
        // Una dependencia nueva con una licencia no revisada rompe la build en vez de colarse.
        strictMode = com.mikepenz.aboutlibraries.plugin.StrictMode.FAIL
        allowedLicenses.addAll("Apache-2.0", "MIT", "BSD-2-Clause", "BSD-3-Clause", "EPL-1.0", "EPL-2.0")
        // BouncyCastle publica su propia licencia (equivalente a MIT).
        allowedLicensesMap = mapOf("Bouncy Castle Licence" to listOf("org.bouncycastle"))
    }
    library {
        duplicationMode = com.mikepenz.aboutlibraries.plugin.DuplicateMode.MERGE
        // Termux llega de JitPack con licencia «Other» y el plugin FUSIONA (no reemplaza) las de
        // config/: se excluye lo detectado y queda solo la definición manual (Apache 2.0, ver
        // termux-app/LICENSE.md: terminal-view y terminal-emulator son la excepción Apache al GPLv3).
        exclusionPatterns.add(Pattern.compile("com\\.github\\.termux\\.termux-app:.*"))
    }
}

// Google Play (Gradle Play Publisher). Credenciales: ARGOS_PLAY_SERVICE_ACCOUNT = RUTA al JSON de la
// cuenta de servicio (fuera del repo). Sin ella, las tareas publish* fallan al ejecutarse, nunca al
// configurar: el resto de la build no depende de Play.
play {
    releaseSetting("ARGOS_PLAY_SERVICE_ACCOUNT")?.let { serviceAccountCredentials.set(rootProject.file(it)) }
    track.set("internal")
    defaultToAppBundles.set(true)
    // Borrador: Play no publica nada hasta que alguien lo revise y lo lance en Play Console
    // (y una app que aún no se ha publicado solo admite borradores).
    releaseStatus.set(ReleaseStatus.DRAFT)
}

// PlayListingTest lee la ficha: si cambia un texto, los tests deben volver a correr (caché de Gradle).
tasks.withType<Test>().configureEach {
    inputs.dir("src/main/play").withPropertyName("playListing").withPathSensitivity(PathSensitivity.RELATIVE)
}
// OpenSourceLicensesTest lee el JSON de licencias generado para debug (mismas dependencias que release).
tasks.matching { it.name == "testDebugUnitTest" }.configureEach { dependsOn("prepareLibraryDefinitionsDebug") }

// Aviso (o error con -PARGOS_REQUIRE_SIGNING=true, como en la CI de publicación) si el AAB sale sin
// firmar: Play no acepta un bundle sin firmar.
val requireSigning: Boolean = releaseSetting("ARGOS_REQUIRE_SIGNING")?.toBoolean() == true
if (!releaseSigned && requireSigning) {
    throw GradleException("ARGOS_REQUIRE_SIGNING=true pero faltan ${missingUploadSigning.joinToString()}.")
}
tasks.matching { it.name == "bundleRelease" || it.name == "assembleRelease" }.configureEach {
    val signed = releaseSigned
    val missing = missingUploadSigning.joinToString()
    doFirst {
        if (!signed) {
            logger.warn(
                "\n⚠️  ${name}: release SIN FIRMAR (faltan $missing). Sirve para comprobar la build, " +
                    "pero Google Play no lo acepta. Ver android/README.md → Publicación.\n",
            )
        }
    }
}

// R8: comprueba en el mapping del release que lo que se carga por NOMBRE no se renombró ni se
// eliminó (proveedor JCA, Worker que WorkManager instancia desde su base de datos, componentes
// del manifiesto, sshj y su binding de slf4j). Corre tras assembleRelease/bundleRelease.
abstract class CheckR8KeepsTask : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val mappingFile: RegularFileProperty

    @get:Input
    abstract val requiredClasses: ListProperty<String>

    @TaskAction
    fun check() {
        val kept = mappingFile.get().asFile.readLines()
            .filter { !it.startsWith(" ") && !it.startsWith("#") && it.contains(" -> ") }
            .mapNotNull { line ->
                val (original, obfuscated) = line.removeSuffix(":").split(" -> ")
                original.takeIf { it == obfuscated }
            }
            .toSet()
        val renamed = requiredClasses.get().filterNot { it in kept }
        if (renamed.isNotEmpty()) {
            throw GradleException("R8 renombró o eliminó clases que se cargan por nombre: ${renamed.joinToString()}")
        }
    }
}

androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        val check = tasks.register<CheckR8KeepsTask>("check${variant.name.replaceFirstChar(Char::uppercase)}R8Keeps") {
            group = "verification"
            description = "Verifica en el mapping de R8 que las clases cargadas por nombre conservan su nombre."
            mappingFile.set(variant.artifacts.get(com.android.build.api.artifact.SingleArtifact.OBFUSCATION_MAPPING_FILE))
            requiredClasses.set(
                listOf(
                    "org.bouncycastle.jce.provider.BouncyCastleProvider",
                    "com.iaportafolio.argos.background.AgentCheckWorker",
                    "com.iaportafolio.argos.background.TerminalKeepAliveService",
                    "com.iaportafolio.argos.ArgosApplication",
                    "com.iaportafolio.argos.MainActivity",
                    "net.schmizz.sshj.SSHClient",
                    "org.slf4j.nop.NOPServiceProvider",
                ),
            )
        }
        tasks.matching { it.name == "assembleRelease" || it.name == "bundleRelease" }.configureEach { finalizedBy(check) }
    }
}
