package com.iaportafolio.argos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.ui.theme.ArgosTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            ArgosTheme {
                ServersPlaceholderScreen()
            }
        }
    }
}

/** Pantalla provisional de la fase 0; la lista real de servidores llega en la fase 2. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ServersPlaceholderScreen() {
    Scaffold(
        topBar = { TopAppBar(title = { Text(stringResource(R.string.servers_title)) }) },
    ) { padding ->
        Box(
            modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = stringResource(R.string.servers_empty),
                style = MaterialTheme.typography.bodyLarge,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Preview
@Composable
private fun ServersPlaceholderPreview() {
    ArgosTheme { ServersPlaceholderScreen() }
}
