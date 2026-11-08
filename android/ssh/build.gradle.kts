plugins {
    alias(libs.plugins.kotlin.jvm)
    // testFixtures: servidor SSH embebido (Apache MINA SSHD) compartido por los tests de
    // integración y por la tarea `devServer`. Nunca llega al APK (no es parte de `main`).
    `java-test-fixtures`
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // core define el contrato (SSHServicing, SSHConnector, errores) y los comandos/parsers.
    api(project(":core"))

    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)

    implementation(libs.sshj)
    // sshj trae BouncyCastle 1.84: se alinea con la versión de core (bcprov 1.86).
    implementation(libs.bouncycastle.bcprov)
    implementation(libs.bouncycastle.bcpkix)
    // sshj registra con slf4j: binding mudo para no arrastrar logback (ni ruido) a Android.
    runtimeOnly(libs.slf4j.nop)

    testFixturesImplementation(project(":core"))
    testFixturesImplementation(libs.sshd.core)
    testFixturesImplementation(libs.sshd.sftp)
    testFixturesImplementation(libs.bouncycastle.bcprov)
    testFixturesRuntimeOnly(libs.slf4j.nop)

    testImplementation(kotlin("test"))
    testImplementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.sshd.core)
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

// Las reglas R8/ProGuard viajan DENTRO del jar (META-INF/proguard/): R8 las aplica solo al
// minificar la app, sin que el módulo `app` tenga que copiarlas.
tasks.processResources {
    from("consumer-rules.pro") {
        into("META-INF/proguard")
        rename { "argos-ssh.pro" }
    }
}

tasks.test {
    useJUnitPlatform()
}

/**
 * Servidor SSH de desarrollo para probar la app en un TELÉFONO FÍSICO:
 *
 *     ./gradlew :ssh:devServer
 *     adb reverse tcp:2222 tcp:2222
 *
 * Escucha en 127.0.0.1:2222 (usuario `argos`, contraseña `argos-dev`) con host key persistente
 * y una clave Ed25519 de cliente de prueba en `build/dev/`. Ctrl+C lo detiene.
 */
tasks.register<JavaExec>("devServer") {
    group = "argos"
    description = "Servidor SSH de desarrollo (MINA SSHD) en 127.0.0.1:2222 para el teléfono."
    classpath = sourceSets["testFixtures"].runtimeClasspath
    mainClass.set("com.iaportafolio.argos.ssh.testing.DevSshServerKt")
    args(layout.buildDirectory.dir("dev").get().asFile.absolutePath)
}
