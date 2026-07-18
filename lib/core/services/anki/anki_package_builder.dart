import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'anki_note_model.dart';

/// Derives a stable, non-negative integer id from [seed] — used for Anki
/// model/deck/note/card ids so re-exporting the same quiz/question updates
/// existing Anki cards in place instead of duplicating them (mirrors the
/// MD5-hash-derived stable-ID behavior of the reference Python generator at
/// `D:\Projects\Anki generator\build_apkg.py`). Dart's `%` on int always
/// returns a non-negative result for a positive divisor, so no separate
/// sign-handling is needed even though the raw 64-bit value can be negative.
int stableAnkiId(String seed) {
  final digest = md5.convert(utf8.encode(seed)).bytes;
  var value = 0;
  for (var i = 0; i < 8; i++) {
    value = (value << 8) | digest[i];
  }
  return value % 4611686018427387903; // 2^62 - 1, safe positive Dart int
}

/// Fixed model id shared by every SecurePlayer Anki export, so all exported
/// quizzes merge into one Anki note type over time instead of creating a new
/// one per export.
final int kSecurePlayerAnkiModelId =
    stableAnkiId('secureplayer:anki:model:v2');

class _PendingNote {
  _PendingNote({
    required this.noteId,
    required this.cardId,
    required this.guid,
    required this.fields,
    required this.sortField,
    required this.dueOrder,
  });

  final int noteId;
  final int cardId;
  final String guid;
  final List<String> fields;
  final String sortField;
  final int dueOrder;
}

class _PendingMedia {
  _PendingMedia({required this.filename, required this.bytes});
  final String filename;
  final Uint8List bytes;
}

/// Builds a single-deck Anki `.apkg` package from SecurePlayer quiz
/// questions.
///
/// No genanki-for-Dart exists, so this hand-builds the Anki SQLite
/// collection (schema confirmed against a working implementation —
/// `Web Apps/Quiz Or Sheet/lib/anki-generator.ts`, the same on-disk format
/// genanki itself produces, "schema 11", which Anki auto-upgrades on import)
/// and zips it with a genanki-style media manifest: each image is a zip
/// entry named as a plain sequential integer string, plus one `media` entry
/// (no extension) mapping that index to the filename referenced from the
/// note's `<img src="...">`.
class AnkiPackageBuilder {
  AnkiPackageBuilder({required this.deckName, int? deckId})
      : deckId = deckId ?? stableAnkiId('secureplayer:anki:deck:$deckName');

  final String deckName;
  final int deckId;

  final List<_PendingNote> _notes = [];
  final List<_PendingMedia> _media = [];

  bool get isEmpty => _notes.isEmpty;
  int get questionCount => _notes.length;

  /// Adds one question as a note+card. [imageBytes], if provided, is packed
  /// into the apkg's media folder and referenced from the note's Image field.
  void addQuestion({
    required String questionId,
    required String quizId,
    required String questionText,
    required List<String> options,
    required int correctIndex,
    required String explanation,
    required String questionDirection,
    required String explanationDirection,
    Uint8List? imageBytes,
    String imageExtension = '.jpg',
    String source = '',
  }) {
    final noteId = stableAnkiId('secureplayer:anki:note:$quizId:$questionId');
    final cardId = stableAnkiId('secureplayer:anki:card:$quizId:$questionId');
    final guid =
        stableAnkiId('secureplayer:anki:guid:$quizId:$questionId')
            .toRadixString(36);

    final choices = <String, String>{};
    for (var i = 0; i < options.length; i++) {
      choices[String.fromCharCode('A'.codeUnitAt(0) + i)] = options[i];
    }
    final correctKey = (correctIndex >= 0 && correctIndex < options.length)
        ? String.fromCharCode('A'.codeUnitAt(0) + correctIndex)
        : '';

    var imageField = '';
    if (imageBytes != null) {
      final filename = 'secureplayer_$questionId$imageExtension';
      _media.add(_PendingMedia(filename: filename, bytes: imageBytes));
      imageField = filename;
    }

    final fields = <String>[
      questionText, // Question
      jsonEncode(choices), // ChoicesJSON
      correctKey, // CorrectKey
      explanation, // Explanation
      imageField, // Image
      source, // Source
      questionDirection, // QuestionDir
      explanationDirection, // ExplanationDir
    ];

    _notes.add(_PendingNote(
      noteId: noteId,
      cardId: cardId,
      guid: guid,
      fields: fields,
      sortField: questionText,
      dueOrder: _notes.length + 1,
    ));
  }

