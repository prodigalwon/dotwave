import 'package:flutter/material.dart';
import 'screens/home_tab.dart';
import 'screens/messages_tab.dart';
import 'screens/explore_tab.dart';
import 'screens/profile_tab.dart';
import 'services/theme_controller.dart';
import 'theme.dart';

class HomeShell extends StatefulWidget {
  final String address;
  const HomeShell({super.key, required this.address});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Rebuild the tabs when the brand accent changes so static accent reads
      // (e.g. the balance card) re-skin live. Tab State is preserved — Flutter
      // matches the rebuilt widgets by type+position, so nothing reloads.
      body: AnimatedBuilder(
        animation: ThemeController.instance,
        builder: (context, _) => IndexedStack(
          index: _currentIndex,
          children: [
            HomeTab(
              address: widget.address,
              onOpenMessages: () => setState(() => _currentIndex = 1),
            ),
            MessagesTab(address: widget.address),
            ExploreTab(address: widget.address),
            ProfileTab(address: widget.address),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: AppTheme.borderSubtle, width: 1),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) => setState(() => _currentIndex = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Messages',
            ),
            NavigationDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view),
              label: 'Explore',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
