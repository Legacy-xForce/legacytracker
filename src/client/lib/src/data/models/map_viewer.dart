/// Someone who has the live map open right now, as the server announces it.
class MapViewer {
  const MapViewer({required this.id, required this.name});

  final String id;
  final String name;

  /// The viewers a `viewers` stream message lists, in the order they started
  /// looking, or null for any other message.
  static List<MapViewer>? listFromMessage(Map<String, dynamic> message) {
    if (message['type'] != 'viewers') return null;
    final items = message['viewers'];
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map && item['id'] is String && item['id'] != '')
          MapViewer(
            id: item['id'] as String,
            name: item['name'] is String
                ? item['name'] as String
                : item['id'] as String,
          ),
    ];
  }
}
