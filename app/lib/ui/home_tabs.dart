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
// Home tabs: bottom navigation across Home (avatar), Chat, Device,
// Activity, Media, and Settings. The avatar screen stays the default tab.
//
// The tab bar follows the old companion-screen _BottomBar aesthetic:
// a floating row with no background container — plain 20px icons on the
// page background, tooltips instead of labels, and the active tab wrapped
// in a MuseBubble (rounded, themed) for the accent.

import 'package:flutter/material.dart';

import 'activity_screen.dart';
import 'chat_screen.dart';
import 'companion_screen.dart';
import 'device_screen.dart';
import 'media_screen.dart';
import 'settings_screen.dart';
import 'muse_theme.dart';
import 'scope.dart';

/// Bottom-tab home. Each tab keeps its own state via IndexedStack;
/// the Companion avatar screen is tab 0 (the default).
class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int _index = 0;

  static const _tabs = [
    _Tab(
      label: 'Home',
      icon: Icons.pets_outlined,
      activeIcon: Icons.pets,
    ),
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
      // The tab bar floats as a Stack overlay instead of using the
      // bottomNavigationBar slot, so no dark strip paints behind it.
      // Tab content extends underneath the floating icons.
      body: Stack(
        children: [
          // Bottom clearance so tab content is not hidden
          // behind the floating tab row.
          Padding(
            padding: const EdgeInsets.only(bottom: 72),
            child: IndexedStack(
              index: _index,
              children: const [
                CompanionScreen(),
                ChatScreen(),
                DeviceScreen(),
                ActivityScreen(),
                MediaScreen(),
                _SettingsTab(),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              // Key for widget tests to scope to the tab bar.
              key: const ValueKey('tabBarSafeArea'),
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var i = 0; i < _tabs.length; i++)
                      _TabIcon(
                        tab: _tabs[i],
                        active: i == _index,
                        onTap: () => setState(() => _index = i),
                      ),
                  ],
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

/// One tab icon: plain and floating when inactive; wrapped in a MuseBubble
/// (rounded, themed, glowing) when active.
class _TabIcon extends StatelessWidget {
  const _TabIcon({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  final _Tab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (active) {
      return MuseBubble(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Tooltip(
            message: tab.label,
            child: Icon(
              tab.activeIcon,
              size: 20,
              color: museBlue,
            ),
          ),
        ),
      );
    }
    return _InactiveTabIcon(tab: tab, onTap: onTap);
  }
}

/// Inactive tab: a plain 20px muted icon floating on the background.
class _InactiveTabIcon extends StatelessWidget {
  const _InactiveTabIcon({required this.tab, required this.onTap});

  final _Tab tab;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tab.label,
      onPressed: onTap,
      icon: Icon(
        tab.icon,
        size: 20,
        color: const Color(0xFF5A7395), // muted blue-grey
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
