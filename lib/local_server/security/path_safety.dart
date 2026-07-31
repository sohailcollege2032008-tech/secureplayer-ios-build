/// True if a URL-supplied path segment could escape the directory it is
/// meant to be resolved inside. Shelf route parameters arrive as raw
/// strings and get interpolated straight into filesystem paths by the
/// handlers, so every segment used that way must be checked first.
///
/// Note: `file_handler.dart` still carries its own private copy of this
/// rule. Left alone deliberately rather than migrated in the same change
/// that fixed an unrelated FairPlay bug — it guards a .sec path that is
/// live in production on Android/Windows and is not worth disturbing here.
bool hasPathTraversal(String segment) =>
    segment.contains('/') || segment.contains('\\') || segment.contains('..');
