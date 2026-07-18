import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../errors/app_exception.dart';

const _project = 'stud-future-platform-db';
const _resourcePrefix = 'projects/$_project/databases/(default)/documents';
const _base = 'https://firestore.googleapis.com/v1/$_resourcePrefix';

// ─── Sentinels ───────────────────────────────────────────────────────────────

/// Use in place of FieldValue.delete() — field will be removed on updateDoc.
const fsDelete = _FsDel._();
/// Use in place of FieldValue.serverTimestamp() — set to DateTime.now().
const fsNow = _FsNow._();

class _FsDel { const _FsDel._(); }
class _FsNow { const _FsNow._(); }

// ─── Client ──────────────────────────────────────────────────────────────────
//
// Ported from studio_flutter/lib/core/services/firestore_rest.dart — that
// app replaced cloud_firestore with this same REST client after the native
// plugin's Windows gRPC C++ SDK proved unstable there. This app hit the
// identical crash on Windows, so it gets the identical fix: same backend,
// same data, same security rules, same billing (Firestore bills per
// read/write regardless of which protocol reaches it) — this is purely a
// client-library swap, not a database migration.

class FirestoreRest {
  FirestoreRest._();
  static final instance = FirestoreRest._();

  final _http = http.Client();

  Future<String> _token({bool forceRefresh = false}) async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) throw StateError('Not signed in');
    return (await u.getIdToken(forceRefresh))!;
  }

  Map<String, String> _hdr(String token) => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  String _docPath(String col, String id) => '$_base/$col/$id';

  /// Sends an authenticated request, retrying with a force-refreshed ID
  /// token if the server rejects the cached one (401/403). The Firebase Auth
  /// SDK's own token cache can go stale without the SDK itself noticing —
  /// seen in practice (studio_flutter) as every Firestore read failing with
  /// 403 PERMISSION_DENIED until the user manually signed out and back in,
  /// which only "fixed" it by forcing a fresh token as a side effect. Also
  /// retries on transient connection failures (e.g. "Connection closed
  /// before full header was received") instead of letting a one-off network
  /// blip surface as an uncaught exception — every write here is naturally
  /// idempotent (set/merge-update/delete by a fixed doc id), so retrying is
  /// safe.
  Future<http.Response> _authedRequest(
    Future<http.Response> Function(String token) send,
  ) async {
    const maxAttempts = 3;
    var forceRefresh = false;
    for (var attempt = 1;; attempt++) {
      final token = await _token(forceRefresh: forceRefresh);
      http.Response res;
      try {
        res = await send(token);
      } on http.ClientException {
        if (attempt >= maxAttempts) rethrow;
        await Future.delayed(Duration(milliseconds: 300 * attempt));
        continue;
      } on SocketException {
        if (attempt >= maxAttempts) rethrow;
        await Future.delayed(Duration(milliseconds: 300 * attempt));
        continue;
      }
      final isAuthFailure = res.statusCode == 401 || res.statusCode == 403;
      if (isAuthFailure && !forceRefresh && attempt < maxAttempts) {
        forceRefresh = true;
        continue;
      }
      return res;
    }
  }

  // ─── Value converters ────────────────────────────────────────────────────

  static Map<String, dynamic> _enc(dynamic v) {
    if (v is _FsNow) return {'timestampValue': DateTime.now().toUtc().toIso8601String()};
    if (v == null) return {'nullValue': null};
    if (v is bool) return {'booleanValue': v};
    if (v is int) return {'integerValue': '$v'};
    if (v is double) return {'doubleValue': v};
    if (v is String) return {'stringValue': v};
    if (v is DateTime) return {'timestampValue': v.toUtc().toIso8601String()};
    if (v is List) {
      return {
        'arrayValue': {
          'values': v.isEmpty ? <dynamic>[] : v.map(_enc).toList(),
        }
      };
    }
    if (v is Map<String, dynamic>) {
      return {'mapValue': {'fields': v.map((k, val) => MapEntry(k, _enc(val)))}};
    }
    return {'stringValue': v.toString()};
  }

  static dynamic _dec(Map<String, dynamic> v) {
    if (v.containsKey('stringValue')) return v['stringValue'] as String;
    if (v.containsKey('integerValue')) return int.parse(v['integerValue'] as String);
    if (v.containsKey('doubleValue')) return (v['doubleValue'] as num).toDouble();
    if (v.containsKey('booleanValue')) return v['booleanValue'] as bool;
    if (v.containsKey('nullValue')) return null;
    if (v.containsKey('timestampValue')) {
      final s = v['timestampValue'] as String;
      return DateTime.tryParse(s) ?? DateTime.now();
    }
    if (v.containsKey('arrayValue')) {
      final arr = (v['arrayValue'] as Map?)? ['values'] as List? ?? [];
      return arr.map((e) => _dec(e as Map<String, dynamic>)).toList();
    }
    if (v.containsKey('mapValue')) {
      final fields = (v['mapValue'] as Map?)?['fields'] as Map<String, dynamic>? ?? {};
      return fields.map((k, val) => MapEntry(k, _dec(val as Map<String, dynamic>)));
    }
    return null;
  }

  static Map<String, dynamic> _parseFields(Map<String, dynamic> doc) {
    final fields = (doc['fields'] as Map<String, dynamic>?) ?? {};
    return fields.map((k, v) => MapEntry(k, _dec(v as Map<String, dynamic>)));
  }

  static String _idFrom(Map<String, dynamic> doc) {
    return (doc['name'] as String).split('/').last;
  }

  /// [_authedRequest] never returns a 401/403 without having already retried
  /// once with a force-refreshed token first (see its loop above) — so any
  /// 401/403 reaching here means that retry already failed, not that the
  /// caller hasn't refreshed yet. Surfaced as a distinct typed exception
  /// (rather than the generic one below) so the UI can offer a guided
  /// sign-out instead of showing this raw REST error text directly, and so
  /// it can be told apart from other failure modes at every call site.
  static Exception _err(http.Response r) {
    if (r.statusCode == 401 || r.statusCode == 403) {
      return AuthSessionExpiredException(
        'Session needs refreshing (Firestore REST ${r.statusCode}): ${r.body}',
      );
    }
    return Exception('Firestore REST ${r.statusCode}: ${r.body}');
  }

  // ─── Public API ───────────────────────────────────────────────────────────

  /// Get a single document. Returns null if not found.
  Future<Map<String, dynamic>?> getDoc(String col, String id) async {
    final res = await _authedRequest(
        (token) => _http.get(Uri.parse(_docPath(col, id)), headers: _hdr(token)));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) throw _err(res);
    return _parseFields(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Structured query with one optional WHERE clause.
  Future<List<({String id, Map<String, dynamic> data})>> query(
    String col, {
    String? whereField,
    String whereOp = 'EQUAL',
    dynamic whereValue,
    int limit = 200,
  }) async {
    final q = <String, dynamic>{
      'from': [
        {'collectionId': col}
      ],
      if (whereField != null)
        'where': {
          'fieldFilter': {
            'field': {'fieldPath': whereField},
            'op': whereOp,
            'value': _enc(whereValue),
          }
        },
      'limit': limit,
    };

    final res = await _authedRequest((token) => _http.post(
      Uri.parse('$_base:runQuery'),
      headers: _hdr(token),
      body: jsonEncode({'structuredQuery': q}),
    ));
    if (res.statusCode != 200) throw _err(res);

    final list = jsonDecode(res.body) as List;
    return list
        .where((r) => (r as Map)['document'] != null)
        .map((r) {
          final doc = (r as Map)['document'] as Map<String, dynamic>;
          return (id: _idFrom(doc), data: _parseFields(doc));
        })
        .toList();
  }

  /// Combined query with any number of WHERE clauses via composite AND,
  /// optionally ordered and cursor-paginated.
  ///
  /// Defaults to ordering by document id (`__name__`) — needs no extra
  /// composite index on top of the existing equality-filter indexes
  /// (Firestore automatically supports ordering by document name after an
  /// equality filter). Pass [orderByField] to order by a real field instead
  /// (e.g. `created_at`) — Firestore then requires `__name__` as an explicit
  /// tiebreaker in the same direction, which this always appends.
  ///
  /// [after], when given, resumes after that document: `fieldValue` is the
  /// last-seen document's value for [orderByField] (ignored/omittable when
  /// ordering by `__name__`, since the doc id alone is the full cursor then).
  /// Inspect whether the returned page is exactly [limit] long to know
  /// whether a further page might exist.
  Future<List<({String id, Map<String, dynamic> data})>> queryAnd(
    String col,
    List<({String field, String op, dynamic value})> filters, {
    int limit = 200,
    String orderByField = '__name__',
    bool descending = false,
    ({String docId, dynamic fieldValue})? after,
  }) async {
    final direction = descending ? 'DESCENDING' : 'ASCENDING';
    final q = <String, dynamic>{
      'from': [
        {'collectionId': col}
      ],
      'where': {
        'compositeFilter': {
          'op': 'AND',
          'filters': filters
              .map((f) => {
                    'fieldFilter': {
                      'field': {'fieldPath': f.field},
                      'op': f.op,
                      'value': _enc(f.value),
                    }
                  })
              .toList(),
        }
      },
      'orderBy': [
        {'field': {'fieldPath': orderByField}, 'direction': direction},
        if (orderByField != '__name__')
          {'field': {'fieldPath': '__name__'}, 'direction': direction},
      ],
      if (after != null)
        'startAt': {
          'values': [
            if (orderByField != '__name__') _enc(after.fieldValue),
            {'referenceValue': '$_resourcePrefix/$col/${after.docId}'},
          ],
          'before': false,
        },
      'limit': limit,
    };

    final res = await _authedRequest((token) => _http.post(
      Uri.parse('$_base:runQuery'),
      headers: _hdr(token),
      body: jsonEncode({'structuredQuery': q}),
    ));
    if (res.statusCode != 200) throw _err(res);

    final list = jsonDecode(res.body) as List;
    return list
        .where((r) => (r as Map)['document'] != null)
        .map((r) {
          final doc = (r as Map)['document'] as Map<String, dynamic>;
          return (id: _idFrom(doc), data: _parseFields(doc));
        })
        .toList();
  }

  /// Set (overwrite) a document.
  Future<void> setDoc(String col, String id, Map<String, dynamic> data) async {
    final body = {
      'fields': data.map((k, v) => MapEntry(k, _enc(v)))
    };
    final res = await _authedRequest((token) => _http.patch(
      Uri.parse(_docPath(col, id)),
      headers: _hdr(token),
      body: jsonEncode(body),
    ));
    if (res.statusCode != 200) throw _err(res);
  }

  /// Create a document with an auto-generated id. Returns the new id.
  Future<String> addDoc(String col, Map<String, dynamic> data) async {
    final body = {
      'fields': data.map((k, v) => MapEntry(k, _enc(v)))
    };
    final res = await _authedRequest((token) => _http.post(
      Uri.parse('$_base/$col'),
      headers: _hdr(token),
      body: jsonEncode(body),
    ));
    if (res.statusCode != 200) throw _err(res);
    return _idFrom(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Update specific fields. Values of [fsDelete] cause field removal.
  Future<void> updateDoc(String col, String id, Map<String, dynamic> data) async {
    final deletes = <String>[];
    final updates = <String, dynamic>{};
    data.forEach((k, v) {
      if (v is _FsDel) {
        deletes.add(k);
      } else {
        updates[k] = v;
      }
    });

    final allKeys = [...updates.keys, ...deletes];
    final maskParam =
        allKeys.map((f) => 'updateMask.fieldPaths=${Uri.encodeComponent(f)}').join('&');

    final body = {'fields': updates.map((k, v) => MapEntry(k, _enc(v)))};
    final res = await _authedRequest((token) => _http.patch(
      Uri.parse('${_docPath(col, id)}?$maskParam'),
      headers: _hdr(token),
      body: jsonEncode(body),
    ));
    if (res.statusCode != 200) throw _err(res);
  }

  /// Delete a document.
  Future<void> deleteDoc(String col, String id) async {
    final res = await _authedRequest((token) => _http.delete(
      Uri.parse(_docPath(col, id)),
      headers: _hdr(token),
    ));
    if (res.statusCode != 200 && res.statusCode != 204) throw _err(res);
  }
}
