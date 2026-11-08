# Reglas de R8 propias de la app Argos.
#
# Las de cada librería viajan con ella y R8 las aplica solas (ver
# app/build/outputs/mapping/release/configuration.txt):
#   - kotlinx.serialization (rutas tipadas de Navigation, projects.json, AboutLibraries),
#     WorkManager (AgentCheckWorker se instancia por nombre), CameraX, Navigation, Compose.
#   - :ssh → META-INF/proguard/argos-ssh.pro (sshj, BouncyCastle, slf4j-nop).
#   - Termux terminal-emulator/terminal-view no usan reflexión; su JNI (libtermux.so) se excluye del
#     APK y Argos nunca lo carga.
# checkReleaseR8Keeps (app/build.gradle.kts) falla si R8 renombra lo que se carga por nombre.

# Trazas legibles en Play Console (el mapping viaja dentro del AAB): conserva números de línea sin
# delatar nombres de archivo.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
