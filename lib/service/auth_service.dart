import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; // NAYA IMPORT

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<bool> signInWithGoogle() async {
    try {
      // 1. Google Auth Process
      await _googleSignIn.initialize();
      final GoogleSignInAccount googleUser = await _googleSignIn.authenticate();
      final GoogleSignInAuthentication googleAuth = googleUser.authentication;
      final OAuthCredential credential = GoogleAuthProvider.credential(idToken: googleAuth.idToken);
      UserCredential userCredential = await _auth.signInWithCredential(credential);
      User? user = userCredential.user;

      if(user != null){
        // 2. FCM Token Nikalo
        String? fcmToken = await FirebaseMessaging.instance.getToken();

        DocumentSnapshot userDoc = await _firestore.collection('users').doc(user.uid).get();

        if(!userDoc.exists){
          // NAYA USER (Sign Up) - Token ke sath pura data set karo
          await _firestore.collection('users').doc(user.uid).set({
            'uid': user.uid,
            'name': user.displayName ?? "Unknown",
            'email': user.email ?? '',
            'profilePic': user.photoURL ?? '',
            'createdAt': FieldValue.serverTimestamp(),
            'lastSeen': FieldValue.serverTimestamp(),
            'isOnline': true,
            'hasAccess': true,
            'fcm_token': fcmToken ?? '', // TOKEN SAVED
          });
        } else {
          // PURANA USER (Login) - Sirf token aur online status update karo
          // (Kyunki ho sakta hai user ne naya phone liya ho)
          await _firestore.collection('users').doc(user.uid).update({
            'isOnline': true,
            'lastSeen': FieldValue.serverTimestamp(),
            'fcm_token': fcmToken ?? '', // TOKEN UPDATED
          });
        }
      }
      return true;
    } catch (e) {
      throw Exception("Authentication Exception: $e");
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }
}