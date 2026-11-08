# Reglas R8/ProGuard del módulo :ssh (sshj + BouncyCastle + slf4j).
#
# Se empaquetan en el jar como META-INF/proguard/argos-ssh.pro, así que R8 las aplica solo al
# minificar la app (isMinifyEnabled = true en release). Si la app deja de consumir el jar (p. ej.
# copia las fuentes), añade estas líneas a app/proguard-rules.pro.

# BouncyCastle: el proveedor JCA registra sus algoritmos por NOMBRE DE CLASE (reflexión).
# Sin esto, R8 los elimina/renombra y fallan X25519, Ed25519, ChaCha20-Poly1305, bcrypt...
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# sshj: fábricas de algoritmos, KEX y formatos de clave (algunas por reflexión/ServiceLoader).
-keep class net.schmizz.sshj.** { *; }
-keep class net.schmizz.keepalive.** { *; }
-keep class com.hierynomus.sshj.** { *; }
-keep class com.hierynomus.asn1.** { *; }
-dontwarn net.schmizz.sshj.**
-dontwarn com.hierynomus.sshj.**
# Kerberos/GSSAPI y JNDI: opcionales en sshj, no existen en Android.
-dontwarn org.ietf.jgss.**
-dontwarn javax.security.auth.**
-dontwarn javax.naming.**
-dontwarn sun.security.**

# slf4j 2.x localiza el binding con ServiceLoader (slf4j-nop: sin logs, sin logback).
-keep class org.slf4j.nop.NOPServiceProvider { *; }
-keep class * implements org.slf4j.spi.SLF4JServiceProvider { *; }
-dontwarn org.slf4j.**
