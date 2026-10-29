package org.earthranger.pmtiles

import java.io.ByteArrayInputStream
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.GZIPInputStream

class PMTilesArchive private constructor(
  private val file: RandomAccessFile,
  private val rootOffset: Long,
  private val rootLength: Long,
  private val leafOffset: Long,
  private val dataOffset: Long,
  private val internalCompression: Int,
  private val tileCompression: Int,
  val tileType: Int,
  val minZoom: Int,
  val maxZoom: Int,
) : Closeable {

  private class Entry(val tileId: Long, val offset: Long, val length: Long, val runLength: Long)

  private val directoryCache = HashMap<Long, List<Entry>>()

  val contentType: String
    get() = when (tileType) {
      TILE_TYPE_MVT -> "application/x-protobuf"
      TILE_TYPE_PNG -> "image/png"
      TILE_TYPE_JPEG -> "image/jpeg"
      TILE_TYPE_WEBP -> "image/webp"
      TILE_TYPE_AVIF -> "image/avif"
      else -> "application/octet-stream"
    }

  @Synchronized
  fun tile(z: Int, x: Long, y: Long): ByteArray? {
    if (z < minZoom || z > maxZoom || x < 0 || y < 0 || x >= (1L shl z) || y >= (1L shl z)) return null

    val tileId = tileId(z, x, y)
    var offset = rootOffset
    var length = rootLength

    repeat(MAX_DIRECTORY_DEPTH) {
      val entry = directory(offset, length)?.let { find(tileId, it) } ?: return null
      if (entry.runLength > 0) {
        val data = read(dataOffset + entry.offset, entry.length) ?: return null
        return if (tileCompression == COMPRESSION_GZIP) gunzip(data) else data
      }
      offset = leafOffset + entry.offset
      length = entry.length
    }
    return null
  }

  @Synchronized
  override fun close() {
    file.close()
  }

  private fun directory(offset: Long, length: Long): List<Entry>? {
    directoryCache[offset]?.let { return it }
    val raw = read(offset, length) ?: return null
    val data = (if (internalCompression == COMPRESSION_GZIP) gunzip(raw) else raw) ?: return null
    val entries = deserializeDirectory(data) ?: return null
    if (directoryCache.size >= MAX_CACHED_DIRECTORIES) {
      directoryCache.clear()
    }
    directoryCache[offset] = entries
    return entries
  }

  private fun read(offset: Long, length: Long): ByteArray? {
    if (length < 0 || length > Int.MAX_VALUE || offset + length > file.length()) return null
    val data = ByteArray(length.toInt())
    file.seek(offset)
    file.readFully(data)
    return data
  }

  companion object {
    private const val HEADER_LENGTH = 127
    private const val MAX_CACHED_DIRECTORIES = 100
    private const val MAX_DIRECTORY_DEPTH = 4
    private const val COMPRESSION_GZIP = 2

    const val TILE_TYPE_MVT = 1
    const val TILE_TYPE_PNG = 2
    const val TILE_TYPE_JPEG = 3
    const val TILE_TYPE_WEBP = 4
    const val TILE_TYPE_AVIF = 5

    private val MAGIC = "PMTiles".toByteArray(Charsets.US_ASCII)

    fun open(path: File): PMTilesArchive? {
      val file = try {
        RandomAccessFile(path, "r")
      } catch (e: Exception) {
        return null
      }
      val header = ByteArray(HEADER_LENGTH)
      val isValid = try {
        file.length() >= HEADER_LENGTH &&
          file.read(header) == HEADER_LENGTH &&
          header.copyOfRange(0, MAGIC.size).contentEquals(MAGIC) &&
          header[7].toInt() == 3
      } catch (e: Exception) {
        false
      }
      if (!isValid) {
        file.close()
        return null
      }

      val buffer = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
      return PMTilesArchive(
        file = file,
        rootOffset = buffer.getLong(8),
        rootLength = buffer.getLong(16),
        leafOffset = buffer.getLong(40),
        dataOffset = buffer.getLong(56),
        internalCompression = header[97].toInt() and 0xFF,
        tileCompression = header[98].toInt() and 0xFF,
        tileType = header[99].toInt() and 0xFF,
        minZoom = header[100].toInt() and 0xFF,
        maxZoom = header[101].toInt() and 0xFF,
      )
    }

    private fun tileId(z: Int, x: Long, y: Long): Long {
      val base = ((1L shl (2 * z)) - 1) / 3
      val n = 1L shl z
      var tx = x
      var ty = y
      var d = 0L
      var s = n shr 1
      while (s > 0) {
        val rx = if (tx and s > 0) 1L else 0L
        val ry = if (ty and s > 0) 1L else 0L
        d += s * s * ((3 * rx) xor ry)
        if (ry == 0L) {
          if (rx == 1L) {
            tx = n - 1 - tx
            ty = n - 1 - ty
          }
          val swap = tx
          tx = ty
          ty = swap
        }
        s = s shr 1
      }
      return base + d
    }

    private fun find(tileId: Long, entries: List<Entry>): Entry? {
      var lo = 0
      var hi = entries.size - 1
      while (lo <= hi) {
        val mid = (lo + hi) ushr 1
        val diff = tileId - entries[mid].tileId
        when {
          diff > 0 -> lo = mid + 1
          diff < 0 -> hi = mid - 1
          else -> return entries[mid]
        }
      }
      if (hi >= 0) {
        val entry = entries[hi]
        if (entry.runLength == 0L || tileId - entry.tileId < entry.runLength) {
          return entry
        }
      }
      return null
    }

    private fun deserializeDirectory(bytes: ByteArray): List<Entry>? {
      var position = 0

      fun varint(): Long? {
        var result = 0L
        var shift = 0
        while (position < bytes.size && shift < 64) {
          val byte = bytes[position].toInt() and 0xFF
          position += 1
          result = result or ((byte and 0x7F).toLong() shl shift)
          if (byte < 0x80) {
            return result
          }
          shift += 7
        }
        return null
      }

      val rawCount = varint() ?: return null
      if (rawCount < 0 || rawCount > bytes.size) return null
      val count = rawCount.toInt()
      val tileIds = LongArray(count)
      val runLengths = LongArray(count)
      val lengths = LongArray(count)
      val offsets = LongArray(count)

      var lastId = 0L
      for (i in 0 until count) {
        lastId += varint() ?: return null
        tileIds[i] = lastId
      }
      for (i in 0 until count) {
        runLengths[i] = varint() ?: return null
      }
      for (i in 0 until count) {
        lengths[i] = varint() ?: return null
      }
      for (i in 0 until count) {
        val value = varint() ?: return null
        if (value == 0L && i == 0) return null
        offsets[i] = if (value == 0L) offsets[i - 1] + lengths[i - 1] else value - 1
      }

      return List(count) { Entry(tileIds[it], offsets[it], lengths[it], runLengths[it]) }
    }

    private fun gunzip(data: ByteArray): ByteArray? = try {
      GZIPInputStream(ByteArrayInputStream(data)).use { it.readBytes() }
    } catch (e: Exception) {
      null
    }
  }
}
