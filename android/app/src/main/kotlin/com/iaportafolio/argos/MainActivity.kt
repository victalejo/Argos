package com.iaportafolio.argos

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.iaportafolio.argos.ui.navigation.ArgosNavHost
import com.iaportafolio.argos.ui.theme.ArgosTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as ArgosApplication).container
        setContent {
            ArgosTheme {
                ArgosNavHost(container)
            }
        }
    }
}
