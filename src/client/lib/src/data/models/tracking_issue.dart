/// Phone settings that stop or delay location updates, as a device reports
/// them (`tracking_issues` on the stream). The codes are the server's closed
/// set (`services/tracking-issues.ts`); the declaration order is the display
/// order, most blocking first. The web client keeps the same wording.
enum TrackingIssue {
  locationServicesOff('location_services_off'),
  locationPermission('location_permission'),
  backgroundLocation('background_location'),
  preciseLocation('precise_location'),
  batteryOptimization('battery_optimization');

  const TrackingIssue(this.code);

  final String code;

  /// Keeps the codes this build knows, in display order; anything else
  /// (a newer client's code, a malformed value) is ignored.
  static List<TrackingIssue> parse(Object? value) {
    if (value is! List) return const [];
    return [
      for (final issue in TrackingIssue.values)
        if (value.contains(issue.code)) issue,
    ];
  }

  String get title => switch (this) {
    locationServicesOff => 'Location is turned off',
    locationPermission => 'Location permission is missing',
    backgroundLocation => 'Location only works while the app is open',
    preciseLocation => 'Precise location is off',
    batteryOptimization => 'Battery settings are delaying updates',
  };

  /// One sentence on what's wrong and what the person should do. [self] is
  /// whether the viewer is the one with the problem ("You should…").
  String summary({required String name, required bool self}) {
    final who = self ? 'You' : name;
    final their = self ? 'your' : 'their';
    return switch (this) {
      locationServicesOff =>
        "Location is turned off for $their whole phone, so it can't be updated.",
      locationPermission =>
        "Legacy Tracker isn't allowed to use $their phone's location.",
      backgroundLocation =>
        '$who should allow Location “All the time” for Legacy Tracker, or '
            'updates stop when the app is closed.',
      preciseLocation =>
        '$who should turn on Precise location for Legacy Tracker; '
            "approximate positions can't record routes.",
      batteryOptimization =>
        "$who should update $their phone's Battery Optimization settings.",
    };
  }

  /// How to fix it on the phone, in order.
  List<String> get steps => switch (this) {
    locationServicesOff => const [
      'Open the phone’s Settings and go to Location.',
      'Turn Location on.',
    ],
    locationPermission || backgroundLocation => const [
      'Open the phone’s Settings and find Legacy Tracker under Apps.',
      'Open its Location permission and choose “Allow all the time”.',
    ],
    preciseLocation => const [
      'Open the phone’s Settings and find Legacy Tracker under Apps.',
      'Open its Location permission and turn on “Use precise location”.',
    ],
    batteryOptimization => const [
      'Open the phone’s Settings and find Legacy Tracker under Apps.',
      'Open Battery and choose “Unrestricted” (or turn battery optimization '
          'off for the app).',
    ],
  };
}
