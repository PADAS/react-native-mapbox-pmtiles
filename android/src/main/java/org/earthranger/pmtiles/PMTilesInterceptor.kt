package org.earthranger.pmtiles

import android.util.Log
import com.mapbox.bindgen.ExpectedFactory
import com.mapbox.common.HttpRequest
import com.mapbox.common.HttpRequestError
import com.mapbox.common.HttpRequestOrResponse
import com.mapbox.common.HttpResponse
import com.mapbox.common.HttpResponseData
import com.mapbox.common.HttpServiceFactory
import com.mapbox.common.HttpServiceInterceptorInterface
import com.mapbox.common.HttpServiceInterceptorRequestContinuation
import com.mapbox.common.HttpServiceInterceptorResponseContinuation
import java.io.File

object PMTilesInterceptor : HttpServiceInterceptorInterface {
  const val HOST = "https://pmtiles.local/"
  private const val TAG = "PMTiles"
  private val NAME_PATTERN = Regex("^[A-Za-z0-9_-]+$")

  private var directory: File? = null
  private val archives = HashMap<String, PMTilesArchive>()

  fun install(directory: File) {
    synchronized(this) {
      this.directory = directory
      archives.values.forEach { it.close() }
      archives.clear()
    }
    HttpServiceFactory.setHttpServiceInterceptor(this)
  }

  override fun onRequest(request: HttpRequest, continuation: HttpServiceInterceptorRequestContinuation) {
    if (!request.url.startsWith(HOST)) {
      continuation.run(HttpRequestOrResponse(request))
      return
    }
    continuation.run(HttpRequestOrResponse(response(request)))
  }

  override fun onResponse(response: HttpResponse, continuation: HttpServiceInterceptorResponseContinuation) {
    continuation.run(response)
  }

  private fun response(request: HttpRequest): HttpResponse {
    val parts = request.url.removePrefix(HOST).substringBefore('?').split('/')
    val archive = if (parts.size == 4) archive(parts[0]) else null
    val z = parts.getOrNull(1)?.toIntOrNull()
    val x = parts.getOrNull(2)?.toLongOrNull()
    val y = parts.getOrNull(3)?.substringBefore('.')?.toLongOrNull()

    if (archive == null || z == null || x == null || y == null) {
      Log.w(TAG, "not found ${request.url}")
      return makeResponse(request, 404, ByteArray(0), hashMapOf())
    }

    val tile = archive.tile(z, x, y) ?: return makeResponse(request, 204, ByteArray(0), hashMapOf())

    Log.i(TAG, "served ${request.url} ${tile.size} bytes")
    return makeResponse(
      request,
      200,
      tile,
      hashMapOf("content-type" to archive.contentType, "cache-control" to "no-store"),
    )
  }

  @Synchronized
  private fun archive(name: String): PMTilesArchive? {
    if (!NAME_PATTERN.matches(name)) return null
    archives[name]?.let { return it }
    val archive = directory?.let { PMTilesArchive.open(File(it, "$name.pmtiles")) } ?: return null
    archives[name] = archive
    return archive
  }

  private fun makeResponse(
    request: HttpRequest,
    code: Int,
    data: ByteArray,
    headers: HashMap<String, String>,
  ): HttpResponse {
    val responseData = HttpResponseData(headers, code, data)
    return HttpResponse(0, request, ExpectedFactory.createValue<HttpRequestError, HttpResponseData>(responseData))
  }
}
