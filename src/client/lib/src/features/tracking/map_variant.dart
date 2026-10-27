/// Mapbox Standard's built-in lighting presets.
enum MapLightPreset { dawn, day, dusk, night }

/// What the user picked: a fixed lighting preset, or Auto to follow the
/// local clock - the web's `MapVariant` (issue #86) in miniature.
enum MapVariant {
  auto('Auto'),
  dawn('Dawn'),
  day('Day'),
  dusk('Dusk'),
  night('Night');

  const MapVariant(this.label);

  final String label;
}

/// Auto's local-time bands, same as the web: dawn 05-08, day 08-17,
/// dusk 17-20, night the rest.
MapLightPreset presetForTime(DateTime at) {
  final hour = at.hour;
  if (hour >= 5 && hour < 8) return MapLightPreset.dawn;
  if (hour >= 8 && hour < 17) return MapLightPreset.day;
  if (hour >= 17 && hour < 20) return MapLightPreset.dusk;
  return MapLightPreset.night;
}

/// Turns the stored preference into the preset Mapbox should show now.
MapLightPreset resolveMapPreset(MapVariant variant, DateTime at) =>
    variant == MapVariant.auto
    ? presetForTime(at)
    : MapLightPreset.values[variant.index - 1];

/// Satellite imagery is photographic, so the basemap's lighting preset
/// cannot reach it: the raster layers are dimmed and desaturated to match
/// each preset, with the same factors the web map uses.
({double brightness, double saturation}) satelliteLightFor(
  MapLightPreset preset,
) => switch (preset) {
  MapLightPreset.dawn => (brightness: 0.65, saturation: -0.1),
  MapLightPreset.day => (brightness: 1, saturation: 0),
  MapLightPreset.dusk => (brightness: 0.6, saturation: -0.05),
  MapLightPreset.night => (brightness: 0.45, saturation: -0.25),
};