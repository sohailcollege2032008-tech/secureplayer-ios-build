import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the path to a .sec file delivered via Android ACTION_VIEW intent.
/// Set by main.dart on cold start (getInitialSecFile) and on hot start
/// (onSecFileReceived MethodChannel call). CourseListScreen listens and
/// triggers the import flow when this becomes non-null.
final pendingSecFileProvider = StateProvider<String?>((ref) => null);
