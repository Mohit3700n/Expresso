import 'package:expresso/screens/link_extractor_tab.dart';
import 'package:expresso/screens/youtube_tab.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../service/auth_service.dart';
import '../service/notification_service.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  int _selectedIndex = 0;
  late PageController _pageController;

  late Stream<DocumentSnapshot> _userStream;

  void updateOnlineStatus(bool isOnline) async {
    final user = _auth.currentUser;
    if (user != null) {
      await _firestore.collection('users').doc(user.uid).update({
        'isOnline': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    updateOnlineStatus(true);
    NotificationService().setupPushNotifications();
    _pageController = PageController(initialPage: _selectedIndex);
    final user = _auth.currentUser;
    if (user != null) {
      _userStream = _firestore.collection('users').doc(user.uid).snapshots();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      updateOnlineStatus(true);
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      updateOnlineStatus(false);
    }
  }

  void _logout() async {
    await AuthService().signOut();
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
    // PageView ko us index par animate karo
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  // NAYA: Jab user screen ko left/right swipe kare
  void _onPageChanged(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    if (user == null) return const Scaffold(body: Center(child: Text("Not logged in")));

    // REAL-TIME ACCESS LISTENER
    return StreamBuilder<DocumentSnapshot>(
      stream: _userStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(backgroundColor: Colors.white, body: Center(child: CircularProgressIndicator(color: Colors.lightBlue)));
        }

        if (snapshot.hasData && snapshot.data!.exists) {
          Map<String, dynamic> userData = snapshot.data!.data() as Map<String, dynamic>;

          bool hasAccess = userData.containsKey('hasAccess') ? userData['hasAccess'] : true;

          if (!hasAccess) {
            return _buildAccessDeniedScreen();
          }
        }

        // AGAR ACCESS HAI, TOH NORMAL APP DIKHAO
        return Scaffold(
          backgroundColor: Colors.white,
          body: PageView(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            physics: const BouncingScrollPhysics(),
            children: [
              _buildChatsTab(),
              const YouTubeTab(),
              const LinkExtractorTab()
            ],
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _selectedIndex,
            onTap: _onItemTapped,
            selectedItemColor: Colors.lightBlue,
            unselectedItemColor: Colors.grey,
            backgroundColor: Colors.white,
            elevation: 10,
            type: BottomNavigationBarType.fixed,
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.chat_bubble_outline), activeIcon: Icon(Icons.chat_bubble), label: "Chats"),
              BottomNavigationBarItem(icon: Icon(Icons.smart_display_outlined), activeIcon: Icon(Icons.smart_display), label: "YouTube"),
              BottomNavigationBarItem(icon: Icon(Icons.grain_rounded), activeIcon: Icon(Icons.grain_outlined), label: "Link Extractor"),
            ],
          ),
        );
      },
    );
  }

  // NAYA: Access Denied UI
  Widget _buildAccessDeniedScreen() {
    return Scaffold(
      backgroundColor: Colors.redAccent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.block, size: 100, color: Colors.white),
              const SizedBox(height: 24, width: double.infinity),
              const Text(
                "Access Denied",
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 12),
              const Text(
                "Your access to this application has been revoked by the developer. Contact support for more information.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.white70),
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: _logout, // User ko wapas login page bhej dega
                icon: const Icon(Icons.logout, color: Colors.redAccent),
                label: const Text("Logout", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatsTab() {
    // NAYA: Chats tab ko apna khud ka Scaffold aur AppBar de diya hai
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("Expresso", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.lightBlue,
        actions: [
          IconButton(icon: const Icon(Icons.logout, color: Colors.white), onPressed: _logout,)
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text("Error fetching users"));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Colors.lightBlue));
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text("No users found"));
          }

          return ListView(
            physics: const BouncingScrollPhysics(),
            children: snapshot.data!.docs.map<Widget>((doc) => _buildUserListItem(doc)).toList(),
          );
        },
      ),
    );
  }

  Widget _buildUserListItem(DocumentSnapshot document) {
    Map<String, dynamic> data = document.data()! as Map<String, dynamic>;

    /*if (_auth.currentUser!.uid == data['uid']) {
      return const SizedBox.shrink();
    }*/

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.lightBlue.shade100,
        backgroundImage: data['profilePic'] != '' ? NetworkImage(data['profilePic']) : null,
        child: data['profilePic'] == '' ? const Icon(Icons.person, color: Colors.white) : null,
      ),
      title: Text(
        (_auth.currentUser!.uid == data['uid']) ? "${data['name']} (You)" : data['name'] ?? 'Unknown User',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(data['email'] ?? ''),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(
              receiverUserName: data['name'] ?? 'User',
              receiverUserID: data['uid'],
              profilePic: data['profilePic'],
              email: data['email'],
            ),
          ),
        );
      },
    );
  }
}