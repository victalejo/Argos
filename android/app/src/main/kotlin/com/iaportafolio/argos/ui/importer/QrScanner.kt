package com.iaportafolio.argos.ui.importer

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.lifecycle.awaitInstance
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.ArgosLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.awaitCancellation
import java.util.concurrent.Executors

/** Resolución de análisis: un QR de pantalla de ~60 módulos se lee bien a 720p. */
private val ANALYSIS_SIZE = Size(1280, 720)

/**
 * Escáner del QR del Mac con permiso de cámara pedido EN EL MOMENTO (con explicación previa).
 * Si se deniega, explica cómo concederlo en Ajustes; el enlace pegado sigue disponible debajo.
 */
@Composable
fun QrScannerSection(onScanned: (String) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val hasCamera = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }
    var granted by remember { mutableStateOf(context.hasCameraPermission()) }
    var denied by rememberSaveable { mutableStateOf(false) }
    var cameraFailed by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { result ->
        granted = result
        denied = !result
    }
    // Al volver de Ajustes el permiso pudo cambiar.
    LifecycleResumeEffect(Unit) {
        granted = context.hasCameraPermission()
        if (granted) denied = false
        onPauseOrDispose { }
    }

    when {
        !hasCamera -> ScannerNotice(stringResource(R.string.import_camera_missing), modifier)
        cameraFailed -> ScannerNotice(stringResource(R.string.import_camera_failed), modifier)
        granted -> CameraPreview(onScanned = onScanned, onFailure = { cameraFailed = true }, modifier = modifier)
        else -> ScannerNotice(
            text = stringResource(if (denied) R.string.import_camera_denied else R.string.import_camera_explanation),
            modifier = modifier,
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { launcher.launch(Manifest.permission.CAMERA) }) {
                    Text(stringResource(R.string.import_camera_allow))
                }
                if (denied) {
                    OutlinedButton(onClick = { context.openAppSettings() }) {
                        Text(stringResource(R.string.import_camera_settings))
                    }
                }
            }
        }
    }
}

@Composable
private fun ScannerNotice(text: String, modifier: Modifier = Modifier, actions: @Composable () -> Unit = {}) {
    Card(modifier = modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(painterResource(R.drawable.ic_qr_code), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Text(text, style = MaterialTheme.typography.bodyMedium)
            actions()
        }
    }
}

/**
 * Vista previa de la cámara trasera + análisis ZXing. La cámara se libera al salir de la
 * composición (pantalla cerrada o QR aceptado) y, por el ciclo de vida, en segundo plano.
 */
@Composable
private fun CameraPreview(onScanned: (String) -> Unit, onFailure: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentOnScanned by rememberUpdatedState(onScanned)
    val currentOnFailure by rememberUpdatedState(onFailure)
    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
    val description = stringResource(R.string.import_camera_preview)

    LaunchedEffect(lifecycleOwner) {
        val main = ContextCompat.getMainExecutor(context)
        val analyzerThread = Executors.newSingleThreadExecutor()
        val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
        val analysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setResolutionStrategy(
                        ResolutionStrategy(ANALYSIS_SIZE, ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
                    )
                    .build(),
            )
            .build()
        analysis.setAnalyzer(analyzerThread, QrCodeAnalyzer({ text -> main.execute { currentOnScanned(text) } }))
        var provider: ProcessCameraProvider? = null
        try {
            val cameras = ProcessCameraProvider.awaitInstance(context)
            provider = cameras
            cameras.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            awaitCancellation()
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            ArgosLog.error(ArgosLog.TAG_UI, "No se pudo abrir la cámara", error)
            currentOnFailure()
        } finally {
            analysis.clearAnalyzer()
            provider?.unbind(preview, analysis)
            analyzerThread.shutdown()
        }
    }

    AndroidView(
        factory = { previewView },
        modifier = modifier.semantics { contentDescription = description },
    )
}

private fun Context.hasCameraPermission(): Boolean =
    ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

private fun Context.openAppSettings() {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
        startActivity(intent)
    } catch (error: android.content.ActivityNotFoundException) {
        ArgosLog.warn(ArgosLog.TAG_UI, "No hay pantalla de ajustes de la app", error)
    }
}
