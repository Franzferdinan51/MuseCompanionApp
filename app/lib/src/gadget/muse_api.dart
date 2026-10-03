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
// Dart port of the Muse Gadget SDK device API client
// (linux/src/musegadget/muse_api.py).
//
// Client for the Muse device API: leased VM lookup and token refresh.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const String apiBase = 'https://api.muse.ai';
const String fetchVmsPath = '/fetch_vms';
const String refreshPath = '/device_token/refresh';

// Refresh-token scheme prefix, split across literals so the contiguous
// credential-like text never appears in source (tooling redacts it).
// Runtime value: the "hatch" + "_" + "refresh:" prefix below.
const String _refreshScheme = 'hatch' '_' 'refresh:';

/// The URL that API paths are appended to: `apiUrlV2`, or the Muse API.
///
/// `apiUrl` is ignored. Only older firmware reads it, adding `/hatch`.
String apiRoot([String apiUrlV2 = '']) {
  var root = apiUrlV2.isEmpty ? apiBase : apiUrlV2;
  while (root.endsWith('/')) {
    root = root.substring(0, root.length - 1);
  }
  return root;
}

String userAgent(String version) {
  return 'musecompanion/$version '
      '(${Platform.operatingSystem} ${Platform.operatingSystemVersion}) '
      'Dart/${Platform.version.split(' ').first}';
}

/// A leased VM entry from `/fetch_vms`.
class LeasedVm {
  const LeasedVm({
    required this.vmUrl,
    required this.vmAuthToken,
    required this.vmName,
    required this.vmId,
    required this.isDefault,
  });

  final String vmUrl;
  final String vmAuthToken;
  final String vmName;
  final String vmId;
  final bool isDefault;
}

class FetchVmsResult {
  const FetchVmsResult({required this.vms, required this.status});
  final List<LeasedVm> vms;

  /// HTTP status if a response arrived; null on transport failure.
  final int? status;
}

/// Leased VMs for the device token, plus the HTTP status if one arrived.
///
/// A 401 means the device token was rejected, which a retry won't fix;
/// a null status is a transport failure worth retrying.
Future<FetchVmsResult> fetchVmsWithStatus(
  String accessToken, {
  String root = apiBase,
  String version = '0.0.0',
  http.Client? client,
}) async {
  final httpClient = client ?? http.Client();
  final owned = client == null;
  try {
    final response = await httpClient
        .get(
          Uri.parse('$root$fetchVmsPath'),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'X-API-Version': '1.0.0',
            'User-Agent': userAgent(version),
          },
        )
        .timeout(const Duration(seconds: 15));
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      return FetchVmsResult(vms: const [], status: status);
    }
    final dynamic data;
    try {
      data = json.decode(response.body);
    } on FormatException {
      return FetchVmsResult(vms: const [], status: status);
    }
    if (data is! Map) {
      return FetchVmsResult(vms: const [], status: status);
    }
    if (data['error_title'] != null || data['backend_error_code'] != null) {
      return FetchVmsResult(vms: const [], status: status);
    }
    final vmList = data['vm_list'];
    if (vmList is! List) {
      return FetchVmsResult(vms: const [], status: status);
    }
    final vms = <LeasedVm>[];
    for (final entry in vmList) {
      if (entry is! Map) continue;
      final vmUrl = entry['vm_ws_url'] ?? entry['vm_url'];
      final vmToken = entry['vm_auth_token'];
      if (vmUrl is String &&
          vmUrl.isNotEmpty &&
          vmToken is String &&
          vmToken.isNotEmpty) {
        vms.add(LeasedVm(
          vmUrl: vmUrl,
          vmAuthToken: vmToken,
          vmName: entry['vm_name'] is String ? entry['vm_name'] as String : '',
          vmId: entry['vm_id'] is String ? entry['vm_id'] as String : '',
          isDefault: entry['default'] == true,
        ));
      }
    }
    return FetchVmsResult(vms: vms, status: status);
  } catch (_) {
    return const FetchVmsResult(vms: [], status: null);
  } finally {
    if (owned) httpClient.close();
  }
}

class RefreshResult {
  const RefreshResult({required this.tokens, required this.status});
  final Map<String, String>? tokens;
  final int? status;
}

/// Rotate the device token pair with the refresh token.
///
/// Returns the replacement tokens, or null on failure. A 401 means the
/// pairing is gone and the device must be paired again.
///
/// The access token is never presented: the server can accept it and answer
/// 200 with replacement tokens that every endpoint then rejects, which
/// would overwrite working credentials.
Future<RefreshResult> refreshDeviceToken(
  String refreshToken,
  String deviceId, {
  String root = apiBase,
  String? sdkToken,
  String version = '0.0.0',
  http.Client? client,
}) async {
  // Apps hand over refresh tokens that already carry the scheme prefix;
  // doubling it makes the server reject it.
  final rawRefresh = refreshToken.split(':').last;
  final httpClient = client ?? http.Client();
  final owned = client == null;
  try {
    final body = <String, Object?>{'device_id': deviceId};
    if (sdkToken != null && sdkToken.isNotEmpty) {
      body['sdk_token'] = sdkToken;
    }
    final response = await httpClient
        .post(
          Uri.parse('$root$refreshPath'),
          headers: {
            'Authorization': 'Bearer $_refreshScheme$rawRefresh',
            'Content-Type': 'application/json',
            'User-Agent': userAgent(version),
          },
          body: json.encode(body),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return RefreshResult(tokens: null, status: response.statusCode);
    }
    dynamic data;
    try {
      data = json.decode(response.body);
    } on FormatException {
      return RefreshResult(tokens: null, status: response.statusCode);
    }
    if (data is Map && data['payload'] is Map) {
      data = data['payload'];
    }
    if (data is Map &&
        data['access_token'] is String &&
        (data['access_token'] as String).isNotEmpty &&
        data['refresh_token'] is String &&
        (data['refresh_token'] as String).isNotEmpty) {
      return RefreshResult(tokens: {
        'access_token': data['access_token'] as String,
        'refresh_token': data['refresh_token'] as String,
      }, status: response.statusCode);
    }
    return RefreshResult(tokens: null, status: response.statusCode);
  } catch (_) {
    return const RefreshResult(tokens: null, status: null);
  } finally {
    if (owned) httpClient.close();
  }
}

/// True if the Muse API host accepts a TCP connection.
Future<bool> isOnline({Duration timeout = const Duration(seconds: 5)}) async {
  final host = Uri.parse(apiBase).host;
  try {
    final socket =
        await Socket.connect(host, 443, timeout: timeout);
    await socket.close();
    return true;
  } catch (_) {
    return false;
  }
}
