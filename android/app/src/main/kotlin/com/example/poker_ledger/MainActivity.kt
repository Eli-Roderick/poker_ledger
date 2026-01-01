package com.example.poker_ledger

import android.os.Bundle
import android.view.Window
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Set the window background to match the app theme to prevent white flash
        window.setBackgroundDrawableResource(android.R.color.transparent)
        window.decorView.setBackgroundColor(0xFF111315.toInt())
    }
}
