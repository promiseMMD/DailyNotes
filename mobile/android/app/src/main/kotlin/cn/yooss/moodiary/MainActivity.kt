package cn.yooss.moodiary

import android.media.MediaCodecList
import android.os.Build
import android.os.Bundle
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.renderer.FlutterRenderer

class MainActivity : FlutterFragmentActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "moodiary.mod/lan_foreground")
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "start" -> {
            try {
              ContextCompat.startForegroundService(
                this, Intent(this, ModLanForegroundService::class.java))
              result.success(null)
            } catch (e: Exception) { result.error("FG_SERVICE", e.message, null) }
          }
          "stop" -> {
            stopService(Intent(this, ModLanForegroundService::class.java))
            result.success(null)
          }
          else -> result.notImplemented()
        }
      }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    // Avoid HiSilicon AVC failures with ImageReader; Flutter's workaround only covers API <= 29.
    // Set before engine initialization. See https://github.com/flutter/flutter/issues/188560
    if (Build.VERSION.SDK_INT > 29 && hasHiSiliconAvcDecoder) {
      FlutterRenderer.debugForceSurfaceProducerGlTextures = true
    }
    super.onCreate(savedInstanceState)
  }

  private val hasHiSiliconAvcDecoder: Boolean by lazy {
    runCatching {
      MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { codec ->
        codec.name.contains("hisi", true) &&
          codec.supportedTypes.any { it.equals("video/avc", true) }
      }
    }.getOrDefault(false)
  }
}
