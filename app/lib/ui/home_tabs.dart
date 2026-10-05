// Copyright (c) Meta Platforms, Inc. and affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Home tabs with floating side-dock navigation.
//
// Six destinations, no bottom bar. Navigation is a slim vertical dock
// floating on the right edge in the MuseBubble aesthetic: small circular
// icon buttons in a semi-transparent pill, the active destination wrapped
// in a glowing MuseBubble. The bottom of the screen stays clean and
// full-bleed - no clearance workarounds needed in any tab.

import 'package:flutter/material.dart';

import 'activity_screen.dart';
import 'chat_screen.dart';
import 'companion_screen.dart';
import 'device_screen.dart';
import 'media_screen.dart';
import 'settings_screen.dart';
import 'muse_theme.dart';
import 'scope.dart';

/// Home with side-dock navigation. Each tab keeps its own state via
/// IndexedStack; the Companion avatar screen is tab 0 (the default).
class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int _index = 0;

  void _selectTab(int i) => setState(() => _index = i);

  static const _tabs = [
    _Tab(label: 'Home', icon: Icons.pets_outlined, activeIcon: Icons.pets),
    _Tab(
      label: 'Chat',
      icon: Icons.chat_bubble_outline,
      activeIcon: Icons.chat_bubble,
    ),
    _Tab(
      label: 'Device',
      icon: Icons.phone_android_outlined,
      activeIcon: Icons.phone_android,
    ),
    _Tab(
      label: 'Activity',
      icon: Icons.receipt_long_outlined,
      activeIcon: Icons.receipt_long,
    ),
    _Tab(
      label: 'Media',
      icon: Icons.photo_library_outlined,
      activeIcon: Icons.photo_library,
    ),
    _Tab(
      label: 'Settings',
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: museInk,
      // The dock floats over full-bleed tab content; nothing is reserved
      // at the bottom of the screen.
      body: Stack(
        children: [
          IndexedStack(
            index: _index,
            children: [
              const CompanionScreen(),
              const ChatScreen(),
              const DeviceScreen(),
              const ActivityScreen(),
              const MediaScreen(),
              const _SettingsTab(),
            ],
          ),
          // Floating side dock: right edge, vertically centered.
          // Positioned.fill + Align keeps it a direct Stack child.
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: SafeArea(
                left: false,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _SideDock(
                    key: const ValueKey('sideDock'),
                    tabs: _tabs,
                    index: _index,
                    onSelect: _selectTab,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings as a tab: grabs AppScope at build time so the tab list can
/// stay const while SettingsScreen gets its onSendChat callback.
class _SettingsTab extends StatelessWidget {
  const _SettingsTab();

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return SettingsScreen(
      onSendChat: (msg, attachments) =>
          scope.service.sendChat(msg, null, attachments),
    );
  }
}

/// Slim vertical floating dock: six small circular destinations in a
/// semi-transparent pill. The active destination gets the MuseBubble
/// glow; inactive ones are plain floating icons.
class _SideDock extends StatelessWidget {
  const _SideDock({
    super.key,
    required this.tabs,
    required this.index,
    required this.onSelect,
  });

  final List<_Tab> tabs;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      // Semi-transparent at rest so it stays out of the content's way.
      opacity: 0.88,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: museNight.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < tabs.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: _DockIcon(
                  tab: tabs[i],
                  active: i == index,
                  onTap: () => onSelect(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One dock destination: a glowing MuseBubble circle when active,
/// a plain floating icon when inactive.
class _DockIcon extends StatelessWidget {
  const _DockIcon({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  final _Tab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      active ? tab.activeIcon : tab.icon,
      size: 20,
      color: active ? museBlue : const Color(0xFF9DB9DC),
      shadows: const [
        Shadow(
          color: Colors.black54,
          blurRadius: 4,
          offset: Offset(0, 1),
        ),
      ],
    );
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Tooltip(
        message: tab.label,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: icon,
        ),
      ),
    );
    if (active) {
      return MuseBubble(
        padding: EdgeInsets.zero,
        radius: 22,
        child: button,
      );
    }
    return button;
  }
}

class _Tab {
  const _Tab({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
}
