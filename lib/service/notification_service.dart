import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import '../main.dart';
import '../screens/chat_screen.dart';

class ChatState {
  static String? currentActiveChatId;
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  final Map<String, List<Message>> _messagesByUser = {};

  Future<Uint8List?> _getBitmapFromUrl(String url) async {
    if (url.isEmpty) {
      debugPrint("⚠️ Profile pic URL is empty!");
      return null;
    }
    try {
      debugPrint("📸 Fetching profile pic from: $url");
      final http.Response response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        debugPrint("✅ Profile pic fetched successfully");
        return response.bodyBytes;
      } else {
        debugPrint("❌ Failed to fetch pic: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Error downloading notification profile pic: $e");
    }
    return null;
  }

  Future<void> setupPushNotifications() async {
    User? currentUser = _auth.currentUser;
    if (currentUser == null) return;

    const AndroidInitializationSettings androidInitSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initSettings = InitializationSettings(android: androidInitSettings,);

    await _localNotifications.initialize(
        settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response){
          if(response.payload != null){
            _handleNotificationClick(response.payload!);
          }
      }
    );

    NotificationSettings settings = await _firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint('User granted notification permission');

      String? token = await _firebaseMessaging.getToken();

      if (token != null) {
        await _saveTokenToDatabase(token, currentUser.uid);
      }

      _firebaseMessaging.onTokenRefresh.listen((newToken) {
        _saveTokenToDatabase(newToken, currentUser.uid);
      });

      FirebaseMessaging.onMessage.listen((RemoteMessage message) {

        String incomingSenderId = message.data['senderId'] ?? '';
        String chatRoomId = message.data['chatRoomId'] ?? '';
        String messageId = message.data['messageId'] ?? '';

        if (chatRoomId.isNotEmpty && messageId.isNotEmpty) {
          FirebaseFirestore.instance
              .collection('chat_rooms')
              .doc(chatRoomId)
              .collection('messages')
              .doc(messageId)
              .update({'status': 'delivered'});
        }

        if (ChatState.currentActiveChatId != incomingSenderId) {
          _showLocalNotification(message);
        } else {
          debugPrint("User is already on the chat screen. Suppressing notification.");
        }
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        _handleFirebaseMessageClick(message);
      });

      _firebaseMessaging.getInitialMessage().then((RemoteMessage? message) {
        if (message != null) {
          _handleFirebaseMessageClick(message);
        }
      });

    } else {
      debugPrint('User declined notification permission');
    }
  }


  void _handleFirebaseMessageClick(RemoteMessage message) {
    _navigateToChat(
      senderId: message.data['senderId'] ?? '',
      senderName: message.data['title'] ?? 'User',
      profilePic: message.data['profilePic'] ?? '',
      email: message.data['email'] ?? '',
    );
  }

  void _handleNotificationClick(String payload) {
    try {
      Map<String, dynamic> data = jsonDecode(payload);
      _navigateToChat(
        senderId: data['senderId'] ?? '',
        senderName: data['title'] ?? 'User',
        profilePic: data['profilePic'] ?? '',
        email: data['email'] ?? '',
      );
    } catch (e) {
      debugPrint("Error routing from notification: $e");
    }
  }

  void _navigateToChat({required String senderId, required String senderName, required String profilePic, required String email}) {
    if (senderId.isNotEmpty && ChatState.currentActiveChatId != senderId) {
      clearNotification(senderId); // Screen par jaate hi clean karo
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            receiverUserName: senderName,
            receiverUserID: senderId,
            profilePic: profilePic,
            email: email,
          ),
        ),
      );
    }
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    String senderId = message.data['senderId'] ?? '';
    String profilePicUrl = message.data['profilePic'] ?? '';
    String title = message.data['title'] ?? 'New Message';  // ← data se lo
    String body = message.data['body'] ?? '';

    Uint8List? profileBitmap = await _getBitmapFromUrl(profilePicUrl);

    _messagesByUser[senderId] ??= [];
    _messagesByUser[senderId]!.add(Message(
      body,
      DateTime.now(),
      Person(
        name: title,
        icon: profileBitmap != null
            ? ByteArrayAndroidIcon(profileBitmap)
            : DrawableResourceAndroidIcon('@mipmap/ic_launcher'),
        important: true,
      ),
    ));

    Person person = Person(
      name: title,
      icon: profileBitmap != null
          ? ByteArrayAndroidIcon(profileBitmap)
          : DrawableResourceAndroidIcon('@mipmap/ic_launcher'),
      important: true,
    );

    MessagingStyleInformation messagingStyle = MessagingStyleInformation(
      person,
      conversationTitle: title,
      groupConversation: false,
      messages:_messagesByUser[senderId]!
    );

    AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'expresso_channel',
      'Chat Messages',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      groupKey: senderId,
      styleInformation: messagingStyle,
      largeIcon: profileBitmap != null
          ? ByteArrayAndroidBitmap(profileBitmap)
          : const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
    );

    NotificationDetails platformDetails = NotificationDetails(android: androidDetails,);

    await _localNotifications.show(
      id: senderId.hashCode,
      title: title,
      body: body,
      notificationDetails: platformDetails,
      payload: jsonEncode(message.data)
    );
  }

  Future<void> clearNotification(String targetSenderId) async {
    _messagesByUser.remove(targetSenderId);
    try {
      await _localNotifications.cancel(id: targetSenderId.hashCode);
    } catch (e) {
      debugPrint("Error clearing notifications: $e");
    }
  }

  Future<void> _saveTokenToDatabase(String token, String uid) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'fcm_token': token,
      });
      debugPrint("FCM Token Saved Successfully");
    } catch (e) {
      debugPrint("Error saving token: $e");
    }
  }
}