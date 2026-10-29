package org.earthranger.pmtiles

import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import java.io.File

class RNMapboxPMTilesModule(context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {

  override fun getName() = NAME

  @ReactMethod
  fun install(directory: String) {
    PMTilesInterceptor.install(File(directory))
  }

  companion object {
    const val NAME = "RNMapboxPMTiles"
  }
}
