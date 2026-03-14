import 'package:flutter/material.dart';
import 'screens/home_tab.dart';
import 'screens/messages_tab.dart';
import 'screens/explore_tab.dart';
import 'screens/profile_tab.dart';

class HomeShell extends StatefulWidget {
  final String address;
  const HomeShell({super.key, required this.address});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _currentIndex = 0;

  late final List<Widget> _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = [
      HomeTab(address: widget.address),
      const MessagesTab(),
      const ExploreTab(),
      ProfileTab(address: widget.address),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _tabs,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        backgroundColor: const Color(0xFF1A1A1A),
        indicatorColor: const Color(0xFFE6007A).withOpacity(0.2),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home, color: Color(0xFFE6007A)),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble, color: Color(0xFFE6007A)),
            label: 'Messages',
          ),
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view, color: Color(0xFFE6007A)),
            label: 'Explore',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person, color: Color(0xFFE6007A)),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
