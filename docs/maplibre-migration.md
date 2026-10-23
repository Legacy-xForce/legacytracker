# MapLibre migration assessment

Status: research notes, October 2026. The web client has been migrated; the app decision is still open.

## Summary

- **Web (Vue):** migrated from Leaflet to MapLibre GL JS with OpenFreeMap vector tiles. The original estimate was 1–2 weeks including a vector style and QA; risk was low-to-medium.
- **App (Flutter + flutter_map):** feasible, but it is a platform-view migration, not a drop-in replacement. Roughly 3–5 weeks for full parity with the `maplibre` package, medium-to-high risk.
- **Switching engines while keeping the current raster tiles will only partly fix slow zoom.** The real win comes from vector tiles and a faster tile source. Changing the engine alone does not remove the per-zoom-level tile fetches.

## Why zooming feels slow today

Before the web migration, both clients used 256 px raster tiles:

- Web: Leaflet 1.9 (`src/web/src/lib/tiles.ts`) with OSM, Esri and OpenTopoMap. Now MapLibre with OpenFreeMap vector tiles.
- App: `flutter_map` 8.3 (`src/client/lib/src/features/tracking/widgets/map_layers.dart`) with the same raster sources.

With raster tiles, every zoom step is a new set of PNG/JPEG requests and decodes. There is no fractional-zoom rendering; the map can only scale the old level while the new one arrives.

The app has a second cost: `tracking_map_tab.dart` rebuilds the marker layer through `MapCamera.of(context)` and re-runs custom clustering on every camera change, with rich marker widgets (avatar, pulse, heading beam, speed/battery badges). Some zoom jank may be Flutter-side rather than tile-side, so profile before rewriting.

`tile.openstreetmap.org` is also not intended for production app traffic. The app using it directly is against OSM's tile usage policy, so the tile source needs to change regardless.

## What MapLibre buys

| | Existing raster tiles | Vector tiles |
|---|---|---|
| MapLibre web | Smoother GPU zoom/fade; still loads tiles per zoom level | Continuous zoom, far fewer requests, much smoother |
| MapLibre app | Native GPU map; tile fetch still per zoom | Native smooth zoom, better caching/offline |

Conclusion: MapLibre plus vector tiles fixes the problem. MapLibre with the current raster sources is only a moderate improvement.

## Web migration (done)

The Leaflet-specific surface was about 1,200 lines:

- `src/web/src/components/PeersMap.vue` — map, custom clustering, follow camera, marker glides
- `src/web/src/components/ReplayLayer.vue`, `EventsLayer.vue`, `CheckpointsLayer.vue`
- `src/web/src/lib/camera.ts`, `motion.ts`, `vueMarker.ts`, `tiles.ts`, `mapContext.ts`
- Leaflet CSS in `main.ts` and `style.css`
- tests `map-logic.test.ts`, `peers-map.test.ts`, `layers.test.ts`

Most concepts map cleanly:

- `L.marker` + `L.divIcon` → `new maplibregl.Marker({ element })`; Vue marker components keep working.
- `panBy`, `project`/`unproject`, `flyTo`, `fitBounds`, `maxBounds`, `getZoom` → all exist.
- Custom clustering stays; replace `L.Point`/`L.LatLng` with plain objects and Web Mercator math.
- Tooltips/popups need rewriting; checkpoint circles (metres) become GeoJSON polygons; route polylines become line layers.
- `marker.setZIndexOffset` → DOM `style.zIndex`.

