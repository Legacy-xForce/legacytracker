import 'package:flutter/material.dart';

class TrackingProfileEditor extends StatelessWidget {
  const TrackingProfileEditor({
    super.key,
    required this.nameController,
    required this.avatarController,
    required this.onSaveProfile,
  });

  final TextEditingController nameController;
  final TextEditingController avatarController;
  final VoidCallback onSaveProfile;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your profile',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Display name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: avatarController,
            decoration: const InputDecoration(
              labelText: 'Avatar image URL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: onSaveProfile,
                  child: const Text('Save profile'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
