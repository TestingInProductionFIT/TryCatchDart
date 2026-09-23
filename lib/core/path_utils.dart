/// Pure path helpers (data in, data out) so UI/state don't import `dart:io`
/// just to split a filename.
String basename(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf('\\');
  final idx = slash > backslash ? slash : backslash;
  return idx < 0 ? path : path.substring(idx + 1);
}
