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
// Captions for the companion screen.
//
// The ESP32 Muse gadgets (Waveshare, AiPi, StickS3, Pocket) show the
// reply under the character and speak a short form of it. These helpers
// turn a chat reply or an activity code into that line. They do not
// touch the network or the display.

/// Visible caption under the character. Four short lines, not the whole reply.
const int captionLimit = 240;

/// How much of a reply is read aloud. The full text stays in the chat.
const int spokenLimit = 500;

/// Plain caption from a Muse reply, with markdown removed.
String captionFromReply(String text) => _clip(_clean(text), captionLimit);

/// What the speaker should say. Same cleaning, a little more room.
String speakableReply(String text) => _clip(_clean(text), spokenLimit);

/// Short line for an `agent.status` activity code, or null when it is empty.
String? activityCaption(String code) {
  final key = code.trim().toLowerCase().replaceAll(' ', '_');
  if (key.isEmpty) return null;
  const known = <String, String>{
    'thinking': 'Thinking…',
    'working': 'Working…',
    'searching': 'Searching…',
    'reading': 'Reading…',
    'writing': 'Writing…',
    'listening': 'Listening…',
    'speaking': 'Speaking…',
    'browsing': 'Looking something up…',
    'using_tool': 'Using a tool…',
    'tool': 'Using a tool…',
    'waiting': 'Waiting…',
  };
  final mapped = known[key];
  if (mapped != null) return mapped;
  final words = key.split('_').where((word) => word.isNotEmpty).join(' ');
  if (words.isEmpty) return null;
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

String _clip(String text, int limit) {
  if (text.length <= limit) return text;
  return '${text.substring(0, limit - 1).trimRight()}…';
}

String _clean(String text) {
  var value = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
  value = value.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]+\)'),
    (match) => match.group(1) ?? '',
  );
  value = value.replaceAll(RegExp(r'[*_~`#>]+'), '');
  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return value;
}
