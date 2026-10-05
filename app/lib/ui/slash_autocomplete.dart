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
// `/` autocomplete for slash commands in the chat composer.
//
// Type `/` and a popup lists the available commands with one-line
// descriptions; it filters as you type, tapping one inserts it, and it
// dismisses when you backspace past the `/`, finish the command, or tap
// away. The command list is data-driven ([kSlashCommands]) so new
// commands are added in one place.
//
// Attribution: autocomplete-for-commands concept adapted from
// hermes-mobile-app (MIT, omarqaterge/hermes-mobile-app).

import 'package:flutter/material.dart';

/// One slash command the composer understands.
class SlashCommand {
  const SlashCommand({required this.name, required this.description});

  /// Command name without the leading `/`, e.g. `photo`.
  final String name;

  /// One-line description shown in the autocomplete popup.
  final String description;

  /// The trigger text typed in the composer, e.g. `/photo`.
  String get trigger => '/$name';
}

/// All composer slash commands. Add new ones here — they show up in the
/// autocomplete popup automatically. The handling switch in
/// `chat_screen.dart` (`_handleSlash`) must know them too.
const List<SlashCommand> kSlashCommands = <SlashCommand>[
  SlashCommand(
    name: 'photo',
    description: 'Take a photo with the camera and send it',
  ),
  SlashCommand(
    name: 'voice',
    description: 'How to record and send a voice note',
  ),
  SlashCommand(
    name: 'local',
    description: 'Ask the on-device local AI (add your instruction after a space)',
  ),
  SlashCommand(
    name: 'speak',
    description: 'Read the last assistant reply aloud',
  ),
];

/// If [cursorOffset] sits at the end of a leading-slash token in [text],
/// return the query typed after the slash. Otherwise null.
///
/// Only a slash at the very start counts — that is the only place the
/// composer treats text as a command — and the token must not contain
/// whitespace, so once the command is complete and arguments begin, the
/// popup hides. Backspacing past the `/` also yields null (dismiss).
String? slashCommandQuery(String text, int cursorOffset) {
  if (!text.startsWith('/')) return null;
  final end = cursorOffset.clamp(0, text.length);
  final token = text.substring(0, end);
  if (!token.startsWith('/')) return null;
  final query = token.substring(1);
  if (query.contains(RegExp(r'\s'))) return null;
  if (query.contains(RegExp(r'[^a-zA-Z0-9_-]'))) return null;
  return query;
}

/// Commands whose names start with [query] (case-insensitive prefix).
/// An empty query matches everything.
List<SlashCommand> matchingSlashCommands(String query) {
  final q = query.toLowerCase();
  return kSlashCommands
      .where((command) => command.name.toLowerCase().startsWith(q))
      .toList();
}

/// Popup shown above the composer while a slash command is being typed.
class SlashCommandMenu extends StatelessWidget {
  const SlashCommandMenu({
    super.key,
    required this.commands,
    required this.onSelect,
  });

  final List<SlashCommand> commands;
  final ValueChanged<SlashCommand> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(16),
        color: theme.colorScheme.surfaceContainerHigh,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: commands.length,
            itemBuilder: (context, index) {
              final command = commands[index];
              return ListTile(
                dense: true,
                leading: Icon(
                  Icons.terminal,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                title: Text(
                  command.trigger,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(command.description),
                onTap: () => onSelect(command),
              );
            },
          ),
        ),
      ),
    );
  }
}
