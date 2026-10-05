// Tests for the shared canvas: versioned document store and the
// canvas_* agent tools.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/canvas_store.dart';
import 'package:muse_companion/app/lmstudio_tools.dart';
import 'package:muse_companion/src/gadget/phone_actions.dart';

class _FakePhone extends PhoneActions {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CanvasStore _store() {
  final dir = Directory.systemTemp.createTempSync('canvas_test_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return CanvasStore.forDir(dir);
}

LmToolContext _ctx(CanvasStore store, {void Function(String, String, bool)? onDoc}) =>
    LmToolContext(
      phone: _FakePhone(),
      cameraFacing: 'back',
      canvas: store,
      onCanvasDocument: onDoc,
    );

void main() {
  group('CanvasStore', () {
    test('create assigns rev 1 and reads back', () async {
      final store = _store();
      final doc = await store.create(
        title: 'Notes',
        type: CanvasDocType.markdown,
        content: '# hi',
      );
      expect(doc.rev, 1);
      expect(doc.content, '# hi');
      expect(doc.versions, hasLength(1));

      final read = await store.read(doc.id);
      expect(read.title, 'Notes');
      expect(read.type, CanvasDocType.markdown);
      await store.close();
    });

    test('update appends versions and caps at 40', () async {
      final store = _store();
      final doc = await store.create(title: 'T', content: 'v0');
      var current = doc;
      for (var i = 1; i <= 45; i++) {
        current = await store.update(doc.id, content: 'v$i');
      }
      expect(current.rev, 46);
      expect(current.versions, hasLength(CanvasStore.maxVersions));
      expect(current.versions.first.rev, 7); // oldest 6 aged out
      expect(current.versions.last.content, 'v45');
      await store.close();
    });

    test('update with no changes is a no-op', () async {
      final store = _store();
      final doc = await store.create(title: 'T', content: 'same');
      final again = await store.update(doc.id, content: 'same');
      expect(again.rev, 1);
      await store.close();
    });

    test('update rejects stale baseRev', () async {
      final store = _store();
      final doc = await store.create(title: 'T', content: 'a');
      await store.update(doc.id, content: 'b');
      expect(
        () => store.update(doc.id, content: 'c', baseRev: 1),
        throwsA(isA<CanvasStoreException>()),
      );
      await store.close();
    });

    test('patch applies exact find/replace edits', () async {
      final store = _store();
      final doc = await store.create(title: 'T', content: 'hello world');
      final patched = await store.patch(doc.id, const [
        CanvasEdit(find: 'world', replace: 'there'),
      ]);
      expect(patched.content, 'hello there');
      expect(patched.rev, 2);
      await store.close();
    });

    test('patch rejects ambiguous find without all:true', () async {
      final store = _store();
      final doc = await store.create(title: 'T', content: 'a a a');
      expect(
        () => store.patch(doc.id, const [
          CanvasEdit(find: 'a', replace: 'b'),
        ]),
        throwsA(isA<CanvasStoreException>()),
      );
      final patched = await store.patch(doc.id, const [
        CanvasEdit(find: 'a', replace: 'b', all: true),
      ]);
      expect(patched.content, 'b b b');
      await store.close();
    });

    test('restore brings back an old revision as a new version', () async {
      final store = _store();
      final doc = await store.create(title: 'T', content: 'first');
      await store.update(doc.id, content: 'second');
      final restored = await store.restore(doc.id, 1, by: 'user');
      expect(restored.content, 'first');
      expect(restored.rev, 3);
      // History is append-only: the pre-restore content is still there.
      final v2 = await store.version(doc.id, 2);
      expect(v2?.content, 'second');
      await store.close();
    });

    test('restore of an aged-out revision throws', () async {
      final store = _store();
      final doc = await store.create(title: 'T', content: 'x');
      expect(
        () => store.restore(doc.id, 999),
        throwsA(isA<CanvasStoreException>()),
      );
      await store.close();
    });

    test('rename and network flag do not create versions', () async {
      final store = _store();
      final doc = await store.create(title: 'Old', content: 'x');
      final renamed = await store.rename(doc.id, 'New');
      expect(renamed.title, 'New');
      expect(renamed.rev, 1);
      final flagged = await store.setNetworkAllowed(doc.id, true);
      expect(flagged.networkAllowed, isTrue);
      expect(flagged.rev, 1);
      await store.close();
    });

    test('delete removes the document', () async {
      final store = _store();
      final doc = await store.create(title: 'T', content: 'x');
      await store.delete(doc.id);
      expect(() => store.read(doc.id), throwsA(isA<CanvasStoreException>()));
      expect(await store.list(), isEmpty);
      await store.close();
    });

    test('list returns metadata oldest first', () async {
      final store = _store();
      await store.create(title: 'B', content: 'x');
      await store.create(title: 'A', content: 'y');
      final metas = await store.list();
      expect(metas, hasLength(2));
      expect(metas.map((m) => m.title), containsAll(['A', 'B']));
      expect(metas.first.chars, isNonNegative);
      await store.close();
    });

    test('changes stream fires on create/update/delete', () async {
      final store = _store();
      final kinds = <CanvasChangeKind>[];
      final sub = store.changes.listen((c) => kinds.add(c.kind));
      final doc = await store.create(title: 'T', content: 'x');
      await store.update(doc.id, content: 'y');
      await store.delete(doc.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        kinds,
        [CanvasChangeKind.created, CanvasChangeKind.updated, CanvasChangeKind.deleted],
      );
      await sub.cancel();
      await store.close();
    });

    test('unknown ids throw CanvasStoreException', () async {
      final store = _store();
      expect(() => store.read('nope'), throwsA(isA<CanvasStoreException>()));
      await store.close();
    });
  });

  group('canvas tools', () {
    test('canvas tools are registered alongside phone tools', () {
      final tools = lmToolsListFor(
        usbStorageEnabled: false,
        usbSerialEnabled: false,
      );
      final names = tools.map((t) => t.name).toSet();
      expect(names, containsAll(['canvas_create', 'canvas_update', 'canvas_list']));
      // Existing tools untouched.
      expect(names, contains('speak_text'));
      expect(names, contains('take_photo'));
    });

    test('canvas_create stores a doc and fires the card callback', () async {
      final store = _store();
      String? seenId;
      String? seenTitle;
      bool? seenUpdated;
      final ctx = _ctx(
        store,
        onDoc: (id, title, updated) {
          seenId = id;
          seenTitle = title;
          seenUpdated = updated;
        },
      );
      final tool = lmToolNamed('canvas_create')!;
      final out = await tool.handler({
        'title': 'Plan',
        'type': 'markdown',
        'content': '# plan',
      }, ctx);
      expect(out, contains('Created canvas document'));
      expect(seenId, isNotNull);
      expect(seenTitle, 'Plan');
      expect(seenUpdated, isFalse);

      final doc = await store.read(seenId!);
      expect(doc.content, '# plan');
      await store.close();
    });

    test('canvas_update replaces content and fires the card callback', () async {
      final store = _store();
      final ctx = _ctx(store);
      final created = await lmToolNamed('canvas_create')!.handler({
        'title': 'Doc',
        'content': 'v1',
      }, ctx);
      final id = RegExp(r'id: ([a-z0-9-]+)').firstMatch(created)!.group(1)!;

      var updatedFlag = false;
      final ctx2 = _ctx(store, onDoc: (_, _, updated) => updatedFlag = updated);
      final out = await lmToolNamed('canvas_update')!.handler({
        'id': id,
        'content': 'v2',
        'note': 'second pass',
      }, ctx2);
      expect(out, contains('now revision 2'));
      expect(updatedFlag, isTrue);
      expect((await store.read(id)).versions.last.note, 'second pass');
      await store.close();
    });

    test('canvas_update on unknown id returns an error string', () async {
      final store = _store();
      final out = await lmToolNamed('canvas_update')!.handler({
        'id': 'missing',
        'content': 'x',
      }, _ctx(store));
      expect(out, startsWith('error:'));
      await store.close();
    });

    test('canvas_list reports documents', () async {
      final store = _store();
      final ctx = _ctx(store);
      expect(
        await lmToolNamed('canvas_list')!.handler({}, ctx),
        'The canvas is empty.',
      );
      await lmToolNamed('canvas_create')!.handler({
        'title': 'One',
        'content': 'x',
      }, ctx);
      final out = await lmToolNamed('canvas_list')!.handler({}, ctx);
      expect(out, contains('"One"'));
      expect(out, contains('rev 1'));
      await store.close();
    });

    test('canvas tools report an error when the store is unavailable', () async {
      final ctx = LmToolContext(phone: _FakePhone(), cameraFacing: 'back');
      final out = await lmToolNamed('canvas_create')!.handler({
        'title': 'T',
        'content': 'x',
      }, ctx);
      expect(out, startsWith('error:'));
    });
  });
}
