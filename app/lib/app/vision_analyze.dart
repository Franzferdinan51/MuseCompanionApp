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
//
// On-device image analysis: OCR text and barcode scanning.
//
// Images come from the agent workspace (written there with file.write as
// base64, or dropped by the user) and never leave the phone: both
// recognizers are ML Kit on-device models. [analyzeWorkspaceImage] copies
// the workspace file to a temp file for the recognizers, then deletes
// it. Unit tests inject a fake backend; no hardware or models needed.

import 'dart:convert';
import 'dart:io';

import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'workspace_files.dart';

/// Thrown for bad modes, missing images, and recognizer failures.
class VisionException implements Exception {
  VisionException(this.message);

  final String message;

  @override
  String toString() => 'VisionException: $message';
}

/// One decoded barcode.
class BarcodeHit {
  const BarcodeHit({required this.format, required this.value});

  final String format;
  final String value;

  Map<String, Object?> toJson() => {'format': format, 'value': value};
}

/// OCR text plus barcodes found in one image.
class VisionAnalysis {
  const VisionAnalysis({required this.text, required this.barcodes});

  final String text;
  final List<BarcodeHit> barcodes;

  Map<String, Object?> toJson() => {
    'text': text,
    'barcodes': [for (final b in barcodes) b.toJson()],
  };
}

/// ML Kit recognizers behind an injectable seam.
abstract class VisionAnalyzerBackend {
  Future<String> recognizeText(String absolutePath);
  Future<List<BarcodeHit>> scanBarcodes(String absolutePath);
  Future<void> dispose();
}

/// Production backend: on-device ML Kit text + barcode models.
class MlKitVisionAnalyzer implements VisionAnalyzerBackend {
  TextRecognizer? _text;
  BarcodeScanner? _codes;

  @override
  Future<String> recognizeText(String absolutePath) async {
    _text ??= TextRecognizer(script: TextRecognitionScript.latin);
    final result = await _text!.processImage(
      InputImage.fromFilePath(absolutePath),
    );
    return result.text.trim();
  }

  @override
  Future<List<BarcodeHit>> scanBarcodes(String absolutePath) async {
    _codes ??= BarcodeScanner(formats: const [BarcodeFormat.all]);
    final codes = await _codes!.processImage(
      InputImage.fromFilePath(absolutePath),
    );
    return [
      for (final code in codes)
        if ((code.displayValue ?? code.rawValue ?? '').isNotEmpty)
          BarcodeHit(
            format: code.format.name,
            value: (code.displayValue ?? code.rawValue)!,
          ),
    ];
  }

  @override
  Future<void> dispose() async {
    await _text?.close();
    await _codes?.close();
    _text = null;
    _codes = null;
  }
}

/// Analyze the workspace image at [relPath]. [mode] is `text`,
/// `barcode`, or `both`. Images stay on the phone; only the extracted
/// text and code values are returned.
Future<VisionAnalysis> analyzeWorkspaceImage({
  required WorkspaceFiles files,
  required String relPath,
  required String mode,
  VisionAnalyzerBackend? backend,
}) async {
  final normalized = mode.trim().toLowerCase();
  if (normalized != 'text' && normalized != 'barcode' && normalized != 'both') {
    throw VisionException('mode must be text, barcode or both');
  }
  final analyzer = backend ?? MlKitVisionAnalyzer();
  final owned = backend == null;
  Directory? tmpDir;
  try {
    final (payload, size) = await files.readBytes(relPath);
    if (size == 0) throw VisionException('image is empty: $relPath');
    tmpDir = await Directory.systemTemp.createTemp('vision_analyze');
    final tmp = File('${tmpDir.path}/image');
    List<int> bytes;
    try {
      bytes = base64Decode(payload);
    } catch (_) {
      throw VisionException('image data is corrupt: $relPath');
    }
    await tmp.writeAsBytes(bytes, flush: true);
    final wantText = normalized != 'barcode';
    final wantCodes = normalized != 'text';
    return VisionAnalysis(
      text: wantText ? await analyzer.recognizeText(tmp.path) : '',
      barcodes: wantCodes ? await analyzer.scanBarcodes(tmp.path) : const [],
    );
  } finally {
    if (owned) await analyzer.dispose();
    try {
      if (tmpDir != null && await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    } catch (_) {}
  }
}
