import 'package:flutter/material.dart';

import '../../../data/models/location_model.dart';

class TrackingHistorySection extends StatelessWidget {
  const TrackingHistorySection({super.key, required this.history});

  final List<LocationPoint> history;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12.0, horizontal: 14.0),
        child: Text('No history yet.'),
      );
    }

    return Column(
      children: history.take(6).map((point) {
        return ListTile(
          title: Text(
            '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
          ),
          subtitle: Text(
            '${point.timestamp.hour}:${point.timestamp.minute.toString().padLeft(2, '0')} • ${point.speed.toStringAsFixed(1)} m/s',
          ),
        );
      }).toList(),
    );
  }
}
