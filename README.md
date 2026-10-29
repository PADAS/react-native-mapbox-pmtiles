# react-native-mapbox-pmtiles

Serve tiles from local [PMTiles](https://github.com/protomaps/PMTiles) files to Mapbox in React Native apps built with [`@rnmapbox/maps`](https://github.com/rnmapbox/maps). Works offline, with no tile server and no changes to Mapbox.

> Status: prototype. Vector PMTiles render on iOS and Android. See [Limitations](#limitations).

## How it works

The library registers a Mapbox HTTP interceptor that answers requests to the reserved host `https://pmtiles.local/<name>/{z}/{x}/{y}.<ext>` by reading the tile from `<directory>/<name>.pmtiles`. Requests to any other host pass through to the network. You point a normal `VectorSource` or `RasterSource` at that URL.

See [docs/architecture.md](docs/architecture.md) for diagrams.

## Requirements

- React Native 0.76+ (new architecture supported through the interop layer)
- `@rnmapbox/maps` 10.1+ using the Mapbox Maps SDK v11 (`RNMapboxMapsVersion` 11.x)
- PMTiles v3 files with `gzip` or no compression

## Installation

Add the dependency from GitHub (requires read access to the repo):

```sh
yarn add github:PADAS/react-native-mapbox-pmtiles
cd ios && pod install
```

No changes to `AppDelegate` or `MainApplication` are needed; autolinking registers the native module on both platforms.

### Android: Mapbox Common version

The library compiles against Mapbox Common, which `@rnmapbox/maps` supplies at runtime. It defaults to `24.16.2` (Mapbox Maps 11.16.x). If your app uses a different Mapbox version, set the matching Common version in `android/build.gradle`:

```groovy
buildscript {
  ext {
    PMTilesMapboxCommonVersion = "24.16.2"
  }
}
```

### Local development against a checkout

To work on the library alongside an app, link it instead:

```json
"react-native-mapbox-pmtiles": "link:../react-native-mapbox-pmtiles"
```

Then let Metro watch the folder and resolve the library's imports from the app:

```js
// metro.config.js
const path = require('path');
const pmtiles = path.resolve(__dirname, '../react-native-mapbox-pmtiles');

const config = {
  watchFolders: [pmtiles],
  resolver: { nodeModulesPaths: [path.resolve(__dirname, 'node_modules')] },
};
```

and set `"preserveSymlinks": true` in the app's `tsconfig.json` so `tsc` resolves the library's imports. Restart Metro with `--reset-cache` after changing `metro.config.js`.

## Usage

### 1. Install the interceptor at startup

Call `install` once, before the map renders, with the folder that holds your `.pmtiles` files:

```ts
import { DocumentDirectoryPath } from 'react-native-fs';
import { install } from 'react-native-mapbox-pmtiles';

install(`${DocumentDirectoryPath}/pmtiles`);
```

`install` throws if the native module isn't linked (rebuild the app after adding the library).

### 2. Put files in that folder

Each file is addressed by its name without the extension: `counties.pmtiles` becomes `counties`. Names may contain letters, numbers, `-` and `_`. Files are opened on first use.

### 3. Add a source to the map

```tsx
import { FillLayer, LineLayer, MapView, VectorSource } from '@rnmapbox/maps';
import { tileUrl } from 'react-native-mapbox-pmtiles';

<MapView>
  <VectorSource
    id="counties"
    tileUrlTemplates={[tileUrl('counties', 'mvt')]}
    minZoomLevel={0}
    maxZoomLevel={7}
  >
    <FillLayer
      id="counties-fill"
      sourceLayerID="UScountiesfgb"
      style={{ fillColor: '#ff00ff', fillOpacity: 0.12 }}
    />
    <LineLayer
      id="counties-line"
      sourceLayerID="UScountiesfgb"
      style={{ lineColor: '#8b008b', lineWidth: 1 }}
    />
  </VectorSource>
</MapView>
```

For raster files use a `RasterSource` with `tileUrl(name, 'png')` (or `'jpg'`, `'webp'`) and a `RasterLayer`.

Set `minZoomLevel` / `maxZoomLevel` to the file's zoom range so Mapbox overzooms instead of requesting missing tiles. Vector layers need the file's source-layer names (e.g. from `pmtiles show <file>`).

## API

| Export | Description |
|---|---|
| `install(directory: string): void` | Registers the interceptor and sets the folder files are read from. Calling it again changes the folder and closes open files. |
| `tileUrl(name: string, extension: TileExtension): string` | Returns `https://pmtiles.local/<name>/{z}/{x}/{y}.<extension>` for `tileUrlTemplates`. |
| `PMTILES_HOST` | `https://pmtiles.local` |
| `TileExtension` | `'mvt' \| 'pbf' \| 'png' \| 'jpg' \| 'webp'` |

Responses: `200` with the tile and `cache-control: no-store`, `204` when the file has no tile at that position, `404` for a malformed URL or a missing or invalid file.

## Loading files onto a device for testing

Debug builds only.

```sh
# iOS
xcrun devicectl device copy to --device <device-id> --domain-type appDataContainer \
  --domain-identifier <bundle-id> --source counties.pmtiles \
  --destination Documents/pmtiles/counties.pmtiles

# Android
adb push counties.pmtiles /data/local/tmp/
adb shell "run-as <application-id> sh -c 'mkdir -p files/pmtiles && cp /data/local/tmp/counties.pmtiles files/pmtiles/'"
```

Logs: `PMTiles served …` in the Xcode console, `adb logcat -s PMTiles` on Android.

## Limitations

- **One interceptor per app.** Mapbox allows a single HTTP interceptor. `Mapbox.addCustomHeader` in `@rnmapbox/maps` installs its own and replaces this one.
- **No file metadata yet.** Bounds, zoom range, tile type and vector layer names must be supplied by the app.
- **Files stay open.** Replacing or deleting a file while the app runs keeps serving the old copy until `install` is called again or the app restarts.
- **Offline base style.** Sources are added on top of the Mapbox style, which must already be cached (or replaced by a local `styleJSON`) for the map to load offline.
- **Compression:** `gzip` or none. Brotli and Zstandard are not supported.

## Tests

Both PMTiles readers are tested against the same fixtures and expected results in `test/fixtures/`:

| Fixture | Covers |
|---|---|
| `vector-gzip.pmtiles` | MVT, gzip directories and tiles, root directory only, missing tiles |
| `raster-leaves.pmtiles` | PNG, uncompressed tiles, leaf directories, run-length and deduplicated entries |
| `webp-uncompressed.pmtiles` | WebP, no compression anywhere, `minZoom` above 0 |
| `invalid-magic.pmtiles`, `truncated.pmtiles` | Files that must fail to open |

`expected.json` holds the header values, tile sizes and SHA-256 hashes the readers must produce. It is generated from the tiles `generate.py` writes, not by reading the files back, and the fixtures were checked with the official `pmtiles` Python reader.

```sh
yarn test:ios       # swift test (Package.swift builds only the reader)
yarn test:android   # JUnit via the host app's Gradle; set APP_ROOT if the app isn't at ../er-mobile
yarn fixtures       # regenerate fixtures and expected.json after changing generate.py
```

When adding reader features (e.g. metadata, new compression), add a fixture and its expected values to `generate.py` first, then make both readers pass.

## License

Apache 2.0. See [LICENSE](LICENSE).
