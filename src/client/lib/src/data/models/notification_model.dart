class NotificationItem {
  final int id;
  final String content;
  final bool read;
  final DateTime createdAt;

  NotificationItem({
    required this.id,
    required this.content,
    required this.read,
    required this.createdAt,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> data) {
    return NotificationItem(
      id: data['id'] as int,
      content: data['content'] as String,
      read: data['read'] as bool,
      createdAt: DateTime.tryParse(data['created_at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
