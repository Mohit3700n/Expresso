  import 'dart:async';
  import 'dart:io';
  import 'package:audioplayers/audioplayers.dart';
  import 'package:cloud_firestore/cloud_firestore.dart';
  import 'package:firebase_auth/firebase_auth.dart';
  import 'package:flutter/material.dart';
  import 'package:flutter_cache_manager/flutter_cache_manager.dart';
  import 'package:image_picker/image_picker.dart';
  import 'package:open_filex/open_filex.dart';
  import 'package:video_player/video_player.dart';
  import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
  import 'package:file_picker/file_picker.dart';
  import 'package:record/record.dart';
  import 'package:path_provider/path_provider.dart';
  import 'package:wakelock_plus/wakelock_plus.dart';
  import 'package:youtube_explode_dart/youtube_explode_dart.dart';
  
  import '../service/chat_service.dart';
  import '../service/notification_service.dart';
  
  class ChatScreen extends StatefulWidget {
    final String receiverUserName;
    final String receiverUserID;
    final String profilePic;
    final String email;
  
    const ChatScreen({
      super.key,
      required this.receiverUserName,
      required this.receiverUserID,
      required this.profilePic,
      required this.email
    });
  
    @override
    State<ChatScreen> createState() => _ChatScreenState();
  }
  
  class _ChatScreenState extends State<ChatScreen> {
    final TextEditingController _messageController = TextEditingController();
    final TextEditingController _watchPartyLinkController = TextEditingController();
    final ChatService _chatService = ChatService();
    final FirebaseAuth _auth = FirebaseAuth.instance;
    final AudioPlayer _audioPlayer = AudioPlayer();
  
    late String chatRoomId;
    DateTime? _screenOpenedAt;
    bool _isUploading = false;
  
    late Stream<QuerySnapshot> _messagesStream;
    final ScrollController _scrollController = ScrollController();
    int _messageLimit = 20;
    bool _isTyping = false;
  
    final FocusNode _focusNode = FocusNode();
    bool _showEmoji = false;
    bool _showWatchPartyInput = false;
    final AudioRecorder _audioRecorder = AudioRecorder();
    bool _isRecording = false;
    Timer? _recordTimer;
    int _recordDuration = 0;

    StreamSubscription<DocumentSnapshot>? _watchPartySub;
    String? _syncedWatchPartyUrl;
    String? _syncedDirectUrl;
    bool? _isExtractingLink;

    List<QueryDocumentSnapshot> _cachedMessages = [];
  
    final List<DocumentSnapshot> _selectedMessages = [];
  
    @override
    void initState() {
      super.initState();
      ChatState.currentActiveChatId = widget.receiverUserID;
      NotificationService().clearNotification(widget.receiverUserID);
      List<String> ids = [_auth.currentUser!.uid, widget.receiverUserID];
      ids.sort();
      chatRoomId = ids.join("_");
      _screenOpenedAt = DateTime.now();
  
      _messageController.addListener(() {
        setState(() {
          _isTyping = _messageController.text.trim().isNotEmpty;
        });
      });
  
      _focusNode.addListener(() {
        if (_focusNode.hasFocus) {
          setState(() {
            _showEmoji = false;
          });
        }
      });
  
      _scrollController.addListener(_scrollListener);
      _updateMessagesStream();

      _audioPlayer.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          usageType: AndroidUsageType.notification,
          contentType: AndroidContentType.sonification,
          audioFocus: AndroidAudioFocus.none,
        )
      ));

      // Firestore Watch Party Listener
      _watchPartySub = FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('watch_party')
          .doc('sync')
          .snapshots()
          .listen((snapshot) {
        if (snapshot.exists) {
          var data = snapshot.data() as Map<String, dynamic>;
          if (data['isActive'] == true) {
            if (_syncedWatchPartyUrl != data['originalUrl']) {
              setState(() {
                _syncedWatchPartyUrl = data['originalUrl'];
                _syncedDirectUrl = data['directUrl'];
              });
            }
          } else {
            setState(() {
              _syncedWatchPartyUrl = null;
              _syncedDirectUrl = null;
            });
          }
        } else {
          setState(() {
            _syncedWatchPartyUrl = null;
            _syncedDirectUrl = null;
          });
        }
      });

    }

    void _startWatchParty() async {
      String url = _watchPartyLinkController.text.trim();
      if (url.isNotEmpty && (url.contains('youtube.com') || url.contains('youtu.be'))) {

        // Box band karo aur loader dikhao
        setState(() {
          _showWatchPartyInput = false;
          _isExtractingLink = true;
        });

        try {
          var yt = YoutubeExplode();
          var video = await yt.videos.get(url);
          var manifest = await yt.videos.streamsClient.getManifest(video.id);
          var streamInfo = manifest.muxed.withHighestBitrate();
          String directUrl = streamInfo.url.toString();
          yt.close();

          await FirebaseFirestore.instance
              .collection('chat_rooms')
              .doc(chatRoomId)
              .collection('watch_party')
              .doc('sync')
              .set({
            'isActive': true,
            'originalUrl': url,
            'directUrl': directUrl,
            'isPlaying': true,
            'position': 0,
            'updatedBy': _auth.currentUser!.uid,
            'timestamp': FieldValue.serverTimestamp(),
          });

          setState(() => _isExtractingLink = false);
          _watchPartyLinkController.clear();

        } catch (e) {
          setState(() => _isExtractingLink = false);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Extraction Failed: $e")));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Only valid YouTube links allowed")));
      }
    }
  
    void _scrollListener() {
      if (_scrollController.offset >= _scrollController.position.maxScrollExtent &&
          !_scrollController.position.outOfRange) {
        setState(() {
          _messageLimit += 20;
          _updateMessagesStream();
        });
      }
    }
  
    void _updateMessagesStream() {
      _messagesStream = _chatService.getMessages(widget.receiverUserID, _auth.currentUser!.uid, _messageLimit);
    }
  
    @override
    void dispose() {
      ChatState.currentActiveChatId = null;
      _messageController.dispose();
      _scrollController.dispose();
      _watchPartyLinkController.dispose();
      _audioPlayer.dispose();
      _focusNode.dispose();
      _audioRecorder.dispose();
      _recordTimer?.cancel();
      _watchPartySub?.cancel();
      super.dispose();
    }
  
    void sendMessage() async {
      String message  = _messageController.text.trim();
      if (message.isNotEmpty) {
        await _audioPlayer.play(AssetSource('sounds/send.mp3'));
        _messageController.clear();
        await _chatService.sendMessage(widget.receiverUserID, message);
      }
    }
  
    void pickAndSendMedia() async {
      final ImagePicker picker = ImagePicker();
      XFile? pickedFile = await picker.pickMedia(imageQuality: 70);
  
      if (pickedFile != null) {
        File file = File(pickedFile.path);
        String ext = file.path.split('.').last.toLowerCase();
        String type = 'unknown';
  
        if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'].contains(ext)) {
          type = 'image';
        } else if (['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext)) {
          type = 'video';
        }
  
        if (type == 'unknown' && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Format not supported.")));
          return;
        }
  
        setState(() => _isUploading = true);
        await _chatService.sendMediaMessage(widget.receiverUserID, type, file);
        setState(() => _isUploading = false);
      }
    }
  
    void pickAndSendDocument() async {
      FilePickerResult? result = await FilePicker.pickFiles(type: FileType.any);
      if (result != null && result.files.single.path != null) {
        File file = File(result.files.single.path!);
        setState(() => _isUploading = true);
        await _chatService.sendMediaMessage(widget.receiverUserID, 'document', file);
        setState(() => _isUploading = false);
      }
    }
  
    void startRecording() async {
      try {
        if (await _audioRecorder.hasPermission()) {
          Directory tempDir = await getTemporaryDirectory();
          String path = '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
          await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
  
          setState(() {
            _isRecording = true;
            _recordDuration = 0;
          });
  
          _recordTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
            setState(() {
              _recordDuration++;
            });
          });
        } else {
          if(!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Microphone permission denied")));
        }
      } catch (e) {
        debugPrint("Audio Record Start Error: $e");
      }
    }
  
    void _stopAndSendRecording() async {
      _recordTimer?.cancel();
      try {
        String? path = await _audioRecorder.stop();
        setState(() => _isRecording = false);
  
        if (path != null) {
          File audioFile = File(path);
          setState(() => _isUploading = true);
          await _chatService.sendMediaMessage(widget.receiverUserID, 'audio', audioFile);
          setState(() => _isUploading = false);
        }
      } catch (e) {
        debugPrint("Audio Record Stop Error: $e");
      }
    }
  
    void _cancelRecording() async {
      _recordTimer?.cancel();
      try {
        String? path = await _audioRecorder.stop();
        if (path != null) {
          File file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        }
      } catch (e) {
        debugPrint("Audio Cancel Error: $e");
      }
      setState(() {
        _isRecording = false;
        _recordDuration = 0;
      });
    }
  
    String _formatDuration(int seconds) {
      int minutes = seconds ~/ 60;
      int remainingSeconds = seconds % 60;
      return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
    }
  
    void toggleEmojiKeyboard() {
      if (_showEmoji) {
        _focusNode.requestFocus();
        setState(() => _showEmoji = false);
      } else {
        _focusNode.unfocus();
        setState(() => _showEmoji = true);
      }
    }
  
    // VALIDATION: Check if SINGLE message can be edited
    bool _canEditSelection() {
      if (_selectedMessages.length != 1) return false;
  
      DocumentSnapshot doc = _selectedMessages.first;
      if (!doc.exists) return false;
      Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
  
      bool isCurrentUser = data['senderId'] == _auth.currentUser!.uid;
      bool isDeleted = data['isDeleted'] ?? false;
      String type = data['messageType'] ?? 'text';
  
      if (!isCurrentUser || isDeleted || type != 'text') return false;
  
      Timestamp? timestamp = data['timestamp'] as Timestamp?;
      if (timestamp == null) return false;
  
      return DateTime.now().difference(timestamp.toDate()).inSeconds < 120;
    }
  
    // VALIDATION: Check if ALL selected messages can be deleted for everyone
    bool _canDeleteForEveryone() {
      for (var doc in _selectedMessages) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        bool isCurrentUser = data['senderId'] == _auth.currentUser!.uid;
        bool isDeleted = data['isDeleted'] ?? false;
        if (!isCurrentUser || isDeleted) return false; // Agar ek bhi dusre ka hai toh allow mat karo
      }
      return true;
    }
  
    void _showDeleteDialog() {
      bool canDeleteEveryone = _canDeleteForEveryone();
  
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text("Delete ${_selectedMessages.length} message(s)?"),
          actions: [
            TextButton(
              onPressed: () {
                // Delete For Me (Loop on all selected)
                for (var doc in _selectedMessages) {
                  _chatService.deleteMessageForMe(chatRoomId, doc.id, _auth.currentUser!.uid);
                }
                Navigator.pop(context);
                setState(() => _selectedMessages.clear());
              },
              child: const Text("Delete for me"),
            ),
            if (canDeleteEveryone)
              TextButton(
                onPressed: () {
                  // Delete For Everyone (Loop on all selected)
                  for (var doc in _selectedMessages) {
                    _chatService.deleteMessageForEveryone(chatRoomId, doc.id);
                  }
                  Navigator.pop(context);
                  setState(() => _selectedMessages.clear());
                },
                child: const Text("Delete for everyone"),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
          ],
        ),
      );
    }
  
    void _showEditDialog() {
      if (_selectedMessages.length != 1) return;
  
      DocumentSnapshot doc = _selectedMessages.first;
      Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
      TextEditingController editController = TextEditingController(text: data['message']);
  
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Edit Message"),
          content: TextField(
            controller: editController,
            autofocus: true,
            decoration: const InputDecoration(hintText: "Enter text..."),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                String updatedText = editController.text.trim();
                if (updatedText.isNotEmpty) {
                  _chatService.editMessage(chatRoomId, doc.id, updatedText);
                }
                Navigator.pop(context);
                setState(() => _selectedMessages.clear());
              },
              child: const Text("Save"),
            ),
          ],
        ),
      );
    }
  
    PreferredSizeWidget _buildAppBar() {
      if (_selectedMessages.isNotEmpty) {
        bool allowEdit = _canEditSelection();
  
        return AppBar(
          backgroundColor: Colors.blueGrey.shade800,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => setState(() => _selectedMessages.clear()),
          ),
          title: Text("${_selectedMessages.length} selected", style: const TextStyle(color: Colors.white)),
          actions: [
            if (allowEdit)
              IconButton(
                icon: const Icon(Icons.edit, color: Colors.white),
                onPressed: _showEditDialog,
              ),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.white),
              onPressed: _showDeleteDialog,
            ),
          ],
        );
      }
  
      return AppBar(
        backgroundColor: Colors.lightBlue,
        elevation: 0,
        leadingWidth: 70,
        leading: InkWell(
          onTap: () => Navigator.pop(context),
          child: Row(
            children: [
              const SizedBox(width: 5),
              const Icon(Icons.arrow_back, color: Colors.white, size: 24),
              const SizedBox(width: 5),
              CircleAvatar(
                radius: 18,
                backgroundColor: Colors.lightBlue.shade100,
                backgroundImage: widget.profilePic.isNotEmpty ? NetworkImage(widget.profilePic) : null,
                child: widget.profilePic.isEmpty ? const Icon(Icons.person, color: Colors.white, size: 20) : null,
              ),
            ],
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.receiverUserName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance.collection('users').doc(widget.receiverUserID).snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || !snapshot.data!.exists) return const Text("offline", style: TextStyle(color: Colors.white70, fontSize: 12));
                var data = snapshot.data!.data() as Map<String, dynamic>;
                if (data['isOnline'] == true) return const Text("online", style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold));
                Timestamp? lastSeen = data['lastSeen'] as Timestamp?;
                if (lastSeen != null) {
                  DateTime dt = lastSeen.toDate();
                  return Text("last seen at ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}", style: const TextStyle(color: Colors.white70, fontSize: 12));
                }
                return const Text("offline", style: TextStyle(color: Colors.white70, fontSize: 12));
              },
            ),
          ],
        ),
      );
    }

    Widget _buildWatchPartyInputBox() {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2))],
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _watchPartyLinkController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: "Paste YouTube link here...",
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.cancel, color: Colors.grey),
              onPressed: () {
                setState(() {
                  _showWatchPartyInput = false;
                  _watchPartyLinkController.clear();
                });
              },
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              onPressed: _startWatchParty,
              child: const Text("Play", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }

    @override
    Widget build(BuildContext context) {
      return PopScope(
        canPop: !_showEmoji && _selectedMessages.isEmpty,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_showEmoji) {
            setState(() => _showEmoji = false);
          } else if (_selectedMessages.isNotEmpty) {
            setState(() => _selectedMessages.clear());
          }
        },
        child: Scaffold(
          backgroundColor: Colors.white,
          appBar: _buildAppBar(),
          body: SafeArea(
            child: Column(
              children: [
                if (_isExtractingLink == true)
                  Container(
                    width: double.infinity,
                    color: Colors.black87,
                    padding: const EdgeInsets.all(12),
                    child: const Center(
                      child: Text("Extracting video...", style: TextStyle(color: Colors.white)),
                    ),
                  ),

                if (_showWatchPartyInput)
                  _buildWatchPartyInputBox(),

                // 2. THE WATCH PARTY PLAYER
                if (_syncedWatchPartyUrl != null && _syncedDirectUrl != null)
                  SyncStreamPlayerWidget(
                    originalYoutubeUrl: _syncedWatchPartyUrl!,
                    directUrl: _syncedDirectUrl!, // NAYA
                    chatRoomId: chatRoomId,
                    currentUserId: _auth.currentUser!.uid,
                  ),

                Expanded(child: _buildMessageList()),
                _isRecording ? _buildRecordingUI() : _buildMessageInput(),
                Offstage(
                  offstage: !_showEmoji,
                  child: SizedBox(
                    height: 250,
                    child: EmojiPicker(
                      textEditingController: _messageController,
                      onEmojiSelected: (category, emoji) {
                        setState(() => _isTyping = true);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
  
    Widget _buildMessageList() {
      return StreamBuilder<QuerySnapshot>(
        stream: _messagesStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('Error loading messages'));
  
          if (snapshot.hasData) {
            _cachedMessages = snapshot.data!.docs;
          }
  
          if (_cachedMessages.isEmpty && snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Colors.lightBlue));
          }
  
          return ListView.builder(
            reverse: true,
            controller: _scrollController,
            itemCount: _cachedMessages.length,
            itemBuilder: (context, index) {
              return _buildMessageItem(_cachedMessages[index]);
            },
          );
        },
      );
    }
  
    Widget _buildMessageItem(DocumentSnapshot document) {
      Map<String, dynamic> data = document.data() as Map<String, dynamic>;
      bool isCurrentUser = data['senderId'] == _auth.currentUser!.uid;
      String status = data['status'] ?? 'sent';
      String messageType = data['messageType'] ?? 'text';
      String mediaUrl = data['mediaUrl'] ?? '';
      bool isDeleted = data['isDeleted'] ?? false;
      bool isEdited = data['isEdited'] ?? false;
  
      List<dynamic> deletedBy = data['deletedBy'] ?? [];
      if (deletedBy.contains(_auth.currentUser!.uid)) {
        return const SizedBox.shrink();
      }
  
      if (!isCurrentUser && status != 'read') {
        Future.microtask(() async {
          _chatService.updateMessageStatus(chatRoomId, document.id, 'read');
          Timestamp? msgTimestamp = data['timestamp'] as Timestamp?;
          if (msgTimestamp != null && _screenOpenedAt != null && msgTimestamp.toDate().isAfter(_screenOpenedAt!)) {
            try { await _audioPlayer.play(AssetSource('sounds/receive.mp3')); } catch (_) {}
          }
        });
      }
  
      var alignment = isCurrentUser ? Alignment.centerRight : Alignment.centerLeft;
  
      // CHECK IF THIS MESSAGE IS IN SELECTED ARRAY
      bool isSelected = _selectedMessages.any((msg) => msg.id == document.id);
  
      var bubbleColor = isSelected
          ? Colors.lightBlue.shade100
          : (isCurrentUser ? Colors.lightBlue : Colors.grey.shade200);
  
      Widget messageContent() {
        if (isDeleted) {
          return Text(
              data['message'],
              style: const TextStyle(color: Colors.black38, fontStyle: FontStyle.italic, fontSize: 15)
          );
        }
        if (messageType == 'image') {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(mediaUrl, width: 250, fit: BoxFit.cover, errorBuilder: (c, e, s) => Container(width: 250, height: 200, color: Colors.grey.shade300, child: const Icon(Icons.broken_image, size: 40))),
          );
        } else if (messageType == 'video') {
          return ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: 250, height: 250, child: VideoPlayerWidget(videoUrl: mediaUrl)));
        } else if (messageType == 'audio') {
          return VoiceNotePlayerWidget(audioUrl: mediaUrl);
        } else if (messageType == 'document') {
          return InkWell(
            onTap: () async {
              // Disable document opening if selection mode is active
              if (_selectedMessages.isNotEmpty) return;
  
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Downloading and opening document...")));
              try {
                var file = await DefaultCacheManager().getSingleFile(mediaUrl);
                final result = await OpenFilex.open(file.path);
                if (result.type != ResultType.done && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Cannot open file: ${result.message}")));
                }
              } catch (e) {
                debugPrint("Error opening doc: $e");
              }
            },
            child: Container(
              width: 200, padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  const Icon(Icons.insert_drive_file, color: Colors.black54, size: 36),
                  const SizedBox(width: 8),
                  Expanded(child: Text("Document File", style: TextStyle(color: isCurrentUser ? Colors.white : Colors.black87))),
                  const Icon(Icons.download, color: Colors.black54)
                ],
              ),
            ),
          );
        }
        return Text(data['message'], style: TextStyle(color: isCurrentUser ? Colors.white : Colors.black87, fontSize: 16));
      }
  
      Widget getTickIcon() {
        if (!isCurrentUser || isDeleted) return const SizedBox.shrink();
        if (status == 'read') return const Icon(Icons.done_all, size: 16, color: Colors.redAccent);
        if (status == 'delivered') return const Icon(Icons.done_all, size: 16, color: Colors.white70);
        return const Icon(Icons.check, size: 16, color: Colors.white70);
      }
  
      return GestureDetector(
        onLongPress: () {
          if (!isDeleted) {
            setState(() {
              if (!isSelected) _selectedMessages.add(document);
            });
          }
        },
        onTap: () {
          // MULTI-SELECTION TAP LOGIC
          if (_selectedMessages.isNotEmpty) {
            setState(() {
              if (isSelected) {
                _selectedMessages.removeWhere((msg) => msg.id == document.id);
              } else {
                if (!isDeleted) _selectedMessages.add(document);
              }
            });
          } else {
            // If not selecting, just close emoji keyboard on tap
            if (_showEmoji) {
              setState(() => _showEmoji = false);
            }
          }
        },
        child: Container(
          alignment: alignment,
          color: isSelected ? Colors.lightBlue.withValues(alpha: 0.08) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Container(
            padding: const EdgeInsets.all(12),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(topLeft: const Radius.circular(12), topRight: const Radius.circular(12), bottomLeft: isCurrentUser ? const Radius.circular(12) : const Radius.circular(0), bottomRight: isCurrentUser ? const Radius.circular(0) : const Radius.circular(12)),
            ),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.end, alignment: WrapAlignment.end,
              children: [
                messageContent(),
                const SizedBox(width: 5),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isEdited && !isDeleted)
                      Text(
                        "edited ",
                        style: TextStyle(color: isCurrentUser ? Colors.white60 : Colors.black38, fontSize: 10, fontStyle: FontStyle.italic),
                      ),
                    Text(
                      data['timestamp'] != null ? "${(data['timestamp'] as Timestamp).toDate().hour.toString().padLeft(2,'0')}:${(data['timestamp'] as Timestamp).toDate().minute.toString().padLeft(2,'0')}" : "",
                      style: TextStyle(color: isCurrentUser ? Colors.white70 : Colors.black45, fontSize: 11),
                    ),
                    const SizedBox(width: 3),
                    getTickIcon(),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
  
    Widget _buildRecordingUI() {
      return Container(
        margin: const EdgeInsets.all(8.0),
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        decoration: BoxDecoration(
          color: const Color(0xFF1B202D),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.play_arrow, color: Colors.grey, size: 28),
                const SizedBox(width: 12),
                const Icon(Icons.circle, color: Colors.lightBlueAccent, size: 12),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 24,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: List.generate(25, (index) {
                        double height = 8.0 + (index % 4) * 4.0;
                        if (index % 3 == 0) height += 6.0;
                        return Container(
                          width: 3,
                          height: height,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade600,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        );
                      }),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _formatDuration(_recordDuration),
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 28),
                  onPressed: _cancelRecording,
                ),
                const Icon(Icons.mic, color: Colors.redAccent, size: 36),
                CircleAvatar(
                  radius: 24,
                  backgroundColor: const Color(0xFF25D366),
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.black, size: 24),
                    onPressed: _stopAndSendRecording,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }
  
    Widget _buildMessageInput() {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(24)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: Icon(_showEmoji ? Icons.keyboard : Icons.emoji_emotions_outlined, color: Colors.grey),
                      onPressed: toggleEmojiKeyboard,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        focusNode: _focusNode,
                        minLines: 1, maxLines: 6,
                        keyboardType: TextInputType.multiline, textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(hintText: 'Message', hintStyle: TextStyle(fontSize: 16), border: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 12)),
                      ),
                    ),
                    if (!_isTyping) ...[
                      IconButton(
                        icon: const Icon(Icons.smart_display_rounded, color: Colors.redAccent),
                        onPressed: () => setState(() => _showWatchPartyInput = !_showWatchPartyInput),
                      ),
                      IconButton(icon: const Icon(Icons.attach_file, color: Colors.grey), onPressed: pickAndSendDocument),
                      IconButton(icon: const Icon(Icons.camera_alt, color: Colors.grey), onPressed: pickAndSendMedia),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _isUploading
                ? const Padding(padding: EdgeInsets.all(12.0), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
                : CircleAvatar(
              radius: 24,
              backgroundColor: Colors.lightBlueAccent,
              child: IconButton(
                icon: Icon(_isTyping ? Icons.send : Icons.mic, color: Colors.white, size: 24),
                onPressed: () {
                  if (_isTyping) {
                    sendMessage();
                  } else {
                    startRecording();
                  }
                },
              ),
            ),
          ],
        ),
      );
    }
  }
  
  class VideoPlayerWidget extends StatefulWidget {
    final String videoUrl;
  
    const VideoPlayerWidget({super.key, required this.videoUrl});
  
    @override
    State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
  }
  
  class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
    late VideoPlayerController _controller;
    bool _isInitialized = false;
    bool _hasError = false;
  
    @override
    void initState() {
      super.initState();
      _initializeAndCacheVideo();
    }
  
    Future<void> _initializeAndCacheVideo() async {
      try {
        FileInfo? fileInfo = await DefaultCacheManager().getFileFromCache(widget.videoUrl);
        File videoFile;
  
        if (fileInfo != null) {
          videoFile = fileInfo.file;
        } else {
          videoFile = await DefaultCacheManager().getSingleFile(widget.videoUrl);
        }
  
        _controller = VideoPlayerController.file(videoFile);
        await _controller.initialize();
  
        if (mounted) {
          setState(() {
            _isInitialized = true;
          });
        }
      } catch (e) {
        debugPrint("Error loading/caching video: $e");
        if (mounted) {
          setState(() {
            _hasError = true;
          });
        }
      }
    }
  
    @override
    void dispose() {
      if (_isInitialized) {
        _controller.dispose();
      }
      super.dispose();
    }
  
    @override
    Widget build(BuildContext context) {
  
      if (_hasError) {
        return Container(
          color: Colors.black12,
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
                SizedBox(height: 8),
                Text("Failed to load video", style: TextStyle(color: Colors.black54, fontSize: 12)),
              ],
            ),
          ),
        );
      }
  
      return _isInitialized
          ? Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: _controller.value.aspectRatio,
            child: VideoPlayer(_controller),
          ),
          IconButton(
            icon: Icon(
              _controller.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
              color: Colors.white.withValues(alpha: 0.8),
              size: 50,
            ),
            onPressed: () {
              setState(() {
                _controller.value.isPlaying ? _controller.pause() : _controller.play();
              });
            },
          ),
        ],
      )
          : Container(
        color: Colors.black87,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
  }
  
  class VoiceNotePlayerWidget extends StatefulWidget {
    final String audioUrl;
    const VoiceNotePlayerWidget({super.key, required this.audioUrl});
  
    @override
    State<VoiceNotePlayerWidget> createState() => _VoiceNotePlayerWidgetState();
  }
  
  class _VoiceNotePlayerWidgetState extends State<VoiceNotePlayerWidget> {
    final AudioPlayer _player = AudioPlayer();
    bool isPlaying = false;
    Duration currentPosition = Duration.zero;
    Duration totalDuration = Duration.zero;
  
    // NAYA: Stream subscriptions ko track karne ke liye
    StreamSubscription? _durationSub;
    StreamSubscription? _positionSub;
    StreamSubscription? _stateSub;
  
    @override
    void initState() {
      super.initState();
      _setupAudioPlayer();
    }
  
    // NAYA LOGIC: Safe Async Initialization
    Future<void> _setupAudioPlayer() async {
      try {
        // Pehle listeners attach karo
        _durationSub = _player.onDurationChanged.listen((duration) {
          if (mounted) setState(() => totalDuration = duration);
        });
  
        _positionSub = _player.onPositionChanged.listen((position) {
          if (mounted) setState(() => currentPosition = position);
        });
  
        _stateSub = _player.onPlayerStateChanged.listen((state) {
          if (mounted) setState(() => isPlaying = state == PlayerState.playing);
        });
  
        // Phir source set karo (Try-Catch ke andar taaki URL fail hone par app crash na ho)
        await _player.setSourceUrl(widget.audioUrl);
  
      } catch (e) {
        debugPrint("AudioPlayer Error: URL load fail ho gaya ya widget dispose ho gaya. Details: $e");
      }
    }
  
    @override
    void dispose() {
      // CRITICAL FIX: Dispose hone se pehle saare streams aur player ko strictly stop aur clear karna
      _durationSub?.cancel();
      _positionSub?.cancel();
      _stateSub?.cancel();
  
      // Player ko stop kiye bina dispose karne par native crash aata hai
      if (_player.state == PlayerState.playing) {
        _player.stop().then((_) => _player.dispose());
      } else {
        _player.dispose();
      }
  
      super.dispose();
    }
  
    @override
    Widget build(BuildContext context) {
      return Container(
        width: 200,
        padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 1),
        child: Row(
          children: [
            IconButton(
              icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: Colors.white, size: 36),
              onPressed: () async {
                try {
                  isPlaying ? await _player.pause() : await _player.play(UrlSource(widget.audioUrl));
                } catch (e) {
                  debugPrint("Play/Pause Error: $e");
                }
              },
            ),
            Expanded(
              child: Slider(
                activeColor: Colors.white,
                inactiveColor: Colors.black26,
                min: 0,
                max: totalDuration.inSeconds.toDouble() > 0 ? totalDuration.inSeconds.toDouble() : 1,
                value: currentPosition.inSeconds.toDouble().clamp(0, totalDuration.inSeconds.toDouble() > 0 ? totalDuration.inSeconds.toDouble() : 1), // Clamp lagaya taaki out of bounds error na aaye
                onChanged: (value) async {
                  final position = Duration(seconds: value.toInt());
                  await _player.seek(position);
                },
              ),
            ),
          ],
        ),
      );
    }
  }

  class SyncStreamPlayerWidget extends StatefulWidget {
    final String originalYoutubeUrl;
    final String directUrl; // SENDER KA LINK
    final String chatRoomId;
    final String currentUserId;

    const SyncStreamPlayerWidget({
      super.key,
      required this.originalYoutubeUrl,
      required this.directUrl,
      required this.chatRoomId,
      required this.currentUserId,
    });

    @override
    State<SyncStreamPlayerWidget> createState() => _SyncStreamPlayerWidgetState();
  }

  class _SyncStreamPlayerWidgetState extends State<SyncStreamPlayerWidget> {
    VideoPlayerController? _controller;
    StreamSubscription<DocumentSnapshot>? _syncSub;

    bool _isExtracting = true;
    bool _showControls = true;
    Timer? _hideTimer;

    bool _hasError = false;
    String _errorMessage = "";

    @override
    void initState() {
      super.initState();
      _smartInitPlayer();
    }

    @override
    void didUpdateWidget(covariant SyncStreamPlayerWidget oldWidget) {
      super.didUpdateWidget(oldWidget);
      if (oldWidget.originalYoutubeUrl != widget.originalYoutubeUrl) {
        _resetAndExtractNewVideo();
      }
    }

    Future<void> _resetAndExtractNewVideo() async {
      setState(() {
        _isExtracting = true;
        _hasError = false;
        _errorMessage = "";
      });

      _syncSub?.cancel();
      _hideTimer?.cancel();
      if (_controller != null) {
        await _controller!.pause();
        await _controller!.dispose();
        _controller = null;
      }

      _smartInitPlayer();
    }

    Future<void> _smartInitPlayer() async {
      try {
        _controller = VideoPlayerController.networkUrl(Uri.parse(widget.directUrl));
        await _controller!.initialize();
        _finishInit();

      } catch (e) {
        debugPrint("Direct URL Failed (Likely IP Mismatch 403). Falling back to Local Extraction...");
        try {
          var yt = YoutubeExplode();
          var video = await yt.videos.get(widget.originalYoutubeUrl);
          var manifest = await yt.videos.streamsClient.getManifest(video.id);

          var streamInfo = manifest.muxed.withHighestBitrate();
          yt.close();

          _controller = VideoPlayerController.networkUrl(Uri.parse(streamInfo.url.toString()));
          await _controller!.initialize();
          _finishInit();

        } catch (fallbackError) {
          debugPrint("Fallback Extraction Error: $fallbackError");
          if (mounted) {
            setState(() {
              _hasError = true;
              _errorMessage = fallbackError.toString();
            });
          }
        }
      }
    }

    void _finishInit() {
      if (mounted) {
        setState(() => _isExtracting = false);
        _controller!.play();
        WakelockPlus.enable();
        _startHideTimer();
        _listenToFirestoreSync();
      }
    }

    void _listenToFirestoreSync() {
      _syncSub = FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(widget.chatRoomId)
          .collection('watch_party')
          .doc('sync')
          .snapshots()
          .listen((snapshot) {
        if (snapshot.exists && _controller != null && _controller!.value.isInitialized) {
          var data = snapshot.data() as Map<String, dynamic>;

          if (data['updatedBy'] != widget.currentUserId) {
            int remotePos = data['position'];
            bool remotePlay = data['isPlaying'];

            int localPos = _controller!.value.position.inMilliseconds;
            if ((remotePos - localPos).abs() > 2000) {
              _controller!.seekTo(Duration(milliseconds: remotePos));
            }

            if (remotePlay && !_controller!.value.isPlaying) {
              _controller!.play();
              WakelockPlus.enable();
            } else if (!remotePlay && _controller!.value.isPlaying) {
              _controller!.pause();
              WakelockPlus.disable();
            }
          }
        }
      });
    }

    void _updateFirestoreState(bool isPlaying, int positionMs) {
      FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(widget.chatRoomId)
          .collection('watch_party')
          .doc('sync')
          .update({
        'isPlaying': isPlaying,
        'position': positionMs,
        'updatedBy': widget.currentUserId,
        'timestamp': FieldValue.serverTimestamp(),
      });
    }

    void _togglePlayPause() {
      if (_controller == null) return;

      bool willPlay = !_controller!.value.isPlaying;
      if (willPlay) {
        _controller!.play();
        WakelockPlus.enable();
      } else {
        _controller!.pause();
        WakelockPlus.disable();
      }

      setState(() {});
      _updateFirestoreState(willPlay, _controller!.value.position.inMilliseconds);
      _startHideTimer();
    }

    void _toggleControls() {
      setState(() => _showControls = !_showControls);
      if (_showControls) _startHideTimer();
    }

    void _startHideTimer() {
      _hideTimer?.cancel();
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showControls = false);
      });
    }

    void _closeWatchParty() {
      FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(widget.chatRoomId)
          .collection('watch_party')
          .doc('sync')
          .update({'isActive': false});
    }

    String _formatDuration(Duration duration) {
      String twoDigits(int n) => n.toString().padLeft(2, "0");
      String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
      String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
      return duration.inHours > 0 ? "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds" : "$twoDigitMinutes:$twoDigitSeconds";
    }

    @override
    void dispose() {
      WakelockPlus.disable();
      _syncSub?.cancel();
      _hideTimer?.cancel();
      _controller?.dispose();
      super.dispose();
    }

    @override
    Widget build(BuildContext context) {
      if (_hasError) {
        return Container(
          height: 250,
          color: Colors.black,
          padding: const EdgeInsets.all(16),
          child: Center(
            child: SingleChildScrollView(
              child: Text(
                "Playback Error:\n$_errorMessage",
                style: const TextStyle(color: Colors.redAccent, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      }

      return Container(
        width: double.infinity,
        color: Colors.black,
        child: Stack(
          alignment: Alignment.center,
          children: [
            _isExtracting || _controller == null
                ? const Padding(padding: EdgeInsets.all(40.0), child: CircularProgressIndicator(color: Colors.redAccent))
                : GestureDetector(
              onTap: _toggleControls,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: VideoPlayer(_controller!),
              ),
            ),

            if (!_isExtracting && _controller != null && _showControls)
              Positioned.fill(
                child: GestureDetector(
                  onTap: _toggleControls,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.4),
                    child: Stack(
                      children: [
                        Center(
                          child: IconButton(
                            iconSize: 60,
                            icon: Icon(_controller!.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: Colors.white),
                            onPressed: _togglePlayPause,
                          ),
                        ),

                        Positioned(
                          top: 5, right: 5,
                          child: IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 28), onPressed: _closeWatchParty),
                        ),

                        Positioned(
                          bottom: 10, left: 10, right: 10,
                          child: Row(
                            children: [
                              ValueListenableBuilder(
                                valueListenable: _controller!,
                                builder: (context, VideoPlayerValue value, child) {
                                  return Text(_formatDuration(value.position), style: const TextStyle(color: Colors.white, fontSize: 12));
                                },
                              ),
                              const SizedBox(width: 8),

                              Expanded(
                                child: ValueListenableBuilder(
                                  valueListenable: _controller!,
                                  builder: (context, VideoPlayerValue value, child) {
                                    double currentVal = value.position.inMilliseconds.toDouble();
                                    double totalVal = value.duration.inMilliseconds.toDouble();
                                    if (totalVal <= 0) totalVal = 1;

                                    return SliderTheme(
                                      data: SliderTheme.of(context).copyWith(thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                                      child: Slider(
                                        activeColor: Colors.redAccent, inactiveColor: Colors.white30,
                                        min: 0, max: totalVal, value: currentVal.clamp(0, totalVal),
                                        onChanged: (v) {
                                          _controller!.seekTo(Duration(milliseconds: v.toInt()));
                                          _startHideTimer();
                                        },
                                        onChangeEnd: (v) {
                                          _updateFirestoreState(_controller!.value.isPlaying, v.toInt());
                                        },
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(_formatDuration(_controller!.value.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
                            ],
                          ),
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