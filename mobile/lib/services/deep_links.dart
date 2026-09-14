import '../shell/nav.dart';

/// Turns a link the OS hands the app into an in-app location (MOB-04).
///
/// Accepted forms:
///
///     dispatch://items/WI-1042                          → /items/WI-1042
///     dispatch://changes/12                             → /changes/12
///     dispatch://my-week                                → /my-week
///     dispatch://pipeline?q=ingest                      → /pipeline?q=ingest
///     https://host/mobile/build/web/#/items/WI-1042     → /items/WI-1042   (App Link / Universal Link to the hosted web build)
///     https://host/mobile/build/web/changes/12          → /changes/12      (path form, if the host serves path URLs)
///     /items/WI-1042                                    → /items/WI-1042   (a notification's `link`, already an app path)
///
/// Returns null for anything that is not a Dispatch route, so the caller can fall back to home
/// rather than land on "Page not found" from a stale or malformed link.
class DeepLinks {
  DeepLinks._();

  /// Custom URL scheme registered in AndroidManifest.xml and Info.plist.
  static const String scheme = 'dispatch';

  /// Where the web build is served from; stripped from https links.
  static const String webPathPrefix = '/mobile/build/web';

  static final Set<String> _static = {
    Routes.overview, Routes.pipeline, Routes.schedule, Routes.changes, Routes.team, Routes.estimates, Routes.benefits,
    Routes.reports, Routes.settings, Routes.myWeek, Routes.addWork, Routes.notifications, Routes.more,
    '/schedule/versions', '/schedule/scenarios',
  };

  static final List<RegExp> _dynamic = [
    RegExp(r'^/items/[A-Za-z0-9._-]+$'),
    RegExp(r'^/items/[A-Za-z0-9._-]+/estimate$'),
    RegExp(r'^/changes/\d+$'),
    RegExp(r'^/people/\d+$'),
  ];

  /// True when [path] (no query) is a route the app can show.
  static bool isRoute(String path) => _static.contains(path) || _dynamic.any((r) => r.hasMatch(path));

  /// True when [uri] needs mapping before go_router can match it.
  static bool needsMapping(Uri uri) => uri.scheme.isNotEmpty || uri.path.startsWith(webPathPrefix);

  static String? toRoute(Uri uri) {
    final Uri inner;
    switch (uri.scheme) {
      case scheme:
        // dispatch://items/WI-1042 parses as host 'items', path '/WI-1042'; dispatch:///items/… as path only.
        inner = Uri(path: uri.host.isEmpty ? uri.path : '/${uri.host}${uri.path}', query: uri.hasQuery ? uri.query : null);
      case 'http':
      case 'https':
        if (uri.fragment.startsWith('/')) {
          inner = Uri.parse(uri.fragment);
        } else {
          var p = uri.path;
          if (p.startsWith(webPathPrefix)) p = p.substring(webPathPrefix.length);
          inner = Uri(path: p.isEmpty ? '/' : p, query: uri.hasQuery ? uri.query : null);
        }
      case '':
        inner = uri;
      default:
        return null;
    }
    var path = inner.path;
    if (!path.startsWith('/')) path = '/$path';
    if (path.length > 1 && path.endsWith('/')) path = path.substring(0, path.length - 1);
    if (!isRoute(path)) return null;
    return inner.hasQuery && inner.query.isNotEmpty ? '$path?${inner.query}' : path;
  }
}
