# Architecture

Serves tiles from local PMTiles files to Mapbox (`@rnmapbox/maps`) by intercepting Mapbox HTTP requests to a reserved host. No tile server and no changes to Mapbox.

Status: prototype. Vector PMTiles render on iOS and Android.

## Components

```mermaid
flowchart TB
  subgraph App["Host app (e.g. EarthRanger Mobile)"]
    Startup["App start<br/>install(directory)"]
    Map["MapView<br/>VectorSource / RasterSource<br/>tileUrlTemplates = tileUrl(name, ext)"]
    Files[("&lt;directory&gt;/&lt;name&gt;.pmtiles")]
  end

  subgraph Lib["react-native-mapbox-pmtiles"]
    JS["src/index.ts<br/>install · tileUrl · PMTILES_HOST · TileExtension"]
    subgraph Native["Native (Swift on iOS / Kotlin on Android)"]
      Module["RNMapboxPMTiles native module"]
      Interceptor["PMTilesInterceptor<br/>claims https://pmtiles.local/"]
      Registry["Open archives by name<br/>(opened lazily)"]
      Archive["PMTilesArchive<br/>header · Hilbert tile ID · directories<br/>leaf directories · gzip · directory cache"]
    end
  end

  subgraph Mapbox["Mapbox Maps SDK"]
    Renderer["Map renderer"]
    Http["Mapbox Common HttpService"]
    Network(("Network"))
  end

  Startup --> JS -- "NativeModules" --> Module
  Module -- "HttpServiceFactory<br/>set interceptor" --> Interceptor
  Map --> Renderer -- "GET tile URL" --> Http
  Http -- "onRequest" --> Interceptor
  Interceptor -- "other hosts: pass through" --> Http --> Network
  Interceptor -- "pmtiles.local/&lt;name&gt;/z/x/y" --> Registry --> Archive
  Archive -- "byte-range reads" --> Files
  Interceptor -. "200 tile · 204 no tile · 404 bad URL or file" .-> Http
```

## Tile request

```mermaid
sequenceDiagram
  participant R as Mapbox renderer
  participant H as Mapbox HttpService
  participant I as PMTilesInterceptor
  participant A as PMTilesArchive
  participant F as .pmtiles file

  R->>H: GET https://pmtiles.local/counties/4/4/6.mvt
  H->>I: onRequest(request)
  alt host is not pmtiles.local
    I-->>H: continue with original request
  else pmtiles.local
    I->>A: tile(z: 4, x: 4, y: 6) (opens archive on first use)
    A->>F: read root directory (cached)
    opt entry points to a leaf directory
      A->>F: read leaf directory (cached)
    end
    A->>F: read tile bytes
    A-->>I: tile data (gunzipped)
    I-->>H: HttpResponse 200, content-type, cache-control: no-store
  end
  H-->>R: tile
```

## Source layout

| Path | Role |
|---|---|
| `src/index.ts` | JS API: `install(directory)`, `tileUrl(name, ext)`, `PMTILES_HOST`, `TileExtension` type |
| `ios/RNMapboxPMTiles.swift`, `ios/RNMapboxPMTiles.m` | Native module; `install` registers the interceptor |
| `ios/PMTilesInterceptor.swift` | URL routing, archive registry, HTTP responses |
| `ios/PMTilesArchive.swift` | PMTiles v3 reader |
| `android/.../RNMapboxPMTilesModule.kt`, `RNMapboxPMTilesPackage.kt` | Native module and autolinked package |
| `android/.../PMTilesInterceptor.kt` | Same behaviour as iOS |
| `android/.../PMTilesArchive.kt` | Kotlin port of the Swift reader |
| `react-native-mapbox-pmtiles.podspec`, `android/build.gradle` | Depend on Mapbox Common supplied by `@rnmapbox/maps` |
| `test/fixtures/` | Shared PMTiles fixtures, `expected.json` and `generate.py` |
| `Package.swift`, `test/ios/PMTilesArchiveTests.swift` | XCTest for the Swift reader (`yarn test:ios`) |
| `android/src/test/.../PMTilesArchiveTest.kt` | JUnit test for the Kotlin reader (`yarn test:android`) |

## Planned

```mermaid
flowchart LR
  Info["getInfo(name)<br/>bounds · zoom · tile type · vector layers"]
  Close["close(name)<br/>before replace or delete"]
  Chain["Chain to an existing interceptor<br/>(e.g. rnmapbox addCustomHeader)"]
  Turbo["TurboModule spec + release"]

  classDef planned stroke-dasharray: 5 5
  class Info,Close,Chain,Turbo planned
```
