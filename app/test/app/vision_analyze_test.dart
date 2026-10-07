// Copyright (c) Meta Platforms, Inc. and affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/lmstudio_tools.dart';
import 'package:muse_companion/app/vision_analyze.dart';
import 'package:muse_companion/app/workspace_files.dart';
import 'package:muse_companion/src/gadget/phone_actions.dart';

class _FakeAnalyzer implements VisionAnalyzerBackend {
  final List<String> calls = [];

  @override
  Future<String> recognizeText(String absolutePath) async {
    calls.add('text:$absolutePath');
    return 'TOTAL 42.00';
  }

  @override
  Future<List<BarcodeHit>> scanBarcodes(String absolutePath) async {
    calls.add('barcode:$absolutePath');
    return const [BarcodeHit(format: 'qrCode', value: 'https://example.com')];
  }

  @override
  Future<void> dispose() async {}
}

class _FakePhone implements PhoneActions {
  @override
  Future<Uint8List> captureJpeg({String facing = 'back'}) async =>
      Uint8List(0);

  @override
  Future<Uint8List> recordWav(int seconds) async => Uint8List(0);

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stopSpeak() async {}

  @override
  Future<void> openNotificationAccess() async {}

  @override
  Future<Map<String, Object?>> run(
    String command,
    Map<String, Object?> params,
  ) async => {};
}

void main() {
  late Directory root;
  late WorkspaceFiles files;
  late _FakeAnalyzer analyzer;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('vision_test');
    files = WorkspaceFiles(root: root);
    analyzer = _FakeAnalyzer();
    await files.writeBytes('scan/receipt.jpg', [1, 2, 3, 4]);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('both mode reads text and barcodes', () async {
    final result = await analyzeWorkspaceImage(
      files: files,
      relPath: 'scan/receipt.jpg',
      mode: 'both',
      backend: analyzer,
    );
    expect(result.text, 'TOTAL 42.00');
    expect(result.barcodes.single.value, 'https://example.com');
    expect(analyzer.calls.length, 2);
  });

  test('modes select the recognizer', () async {
    await analyzeWorkspaceImage(
      files: files,
      relPath: 'scan/receipt.jpg',
      mode: 'text',
      backend: analyzer,
    );
    expect(analyzer.calls.length, 1);
    expect(analyzer.calls.single, startsWith('text:'));

    analyzer.calls.clear();
    await analyzeWorkspaceImage(
      files: files,
      relPath: 'scan/receipt.jpg',
      mode: 'barcode',
      backend: analyzer,
    );
    expect(analyzer.calls.length, 1);
    expect(analyzer.calls.single, startsWith('barcode:'));
  });

  test('bad mode, missing and empty images fail cleanly', () async {
    expect(
      () => analyzeWorkspaceImage(
        files: files,
        relPath: 'scan/receipt.jpg',
        mode: 'smell',
        backend: analyzer,
      ),
      throwsA(isA<VisionException>()),
    );
    expect(
      () => analyzeWorkspaceImage(
        files: files,
        relPath: 'scan/nope.jpg',
        mode: 'text',
        backend: analyzer,
      ),
      throwsA(isA<WorkspaceException>()),
    );
    await files.writeBytes('scan/empty.jpg', []);
    expect(
      () => analyzeWorkspaceImage(
        files: files,
        relPath: 'scan/empty.jpg',
        mode: 'text',
        backend: analyzer,
      ),
      throwsA(isA<VisionException>()),
    );
  });

  test('vision_analyze tool reports text and barcodes', () async {
    final ctx = LmToolContext(
      phone: _FakePhone(),
      cameraFacing: 'back',
      workspace: files,
      visionAnalyzer: analyzer,
    );
    final out = await lmToolNamed('vision_analyze')!.handler({
      'path': 'scan/receipt.jpg',
      'mode': 'both',
    }, ctx);
    expect(out, contains('TOTAL 42.00'));
    expect(out, contains('qrCode'));
  });

  test('vision_analyze tool validates path', () async {
    final ctx = LmToolContext(
      phone: _FakePhone(),
      cameraFacing: 'back',
      workspace: files,
      visionAnalyzer: analyzer,
    );
    expect(
      await lmToolNamed('vision_analyze')!.handler({}, ctx),
      startsWith('error:'),
    );
    expect(
      await lmToolNamed('vision_analyze')!.handler(
        {'path': 'scan/nope.jpg'},
        ctx,
      ),
      startsWith('error:'),
    );
  });
}
