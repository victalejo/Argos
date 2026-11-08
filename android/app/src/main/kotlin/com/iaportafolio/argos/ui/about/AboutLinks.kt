package com.iaportafolio.argos.ui.about

/** Enlaces de «Acerca de». Se abren SIEMPRE tras confirmar (ver `ProvideConfirmedLinks`). */
object AboutLinks {
    /** Misma política que la ficha de Google Play y la de Apple. */
    const val PRIVACY_POLICY = "https://iaportafolio.com/privacidad#argos"

    /** Código fuente (Apache 2.0) e incidencias. */
    const val SOURCE_CODE = "https://github.com/victalejo/Argos"
}

/** «1.0.0 (1)»: lo que el usuario ve y el código que pide soporte para identificar el build. */
fun versionLabel(versionName: String, versionCode: Int): String = "$versionName ($versionCode)"
