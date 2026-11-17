import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' as typed_data;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:expresso/screens/home_screen.dart';
import 'package:expresso/screens/login_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'firebase_options.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  String chatRoomId = message.data['chatRoomId'] ?? '';
  String messageId = message.data['messageId'] ?? '';
  if (chatRoomId.isNotEmpty && messageId.isNotEmpty) {
    await FirebaseFirestore.instance
        .collection('chat_rooms')
        .doc(chatRoomId)
        .collection('messages')
        .doc(messageId)
        .update({'status': 'delivered'});
  }

  await _showBackgroundNotification(message);
}

Future<void> _showBackgroundNotification(RemoteMessage message) async {
  final FlutterLocalNotificationsPlugin localNotifications =
  FlutterLocalNotificationsPlugin();

  const AndroidInitializationSettings androidInit =
  AndroidInitializationSettings('@mipmap/ic_launcher');
  await localNotifications.initialize(
      settings: const InitializationSettings(android: androidInit));

  String title = message.data['title'] ?? 'New Message';
  String body = message.data['body'] ?? '';
  String senderId = message.data['senderId'] ?? '';
  String profilePicUrl = message.data['profilePic'] ?? '';

  typed_data.Uint8List? profileBitmap;
  if (profilePicUrl.isNotEmpty) {
    try {
      final response = await http.get(Uri.parse(profilePicUrl));
      if (response.statusCode == 200) {
        profileBitmap = typed_data.Uint8List.fromList(response.bodyBytes);
      }
    } catch (_) {}
  }

  // ✅ App open wala same style — MessagingStyleInformation
  final Person person = Person(
    name: title,
    icon: profileBitmap != null
        ? ByteArrayAndroidIcon(profileBitmap)
        : const DrawableResourceAndroidIcon('@mipmap/ic_launcher'),
    important: true,
  );

  final MessagingStyleInformation messagingStyle = MessagingStyleInformation(
    person,
    conversationTitle: title,
    groupConversation: false,
    messages: [
      Message(
        body,
        DateTime.now(),
        person,
      )
    ],
  );

  final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'expresso_channel',
    'Chat Messages',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
    groupKey: senderId,
    // ✅ largeIcon mein profile pic
    largeIcon: profileBitmap != null
        ? ByteArrayAndroidBitmap(profileBitmap)
        : const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
    // ✅ BigPictureStyleInformation HATA DO — MessagingStyle use karo
    styleInformation: messagingStyle,
  );

  await localNotifications.show(
    id: senderId.hashCode,
    title: title,
    body: body,
    notificationDetails: NotificationDetails(android: androidDetails),
    payload: jsonEncode(message.data),
  );
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = MyHttpOverrides();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform,);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Expresso',
        navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: Colors.lightBlue,
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const AuthGate()
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(color: Colors.lightBlue)),
          );
        }
        if (snapshot.hasData) {
          return const HomeScreen();
        }
        return const LoginScreen();
      },
    );
  }
}