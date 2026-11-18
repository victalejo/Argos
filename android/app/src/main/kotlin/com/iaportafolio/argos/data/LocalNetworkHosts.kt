package com.iaportafolio.argos.data

import java.net.InetAddress
import java.net.UnknownHostException

/**
 * ¿Un host está en la red local? Lógica pura (sin Android) para el permiso `ACCESS_LOCAL_NETWORK`
 * de Android 17: con target 37, el TCP hacia la LAN queda bloqueado sin él (y da «timeout»).
 *
 * Cuenta como local: IPv4 privada (RFC 1918: 10/8, 172.16/12, 192.168/16), enlace local
 * (169.254/16, fe80::/10), IPv6 de ámbito local único (fc00::/7) y los nombres mDNS `.local`.
 * NO cuenta: el bucle local (127/8, ::1, que usa `adb reverse`) ni el rango CGNAT 100.64/10 (VPN
 * como Tailscale): la documentación no los incluye y bloquearlos rompería conexiones que funcionan.
 */
object LocalNetworkHosts {

    /** Sufijo mDNS: resolverlo ya exige el permiso. */
    private const val MDNS_SUFFIX = ".local"

    private val IPV4_LITERAL = Regex("""^\d{1,3}(\.\d{1,3}){3}$""")

    /**
     * Decide solo con el texto (sin DNS): IP literal local o nombre `.local`. Un nombre normal
     * devuelve `false` aunque resuelva a la LAN; para eso está [isLocalAddress] tras resolverlo.
     */
    fun isLocalHostName(host: String): Boolean {
        val name = host.trim().trimEnd('.').removePrefix("[").removeSuffix("]")
        if (name.isEmpty()) return false
        if (name.endsWith(MDNS_SUFFIX, ignoreCase = true)) return true
        return literalAddress(name)?.let { isLocalAddress(it.address) } ?: false
    }

    /** ¿Es un literal IP (v4 o v6)? Los nombres no se resuelven aquí. */
    fun isIpLiteral(host: String): Boolean = literalAddress(host.trim().removePrefix("[").removeSuffix("]")) != null

    /** Dirección ya resuelta (4 o 16 bytes). */
    fun isLocalAddress(address: ByteArray): Boolean = when (address.size) {
        IPV4_BYTES -> isLocalIpv4(address)
        IPV6_BYTES -> isLocalIpv6(address)
        else -> false
    }

    private fun isLocalIpv4(a: ByteArray): Boolean {
        val first = a[0].toInt() and BYTE_MASK
        val second = a[1].toInt() and BYTE_MASK
        return first == 10 ||
            (first == 172 && second in 16..31) ||
            (first == 192 && second == 168) ||
            (first == 169 && second == 254)
    }

    private fun isLocalIpv6(a: ByteArray): Boolean {
        val first = a[0].toInt() and BYTE_MASK
        val second = a[1].toInt() and BYTE_MASK
        // IPv4 mapeada (::ffff:a.b.c.d): se decide por la IPv4.
        val mapped = (0 until 10).all { a[it].toInt() == 0 } &&
            (a[10].toInt() and BYTE_MASK) == BYTE_MASK &&
            (a[11].toInt() and BYTE_MASK) == BYTE_MASK
        if (mapped) return isLocalIpv4(a.copyOfRange(12, 16))
        val linkLocal = first == 0xfe && (second and 0xc0) == 0x80
        val uniqueLocal = (first and 0xfe) == 0xfc
        return linkLocal || uniqueLocal
    }

    /** Literal IP sin consultar el DNS (para IPv6 se quita el identificador de zona `%wlan0`). */
    private fun literalAddress(text: String): InetAddress? {
        val isV4 = IPV4_LITERAL.matches(text)
        val isV6 = ':' in text
        if (!isV4 && !isV6) return null
        if (isV4 && text.split('.').any { it.toInt() > BYTE_MASK }) return null
        return try {
            // Con un literal, getByName no resuelve nada: solo lo convierte (una IPv4 mapeada
            // en IPv6, `::ffff:a.b.c.d`, sale como IPv4).
            InetAddress.getByName(text.substringBefore('%'))
        } catch (error: UnknownHostException) {
            null
        } catch (error: SecurityException) {
            null
        }
    }

    private const val IPV4_BYTES = 4
    private const val IPV6_BYTES = 16
    private const val BYTE_MASK = 0xff
}

/**
 * Decide si una conexión a un host va a chocar con el permiso de red local que falta. Las tres
 * piezas que dependen del sistema van inyectadas para poder probarlo en la JVM.
 */
class LocalNetworkGate(
    /** ¿Aplica el permiso? (Android 17+ con target 37). */
    private val isRequired: () -> Boolean,
    private val isGranted: () -> Boolean,
    /** DNS del sistema (el servidor DNS local no necesita el permiso). Bloqueante: llamar en IO. */
    private val resolve: (String) -> List<ByteArray>,
) {
    /** ¿Falta el permiso en este dispositivo? (sin mirar ningún host). */
    val isMissing: Boolean get() = isRequired() && !isGranted()

    /** `true` si conectar a [host] necesita el permiso y no está concedido. Bloqueante (DNS). */
    fun blocks(host: String): Boolean {
        if (!isMissing) return false
        return isLocal(host)
    }

    /** ¿[host] está en la red local? Literal, `.local` o un nombre que resuelve a la LAN. */
    fun isLocal(host: String): Boolean {
        if (LocalNetworkHosts.isLocalHostName(host)) return true
        if (LocalNetworkHosts.isIpLiteral(host)) return false
        val addresses = try {
            resolve(host)
        } catch (error: UnknownHostException) {
            // Sin resolver no se sabe: que la conexión falle con su propio error.
            return false
        } catch (error: SecurityException) {
            return false
        }
        return addresses.any(LocalNetworkHosts::isLocalAddress)
    }

    companion object {
        /** Sin permiso de red local (versiones anteriores, tests): nunca bloquea. */
        val NotRequired = LocalNetworkGate({ false }, { true }, { emptyList() })

        /** DNS real del sistema. */
        fun systemResolver(host: String): List<ByteArray> = InetAddress.getAllByName(host).map { it.address }
    }
}

/**
 * Falta el permiso de red local para un servidor de la Wi-Fi. Sin él, Android 17 descarta el TCP
 * y la conexión acabaría en «timeout» sin explicar por qué: se corta antes con un mensaje propio.
 */
class LocalNetworkPermissionException(val host: String) : Exception(
    "Para conectar con $host, que está en tu red local, Argos necesita el permiso «Dispositivos " +
        "cercanos». Concédelo al volver a abrir el servidor o en Ajustes del sistema → Apps → Argos → " +
        "Permisos.",
)
