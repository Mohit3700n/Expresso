import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:minio/io.dart';
import 'package:minio/minio.dart';
import '../models/message.dart';

class ChatService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final String _apiUrl = "https://biblekhazana.com/expresso/send_expresso_notification.php";
  final String _apiKey = "WHATSAPP_CLONE_SECURE_KEY_2026";

  final Minio minio = Minio(
    endPoint: '084ec757be409abbe3581ef9e91f02dc.r2.cloudflarestorage.com',
    accessKey: '45e178c53a8e677cfb8098058960beb1',
    secretKey: '302584890456dc478dd7f4882eaccbcec7b7ade50d2a3e001e42dbfbe7a70606',
    useSSL: true,
  );

  final String r2BucketName = 'expresso';
  final String r2PublicDomain = 'https://pub-01a3f73690894fc39cec4138ac040a14.r2.dev';

  Future<String?> uploadDirectToR2(File file, String type) async {
    try {
      String ext = file.path.split('.').last;

      String fileName = '${type}_${DateTime.now().millisecondsSinceEpoch}.$ext';

      await minio.fPutObject(
        r2BucketName,
        fileName,
        file.path,
      );

      return '$r2PublicDomain/$fileName';

    } catch (e) {
      debugPrint("R2 Direct Upload Error: $e");
      return null;
    }
  }

  Future<void> sendMediaMessage(String receiverId, String type, File file) async {
    final String currentUserId = _auth.currentUser!.uid;
    final String currentUserEmail = _auth.currentUser!.email ?? '';

    String? mediaUrl = await uploadDirectToR2(file, type);

    if (mediaUrl == null) {
      debugPrint("Upload failed, stopping message send process.");
      return;
    }

    String displayMessage = '📁 File';
    if (type == 'image') {
      displayMessage = '📷 Photo';
    } else if (type == 'video'){
      displayMessage = '🎥 Video';
    } else if (type == 'audio'){
      displayMessage = '🎵 Voice Note';
    } else if (type == 'document'){
      displayMessage = '📄 Document';
    }

    Message newMessage = Message(
      senderId: currentUserId,
      senderEmail: currentUserEmail,
      receiverId: receiverId,
      message: displayMessage,
      timestamp: Timestamp.now(),
      status: 'sent',
      messageType: type,
      mediaUrl: mediaUrl,
    );

    List<String> ids = [currentUserId, receiverId];
    ids.sort();
    String chatRoomId = ids.join("_");

    try {
      DocumentReference docRef = await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .add(newMessage.toMap());

      await _triggerPushNotification(
        receiverId: receiverId,
        messageText: displayMessage,
        chatRoomId: chatRoomId,
        messageId: docRef.id,
      );
    } catch (e) {
      debugPrint("Error sending media message: $e");
    }
  }

  Future<void> sendMessage(String receiverId, String messageText) async {
    final String currentUserId = _auth.currentUser!.uid;
    final String currentUserEmail = _auth.currentUser!.email ?? '';
    final Timestamp timestamp = Timestamp.now();

    Message newMessage = Message(
        senderId: currentUserId,
        senderEmail: currentUserEmail,
        receiverId: receiverId,
        message: messageText,
        timestamp: timestamp,
        status: 'sent',
        messageType: 'text',
        mediaUrl: ''
    );

    List<String> ids = [currentUserId, receiverId];
    ids.sort();
    String chatRoomId = ids.join("_");

    try {
      DocumentReference docRef = await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .add(newMessage.toMap());

      await _triggerPushNotification(
        receiverId: receiverId,
        messageText: messageText,
        chatRoomId: chatRoomId,
        messageId: docRef.id,
      );
    } catch (e) {
      debugPrint("Error sending text message: $e");
    }
  }

  Future<void> _triggerPushNotification({
    required String receiverId,
    required String messageText,
    required String chatRoomId,
    required String messageId,
  }) async {
    final String currentUserId = _auth.currentUser!.uid;

    try {
      DocumentSnapshot receiverDoc = await _firestore.collection('users').doc(receiverId).get();

      if (receiverDoc.exists) {
        Map<String, dynamic> receiverData = receiverDoc.data() as Map<String, dynamic>;
        String? receiverToken = receiverData['fcm_token'];

        if (receiverToken != null && receiverToken.isNotEmpty) {
          DocumentSnapshot senderDoc = await _firestore.collection('users').doc(currentUserId).get();
          String senderName = senderDoc['name'] ?? 'New Message';
          String senderPic = senderDoc['profilePic'] ?? '';
          String senderEmail = senderDoc['email'] ?? '';

          var response = await http.post(
            Uri.parse(_apiUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': _apiKey,
            },
            body: jsonEncode({
              'token': receiverToken,
              'title': senderName,
              'body': messageText,
              'chatRoomId': chatRoomId,
              'senderId': currentUserId,
              'messageId': messageId,
              'profilePic': senderPic,
              'email': senderEmail,
            }),
          );

          if (response.statusCode == 200) {
            debugPrint("Notification API Hit Success for $messageText!");
          } else {
            debugPrint("Notification API Failed: ${response.statusCode} - ${response.body}");
          }
        }
      }
    } catch (e) {
      debugPrint("Error inside _triggerPushNotification: $e");
    }
  }

  Future<void> updateMessageStatus(String chatRoomId, String messageId, String newStatus) async {
    try {
      await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId)
          .update({'status': newStatus});
    } catch (e) {
      debugPrint("Status Update Error: $e");
    }
  }

  Stream<QuerySnapshot> getMessages(String userId, String otherUserId, int limit) {
    List<String> ids = [userId, otherUserId];
    ids.sort();
    String chatRoomId = ids.join("_");

    return _firestore
        .collection('chat_rooms')
        .doc(chatRoomId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(limit)
        .snapshots();
  }

  // 1. DELETE FOR EVERYONE (Message text badal jayega aur media links clear ho jayenge)
  Future<void> deleteMessageForEveryone(String chatRoomId, String messageId) async {
    try {
      await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId)
          .update({
        'message': '🚫 This message was deleted',
        'messageType': 'text',
        'mediaUrl': '',
        'isDeleted': true, // Identifier flag for UI formatting
      });
    } catch (e) {
      debugPrint("Delete Everyone Error: $e");
    }
  }

  // 2. DELETE FOR ME (User ID ko array me push karo taaki query me filter ho sake)
  Future<void> deleteMessageForMe(String chatRoomId, String messageId, String userId) async {
    try {
      await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId)
          .update({
        'deletedBy': FieldValue.arrayUnion([userId]),
      });
    } catch (e) {
      debugPrint("Delete For Me Error: $e");
    }
  }

  // 3. EDIT MESSAGE (Strictly text update aur flag insertion)
  Future<void> editMessage(String chatRoomId, String messageId, String newText) async {
    try {
      await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId)
          .update({
        'message': newText,
        'isEdited': true,
      });
    } catch (e) {
      debugPrint("Edit Message Error: $e");
    }
  }

}