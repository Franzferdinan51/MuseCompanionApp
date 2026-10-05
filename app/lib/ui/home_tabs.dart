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
// Activity, and Media. The avatar screen stays the default tab.
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
import 'muse_theme.dart';

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
      icon: Icons.monitor_heart_outlined,
      activeIcon: Icons.monitor_heart,
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
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: museInk,
      body: IndexedStack(
        index: _index,
        children: const [
          CompanionScreen(),
          ChatScreen(),
          DeviceScreen(),
          ActivityScreen(),
          MediaScreen(),
        ],
      ),
      // No background container — the icons float on the page background,
      // exactly like the old _BottomBar.
      bottomNavigationBar: SafeArea(
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
