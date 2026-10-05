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
// a floating row with no hard background bar — plain 20px icons over the
// page background, tooltips instead of labels, and the active tab wrapped
// in a MuseBubble (rounded, themed) for the accent. A soft gradient scrim
// behind the icons keeps them readable over content without a hard edge.
//
// The bar auto-hides on scroll-down in scrollable tabs (slide + fade,
// ~200ms) and comes back on scroll-up, on reaching the top, on tapping
// the slim edge handle, or on switching tabs — so it never interferes
// with content and never strands the user without navigation.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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

  /// Drives the floating tab bar's auto-hide. Scrolling down in the active
  /// tab hides the bar (and its gradient scrim fades with it); scrolling up,
  /// tapping the edge handle, or switching tabs brings it back.
  final ValueNotifier<bool> _tabBarVisible = ValueNotifier<bool>(true);

  @override
  void dispose() {
    _tabBarVisible.dispose();
    super.dispose();
  }

  void _selectTab(int i) {
    // Switching tabs always recovers the bar - never strand the user
    // without navigation.
    _tabBarVisible.value = true;
    setState(() => _index = i);
  }

  /// Standard hide-on-scroll-down / show-on-scroll-up, driven by scroll
  /// notifications bubbling up from the active tab's scrollable. The Home
  /// tab (CompanionScreen) is not scrollable, so it never hides the bar.
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification) {
      switch (notification.direction) {
        case ScrollDirection.reverse:
          if (_tabBarVisible.value) _tabBarVisible.value = false;
        case ScrollDirection.forward:
          if (!_tabBarVisible.value) _tabBarVisible.value = true;
        case ScrollDirection.idle:
          break;
      }
    } else if (notification is ScrollUpdateNotification) {
      // Reaching the very top always restores the bar.
      if (notification.metrics.pixels <= notification.metrics.minScrollExtent &&
          !_tabBarVisible.value) {
        _tabBarVisible.value = true;
      }
    }
    return false; // let the notification keep bubbling
  }

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
    // While the keyboard is up the tab bar is useless (no tab
    // switching mid-typing) and just eats vertical space, worst in
    // landscape. Hide it; the ValueNotifier keeps the pre-keyboard
    // state so closing the keyboard restores exactly what was there.
    // The slim edge handle hides too: it sits behind the keyboard.
    final keyboardUp = MediaQuery.of(context).viewInsets.bottom > 0;
    return Scaffold(
      backgroundColor: museInk,
      // The tab bar floats as a Stack overlay instead of using the
      // bottomNavigationBar slot. Tab content flows full-height underneath;
      // a soft gradient scrim behind the icons keeps them readable without
      // a hard bar edge.
      body: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: IndexedStack(
              index: _index,
              children: [
                // CompanionScreen is full-bleed: its own Column carries an
                // internal bottom spacer clearing the floating tab bar.
                // No outer Padding here - that would reveal the scaffold
                // background as a solid strip behind the icons.
                const CompanionScreen(),
                const ChatScreen(),
                const DeviceScreen(),
                const ActivityScreen(),
                const MediaScreen(),
                const _SettingsTab(),
              ],
            ),
          ),
          // Floating tab bar: auto-hides on scroll-down (slide + fade);
          // the gradient scrim is inside the animated child so it fades
          // away with the icons instead of lingering as a floating strip.
          // NOTE: Positioned must stay a direct child of the outer Stack -
          // the animation widgets wrap its child, not the Positioned itself.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ValueListenableBuilder<bool>(
              valueListenable: _tabBarVisible,
              builder: (context, visible, child) {
                final effectiveVisible = visible && !keyboardUp;
                return AnimatedSlide(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  offset: effectiveVisible ? Offset.zero : const Offset(0, 1.5),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    opacity: effectiveVisible ? 1.0 : 0.0,
                    child: child,
                  ),
                );
              },
              child: SafeArea(
                // Key for widget tests to scope to the tab bar.
                key: const ValueKey('tabBarSafeArea'),
                top: false,
                child: Stack(
                  children: [
                    // Soft gradient scrim: keeps the floating icons readable
                    // over scrolling content without a hard bar edge.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                museInk.withValues(alpha: 0.0),
                                museInk.withValues(alpha: 0.6),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (var i = 0; i < _tabs.length; i++)
                            _TabIcon(
                              tab: _tabs[i],
                              active: i == _index,
                              onTap: () => _selectTab(i),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Slim edge handle: visible only while the tab bar is hidden, so
          // there's always a tappable way to bring navigation back.
          // (Positioned stays a direct child of the outer Stack.)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ValueListenableBuilder<bool>(
              valueListenable: _tabBarVisible,
              builder: (context, visible, _) {
                if (visible || keyboardUp) return const SizedBox.shrink();
                return SafeArea(
                  top: false,
                  child: GestureDetector(
                    key: const ValueKey('tabBarHandle'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _tabBarVisible.value = true,
                    child: Container(
                      height: 28,
                      alignment: Alignment.center,
                      child: Container(
                        width: 48,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFF5A7395).withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                );
              },
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
            child: Icon(tab.activeIcon, size: 20, color: museBlue),
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
