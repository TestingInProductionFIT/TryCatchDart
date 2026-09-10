/// SharedPreferences keys. Single format, no versioning — there is one
/// release, so keys carry no version suffix.
abstract final class PrefsKeys {
  /// JSON-encoded [WorkspaceState].
  static const String workspaces = 'trycatch.workspaces';

  /// JSON-encoded [LaunchSiteState].
  static const String launchSites = 'trycatch.launch_sites';

  /// Dark-mode flag.
  static const String darkMode = 'trycatch.dark_mode';
}
