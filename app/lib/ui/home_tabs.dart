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
  static const int _settingsIndex = 5;

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  int _index = 0;
  int _previousIndex = 0;

  void _selectTab(int i) => setState(() {
        if (i != _index) _previousIndex = _index;
        _index = i;
      });

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  /// Settings is a detail page: back returns to the tab we came from.
  void _backFromSettings() => _selectTab(
      _previousIndex == _settingsIndex ? 0 : _previousIndex);

  bool get _onSettings => _index == _settingsIndex;

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
      key: _scaffoldKey,
      backgroundColor: museInk,
      // Slide-in navigation drawer. Nothing persistent overlays content;
      // Settings is a detail page, so the edge-drag gesture is off there
      // (its back button is the way out).
      drawer: _NavDrawer(
        tabs: _tabs,
        index: _index,
        onSelect: _selectTab,
      ),
      drawerEnableOpenDragGesture: !_onSettings,
      body: IndexedStack(
        index: _index,
        children: [
          CompanionScreen(onMenu: _openDrawer),
          ChatScreen(onMenu: _openDrawer),
          DeviceScreen(onMenu: _openDrawer),
          ActivityScreen(onMenu: _openDrawer),
          MediaScreen(onMenu: _openDrawer),
          _SettingsTab(onBack: _backFromSettings),
        ],
      ),
    );
  }
}

/// Settings as a detail page: grabs AppScope at build time so the tab list
/// can stay const while SettingsScreen gets its callbacks. The drawer
/// stays closed here; [onBack] returns to the previous tab.
class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return SettingsScreen(
      onSendChat: (msg, attachments) =>
          scope.service.sendChat(msg, null, attachments),
      onBack: onBack,
    );
  }
}

/// Slide-in navigation drawer: the six destinations as icon + label rows.
/// The active destination gets the MuseBubble glow so it's always clear
/// where you are. Tapping a destination navigates and closes the drawer;
/// the scrim and edge-swipe behaviors are the standard Drawer ones.
class _NavDrawer extends StatelessWidget {
  const _NavDrawer({
    required this.tabs,
    required this.index,
    required this.onSelect,
  });

  final List<_Tab> tabs;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      backgroundColor: museInk,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  const MuseLogo(size: 40),
                  const SizedBox(width: 12),
                  Text(
                    'Muse',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(
              color: Color(0x22FFFFFF),
              indent: 20,
              endIndent: 20,
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: tabs.length,
                itemBuilder: (context, i) {
                  final tab = tabs[i];
                  final active = i == index;
                  final row = Row(
                    children: [
                      Icon(
                        active ? tab.activeIcon : tab.icon,
                        color: active
                            ? museBlue
                            : museMist.withValues(alpha: 0.75),
                        size: 22,
                      ),
                      const SizedBox(width: 16),
                      Text(
                        tab.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight:
                              active ? FontWeight.w700 : FontWeight.w500,
                          color: active
                              ? museMist
                              : museMist.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  );
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    child: InkWell(
                      key: ValueKey('drawer_${tab.label}'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        onSelect(i);
                        Navigator.of(context).pop();
                      },
                      child: active
                          ? MuseBubble(child: row)
                          : Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              child: row,
                            ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
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
