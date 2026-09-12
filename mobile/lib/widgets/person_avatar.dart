import 'package:flutter/material.dart';

import '../models/person.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Round initials avatar. [colour] may be a Color or a '#RRGGBB' string via
/// [colourHex]; falls back to a seeded palette colour.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar(this.initials, {super.key, this.colour, this.colourHex, this.size = 32, this.seed, this.tooltip, this.outlined = false});

  /// Build from a [Person].
  PersonAvatar.person(Person p, {Key? key, double size = 32, bool outlined = false})
      : this(p.initialsOrDerived, key: key, colour: p.colour, size: size, tooltip: p.name, outlined: outlined);

  final String initials;
  final Color? colour;
  final String? colourHex;
  final double size;
  /// Used to pick a stable fallback colour when none is given.
  final Object? seed;
  final String? tooltip;
  /// White ring — for stacked avatar rows.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final c = colour ?? (colourHex != null ? DispatchColors.parseHex(colourHex, fallback: DispatchColors.forSeed(seed ?? initials)) : DispatchColors.forSeed(seed ?? initials));
    final w = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: outlined ? Border.all(color: Theme.of(context).colorScheme.surface, width: 2) : null,
      ),
      child: Text(
        initials.toUpperCase(),
        style: DispatchTheme.manrope(fontSize: size * 0.36, fontWeight: FontWeight.w800, color: Colors.white, height: 1, letterSpacing: -0.2),
      ),
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

/// Overlapping row of avatars, with a '+N' overflow bubble.
class AvatarStack extends StatelessWidget {
  const AvatarStack(this.people, {super.key, this.size = 28, this.max = 3, this.overlap = 0.3});
  final List<Person> people;
  final double size;
  final int max;
  final double overlap;

  @override
  Widget build(BuildContext context) {
    final shown = people.take(max).toList();
    final extra = people.length - shown.length;
    final step = size * (1 - overlap);
    final count = shown.length + (extra > 0 ? 1 : 0);
    return SizedBox(
      width: count == 0 ? 0 : size + step * (count - 1),
      height: size,
      child: Stack(children: [
        for (var i = 0; i < shown.length; i++) Positioned(left: i * step, child: PersonAvatar.person(shown[i], size: size, outlined: true)),
        if (extra > 0)
          Positioned(
            left: shown.length * step,
            child: Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: DispatchColors.surfaceAlt, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2)),
              child: Text('+$extra', style: DispatchTheme.manrope(fontSize: size * 0.34, fontWeight: FontWeight.w800, color: DispatchColors.ink)),
            ),
          ),
      ]),
    );
  }
}
