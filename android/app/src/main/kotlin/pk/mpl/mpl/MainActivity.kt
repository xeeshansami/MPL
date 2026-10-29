package pk.mpl.mpl

import android.app.Activity
import android.content.Intent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI. Extends AudioServiceActivity so background playback
 * and lock-screen controls (just_audio_background) bind to this activity.
 */
class MainActivity : AudioServiceActivity() {
    private lateinit var bridge: MediaBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = MediaBridge(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mpl/native")
            .setMethodCallHandler(bridge)
    }

    @Deprecated("Required for SAF pickers on FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (::bridge.isInitialized) {
            bridge.onActivityResult(requestCode, resultCode == Activity.RESULT_OK, data)
        }
    }
}