Testing was the main friction: MapLibre needs WebGL, which jsdom does not provide. The web suite mocks the library in `src/test/maplibre-mock.ts`; pure projection, cluster and motion tests stay real. Also note the bundle growth (roughly +200 KB gzip versus Leaflet's ~40 KB) and that MapLibre GL JS v6 requires WebGL2 (v5 if older browsers matter).

**Original estimate: 5–10 working days including a vector style, visual QA and tests. Risk: low-to-medium. Actual web migration: done.**

### Chosen web approach

- Use `maplibre-gl` directly (no Vue wrapper).
- Standard basemap: OpenFreeMap vector style (free, no API key), configurable with `VITE_MAP_STYLE_URL`.
- Satellite: Esri World Imagery plus reference labels as raster sources in a MapLibre style.
- Terrain: OpenTopoMap as a raster source.
- Keep the existing custom Vue marker components and clustering logic; only the map/geometry plumbing changes.
- Keep camera maths as pure functions and mock MapLibre in jsdom tests.

### What changed

- `leaflet` and `@types/leaflet` were removed; `maplibre-gl` v6 is the only map dependency.
- `src/lib/geo.ts` holds plain `LatLng` values and the checkpoint circle polygon.
- `src/lib/maplibre.ts` points MapLibre at Vite's fingerprinted worker asset through `setWorkerUrl`; without it the library looks for a worker next to the bundle, where bundlers do not put it.
- `PeersMap.vue`, `EventsLayer.vue`, `CheckpointsLayer.vue` and `ReplayLayer.vue` use MapLibre sources/layers and DOM markers. Checkpoints are GeoJSON polygons; events, peers and the replay rider stay Vue-rendered marker elements.
- Camera, motion and marker helpers work with plain coordinates and Web Mercator maths. `fitBounds`/`flyTo` durations are milliseconds now.
- The CSP allows OpenFreeMap styles, tiles, glyphs and sprites, and `worker-src 'self' blob:` for the MapLibre worker.
- jsdom tests use `src/test/maplibre-mock.ts`, so the suite does not need WebGL.
- Browser QA covered the OpenFreeMap style, all three map styles, clustering, checkpoints, event popups, replay route/playback and the production build with the Cloudflare `_headers` CSP.

Bundle note: the map chunk grows to roughly 1.2 MB minified (about 325 KB gzip), against Leaflet's much smaller payload. MapLibre is loaded only with the map view, which is already lazy-loaded.

## App migration

Options:

1. **`maplibre` 0.3.x (josxha)** — native MapLibre on Android/iOS plus web. Supports `WidgetLayer` for arbitrary Flutter widgets. This is the only good fit for the rich markers. Risks: young 0.3.x package with a single maintainer; `WidgetLayer` lags behind the native map during pan/zoom because it is a platform view and widgets are repositioned after native camera events; the widget layer has no clustering, so custom clustering stays and has to project through `MapController.toScreenLocations` rather than local Dart math.
2. **`maplibre_gl`** — more mature, but annotations only. The rich `TrackedUserMarker` and cluster widgets would be lost or need bitmap rendering. Not recommended.
3. **Stay on `flutter_map` with vector tiles** (`vector_map_tiles` / `vector_tile_renderer`) plus caching. Much smaller change; keeps widgets, clustering, camera math and tests. Lower performance ceiling because vector rendering happens in Dart rather than native GPU. Benchmark before choosing.

With the `maplibre` package:

- `minZoom`/`maxZoom`/`maxBounds` cover the world bounds constraint.
- `fitBounds`/`animateCamera` support padding, so the bottom-sheet inset logic ports.
- `CircleLayer` supports radius in metres (checkpoints), polylines are available, `WidgetLayer` keeps marker widgets nearly unchanged.
- The custom 15° rotation-threshold gesture is likely replaced by native rotation plus a compass/reset button.
- iOS requires Swift Package Manager enabled (currently CocoaPods, iOS 13 target).
- Android platform view: map widgets cannot be meaningfully widget-tested; gesture/zoom QA needs emulator/device runs. `lib/main_mapcheck.dart` is the right harness.
- APK size: the MapLibre Android AAR is about 19 MB compressed with about 50 MB of `.so` across ABIs. A universal release APK grows by roughly 15–20 MB; per-ABI splits would cut that but complicate the self-update flow (the server serves one APK).

**Estimate: 3–5 days for a realistic spike in `main_mapcheck.dart`; 3–5 weeks for full parity across live map, replay and checkpoint editor, plus device QA. Risk: medium-to-high.**

## Recommended sequence

1. Decide the tile source (vector style: OpenFreeMap, self-hosted Protomaps/PMTiles, or a paid provider). Keep Esri satellite as a raster layer. This is the actual performance fix and resolves the OSM policy issue.
2. ~~Migrate the web to MapLibre plus the vector standard style.~~ Done; measure it in daily use.
3. Spike the app with `maplibre` in `main_mapcheck.dart`: a few live markers, clustering, follow camera, sheet inset, pinch/rotate. Measure marker lag and APK size.
4. Choose between full `maplibre` parity and `flutter_map` plus vector tiles/caching.
5. Port the app in stages: live map → session replay → checkpoint editor.

## Effort summary

For one developer familiar with the codebase:

| Scope | Time | Risk | Status |
|---|---|---|---|
| Web only | 1–2 weeks | Low-medium | Done |
| App spike | 3–5 days | Medium | Open |
| App full `maplibre` | 3–5 weeks | Medium-high | Open |
| App vector tiles on `flutter_map` | 3–8 days | Low-medium | Open |
| Both, end to end | 5–8 weeks | Medium-high | Web done |

The app estimates assume the web experience has been measured first; they have not been revised since the web migration.