  /// Builds the .apkg zip bytes. Writes a throwaway SQLite file under the
  /// system temp dir (sqflite has no true in-memory mode that behaves
  /// identically across Android/iOS/Windows), then deletes it once read.
  /// [tempDirPath] overrides where that file is written — production callers
  /// never need it (defaults to the OS temp dir via path_provider); tests use
  /// it to avoid depending on a platform channel.
  Future<Uint8List> build({String? tempDirPath}) async {
    final tempDir = tempDirPath ?? (await getTemporaryDirectory()).path;
    final dbPath = '$tempDir/anki_build_'
        '${DateTime.now().microsecondsSinceEpoch}.sqlite';
    final dbFile = File(dbPath);
    if (await dbFile.exists()) await dbFile.delete();

    final db = await openDatabase(dbPath, version: 1, onCreate: _createTables);
    try {
      await _populate(db);
    } finally {
      await db.close();
    }

    final dbBytes = await dbFile.readAsBytes();
    await dbFile.delete();

    final archive = Archive();
    archive.addFile(ArchiveFile('collection.anki21', dbBytes.length, dbBytes));
    archive.addFile(ArchiveFile('collection.anki2', dbBytes.length, dbBytes));

    final mediaManifest = <String, String>{};
    for (var i = 0; i < _media.length; i++) {
      mediaManifest['$i'] = _media[i].filename;
      final bytes = _media[i].bytes;
      archive.addFile(ArchiveFile('$i', bytes.length, bytes));
    }
    final manifestBytes = utf8.encode(jsonEncode(mediaManifest));
    archive.addFile(ArchiveFile('media', manifestBytes.length, manifestBytes));

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw StateError('Failed to build .apkg zip archive');
    }
    return Uint8List.fromList(zipBytes);
  }

  Future<void> _createTables(Database db, int version) async {
    await db.execute('''
      CREATE TABLE col (
        id integer primary key, crt integer not null, mod integer not null,
        scm integer not null, ver integer not null, dty integer not null,
        usn integer not null, ls integer not null, conf text not null,
        models text not null, decks text not null, dconf text not null,
        tags text not null
      )
    ''');
    await db.execute('''
      CREATE TABLE notes (
        id integer primary key, guid text not null, mid integer not null,
        mod integer not null, usn integer not null, tags text not null,
        flds text not null, sfld text not null, csum integer not null,
        flags integer not null, data text not null
      )
    ''');
    await db.execute('''
      CREATE TABLE cards (
        id integer primary key, nid integer not null, did integer not null,
        ord integer not null, mod integer not null, usn integer not null,
        type integer not null, queue integer not null, due integer not null,
        ivl integer not null, factor integer not null, reps integer not null,
        lapses integer not null, left integer not null, odue integer not null,
        odid integer not null, flags integer not null, data text not null
      )
    ''');
    await db.execute('''
      CREATE TABLE revlog (
        id integer primary key, cid integer not null, usn integer not null,
        ease integer not null, ivl integer not null, lastIvl integer not null,
        factor integer not null, time integer not null, type integer not null
      )
    ''');
    await db.execute('''
      CREATE TABLE graves (
        usn integer not null, oid integer not null, type integer not null
      )
    ''');
  }

  Future<void> _populate(Database db) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await db.insert('col', {
      'id': 1,
      'crt': nowSec,
      'mod': nowSec,
      'scm': nowSec,
      'ver': 11,
      'dty': 0,
      'usn': 0,
      'ls': 0,
      'conf': _buildConfJson(),
      'models': _buildModelJson(nowSec),
      'decks': _buildDeckJson(nowSec),
      'dconf': _buildDconfJson(nowSec),
      'tags': '{}',
    });

    for (final note in _notes) {
      await db.insert('notes', {
        'id': note.noteId,
        'guid': note.guid,
        'mid': kSecurePlayerAnkiModelId,
        'mod': nowSec,
        'usn': -1,
        'tags': '',
        'flds': note.fields.join('\x1f'),
        'sfld': note.sortField,
        'csum': _fieldChecksum(note.fields.first),
        'flags': 0,
        'data': '',
      });

      await db.insert('cards', {
        'id': note.cardId,
        'nid': note.noteId,
        'did': deckId,
        'ord': 0,
        'mod': nowSec,
        'usn': -1,
        'type': 0,
        'queue': 0,
        'due': note.dueOrder,
        'ivl': 0,
        'factor': 2500,
        'reps': 0,
        'lapses': 0,
        'left': 0,
        'odue': 0,
        'odid': 0,
        'flags': 0,
        'data': '',
      });
    }
  }

  String _buildConfJson() => jsonEncode({
        'nextPos': _notes.length + 1,
        'estTimes': true,
        'activeDecks': [deckId],
        'sortType': 'noteFld',
        'timeLim': 0,
        'sortBackwards': false,
        'addToCur': true,
        'curDeck': deckId,
        'newBury': true,
        'newSpread': 0,
        'dueCounts': true,
        'curModel': '$kSecurePlayerAnkiModelId',
        'collapseTime': 1200,
      });

  String _buildModelJson(int nowSec) {
    final model = {
      'id': kSecurePlayerAnkiModelId,
      'name': 'SecurePlayer MCQ',
      'type': 0,
      'mod': nowSec,
      'usn': -1,
      'sortf': 0,
      'did': deckId,
      'tmpls': [
        {
          'name': 'SecurePlayer MCQ',
          'ord': 0,
          'qfmt': ankiMcqFrontTemplate,
          'afmt': ankiMcqBackTemplate,
          'bqfmt': '',
          'bafmt': '',
          'did': null,
        }
      ],
      'flds': [
        for (var i = 0; i < ankiNoteFields.length; i++)
          {
            'name': ankiNoteFields[i],
            'ord': i,
            'sticky': false,
            'rtl': false,
            'font': 'Arial',
            'size': 20,
          }
      ],
      'css': '',
      'req': [
        [0, 'all', [0]]
      ],
    };
    // Keys in Anki's models/decks/dconf JSON blobs are the numeric id
    // *as a string* — jsonEncode on an int-keyed Dart map would throw.
    return jsonEncode({'$kSecurePlayerAnkiModelId': model});
  }

  String _buildDeckJson(int nowSec) {
    final deck = {
      'id': deckId,
      'mod': nowSec,
      'name': deckName,
      'usn': -1,
      'lrnToday': [0, 0],
      'revToday': [0, 0],
      'newToday': [0, 0],
      'timeToday': [0, 0],
      'collapsed': false,
      'browserCollapsed': false,
      'desc': 'SecurePlayer',
      'dyn': 0,
      'conf': 1,
      'extendNew': 10,
      'extendRev': 50,
    };
    return jsonEncode({'$deckId': deck});
  }

  String _buildDconfJson(int nowSec) {
    final dconf = {
      'id': 1,
      'mod': nowSec,
      'name': 'Default',
      'usn': 0,
      'maxTaken': 60,
      'autoplay': true,
      'timer': 0,
      'replayq': true,
      'new': {
        'bury': true,
        'delays': [1, 10],
        'initialFactor': 2500,
        'ints': [1, 4, 7],
        'order': 1,
        'perDay': 20,
      },
      'rev': {
        'bury': true,
        'ease4': 1.3,
        'ivlFct': 1,
        'maxIvl': 36500,
        'perDay': 200,
        'hardFactor': 1.2,
      },
      'lapse': {
        'delays': [10],
        'leechAction': 1,
        'leechFails': 8,
        'minInt': 1,
        'mult': 0,
      },
    };
    return jsonEncode({'1': dconf});
  }

  /// Anki's own duplicate-detection hash: sha1 of the first field stripped
  /// of HTML tags, first 8 hex chars parsed as an integer.
  int _fieldChecksum(String firstField) {
    final stripped = firstField.replaceAll(RegExp('<[^>]*>'), '');
    final hex = sha1.convert(utf8.encode(stripped)).toString().substring(0, 8);
    return int.parse(hex, radix: 16);
  }
}
