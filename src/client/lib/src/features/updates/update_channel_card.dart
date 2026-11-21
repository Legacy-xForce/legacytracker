import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'update_channel.dart';

/// Picks which release channel the native updater follows. The choice is saved
/// on this device and takes effect as soon as it is tapped.
class UpdateChannelCard extends StatelessWidget {
  const UpdateChannelCard({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<UpdateChannelSettings>();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Update channel'),
            const SizedBox(height: 4),
            Text(
              settings.channel.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<UpdateChannel>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: UpdateChannel.stable,
                    icon: Icon(Icons.verified_outlined),
                    label: Text('Stable'),
                  ),
                  ButtonSegment(
                    value: UpdateChannel.nightly,
                    icon: Icon(Icons.science_outlined),
                    label: Text('Nightly'),
                  ),
                ],
                selected: {settings.channel},
                onSelectionChanged: (selection) =>
                    settings.setChannel(selection.first),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
