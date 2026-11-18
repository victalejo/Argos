package com.iaportafolio.argos.ui.doctor

import android.os.Build
import androidx.compose.runtime.Composable
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.iaportafolio.argos.AppContainer
import com.iaportafolio.argos.BuildConfig
import com.iaportafolio.argos.core.doctor.DiagnosticAppInfo

/** Versión, variante, sistema y modelo (nada personal) para «Copiar diagnóstico». */
internal fun currentDiagnosticAppInfo(): DiagnosticAppInfo = DiagnosticAppInfo(
    version = BuildConfig.VERSION_NAME,
    build = BuildConfig.VERSION_CODE.toString(),
    variant = if (BuildConfig.DEBUG) "Android (depuración)" else "Google Play",
    system = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
    deviceModel = "${Build.MANUFACTURER} ${Build.MODEL}",
)

/** «Doctor del servidor» de [serverId]. */
@Composable
internal fun doctorViewModel(container: AppContainer, serverId: String): DoctorViewModel = viewModel(
    key = "doctor:$serverId",
    factory = viewModelFactory {
        initializer { DoctorViewModel(serverId, container.servers, container.services, container.io, currentDiagnosticAppInfo()) }
    },
)
