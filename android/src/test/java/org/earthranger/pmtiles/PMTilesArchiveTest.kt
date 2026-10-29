package org.earthranger.pmtiles

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class PMTilesArchiveTest {

  private val fixtures = File(
    System.getProperty("pmtiles.fixtures") ?: "../test/fixtures",
  )

  private val tileTypes = mapOf(
    "mvt" to PMTilesArchive.TILE_TYPE_MVT,
    "png" to PMTilesArchive.TILE_TYPE_PNG,
    "jpeg" to PMTilesArchive.TILE_TYPE_JPEG,
    "webp" to PMTilesArchive.TILE_TYPE_WEBP,
    "avif" to PMTilesArchive.TILE_TYPE_AVIF,
  )

  private fun expected(): List<JSONObject> {
    val array = JSONObject(File(fixtures, "expected.json").readText()).getJSONArray("fixtures")
    return List(array.length()) { array.getJSONObject(it) }
  }

  private fun valid() = expected().filter { it.getBoolean("valid") }

  private fun open(fixture: JSONObject): PMTilesArchive {
    val file = fixture.getString("file")
    val archive = PMTilesArchive.open(File(fixtures, file))
    assertNotNull(file, archive)
    return archive!!
  }

  @Test
  fun invalidFilesDoNotOpen() {
    expected().filter { !it.getBoolean("valid") }.forEach {
      assertNull(it.getString("file"), PMTilesArchive.open(File(fixtures, it.getString("file"))))
    }
  }

  @Test
  fun missingFileDoesNotOpen() {
    assertNull(PMTilesArchive.open(File(fixtures, "does-not-exist.pmtiles")))
  }

  @Test
  fun headers() {
    valid().forEach { fixture ->
      val file = fixture.getString("file")
      val header = fixture.getJSONObject("header")
      open(fixture).use { archive ->
        assertEquals(file, tileTypes[header.getString("tileType")], archive.tileType)
        assertEquals(file, header.getString("contentType"), archive.contentType)
        assertEquals(file, header.getInt("minZoom"), archive.minZoom)
        assertEquals(file, header.getInt("maxZoom"), archive.maxZoom)
      }
    }
  }

  @Test
  fun tiles() {
    valid().forEach { fixture ->
      val file = fixture.getString("file")
      val tiles: JSONArray = fixture.getJSONArray("tiles")
      open(fixture).use { archive ->
        for (i in 0 until tiles.length()) {
          val tile = tiles.getJSONObject(i)
          val z = tile.getInt("z")
          val x = tile.getLong("x")
          val y = tile.getLong("y")
          val label = "$file $z/$x/$y"
          val data = archive.tile(z, x, y)
          if (tile.optBoolean("missing")) {
            assertNull(label, data)
          } else {
            assertNotNull(label, data)
            assertEquals(label, tile.getInt("size"), data!!.size)
            assertEquals(label, tile.getString("sha256"), sha256(data))
          }
        }
      }
    }
  }

  @Test
  fun everyAddressedTileIsReachable() {
    valid().forEach { fixture ->
      open(fixture).use { archive ->
        var count = 0
        for (z in archive.minZoom..archive.maxZoom) {
          for (x in 0 until (1L shl z)) {
            for (y in 0 until (1L shl z)) {
              if (archive.tile(z, x, y) != null) count++
            }
          }
        }
        assertEquals(fixture.getString("file"), fixture.getInt("addressedTiles"), count)
      }
    }
  }

  @Test
  fun closedArchiveCanBeReopened() {
    val fixture = valid().first()
    val first = open(fixture).use { it.tile(0, 0, 0) }
    val second = open(fixture).use { it.tile(0, 0, 0) }
    assertArrayEquals(first, second)
  }

  private fun sha256(data: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
}
