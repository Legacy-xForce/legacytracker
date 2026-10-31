import 'package:flutter/material.dart';

import '../../../data/models/user_model.dart';

/// What a screen reader announces for [person] on the map.
String mapContentsLabel(UserProfile person, {required bool isSelf}) {
  final name = isSelf ? '${person.name} (you)' : person.name;
  if (!person.sharesWithMe) return '$name, location hidden';
  if (person.lastLocation == null) return '$name, no location yet';
  if (!isSelf && person.isStale) return '$name, not heard from in a while';
  return name;
}

/// The map's markers for TalkBack and VoiceOver.
///
/// Mapbox draws annotations as platform-rendered bitmaps, so they have no
/// semantics of their own and a screen-reader user could not enumerate who is
/// on the map. This lists the same people as invisible accessibility nodes; activating one selects that person, exactly as tapping their marker
/// does. It paints nothing and takes no pointer events.
class MapContentsSemantics extends StatelessWidget {
  const MapContentsSemantics({
    super.key,
    required this.selfId,
    required this.people,
    required this.onSelect,
  });

  final String selfId;
  final List<UserProfile> people;
  final ValueChanged<UserProfile> onSelect;

  @override
  Widget build(BuildContext context) {
    // Plain SizedBoxes are not hit-testable and Opacity(0) paints nothing, so
    // the nodes can't take touches. (IgnorePointer would also block the
    // screen reader's own tap action.)
    return Opacity(
      opacity: 0,
      alwaysIncludeSemantics: true,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: 'People on the map',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final person in people)
              Semantics(
                button: true,
                label: mapContentsLabel(person, isSelf: person.id == selfId),
                onTap: () => onSelect(person),
                child: const SizedBox.square(
                  dimension: kMinInteractiveDimension,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
