import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class VideoPlayerScreen extends StatefulWidget {
  final Video video;
  final VoidCallback onClose;
  final Function(Video) onPlayRelated;

  const VideoPlayerScreen({
    super.key,
    required this.video,
    required this.onClose,
    required this.onPlayRelated,
  });

  // ─── THE OVERLAY INJECTOR ───
  static OverlayEntry? _overlayEntry;

  static void play(BuildContext context, Video video) {
    _overlayEntry?.remove();
    _overlayEntry = OverlayEntry(
      builder: (context) => VideoPlayerScreen(
        video: video,
        onClose: () {
          _overlayEntry?.remove();
          _overlayEntry = null;
        },
        onPlayRelated: (newVideo) {
          play(context, newVideo);
        },
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
  }

  @override
  // NAYA: WidgetsBindingObserver add kiya
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> with WidgetsBindingObserver {
  final YoutubeExplode yt = YoutubeExplode();
  VideoPlayerController? _videoController;

  bool _isPlaying = false;
  bool _isLoadingStream = true;
  String _errorMessage = '';
  List<Video> _relatedVideos = [];
  bool _isLoadingRelated = true;
  StreamInfo? _selectedStream;
  final ValueNotifier<double> _progressNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<String> _statusNotifier = ValueNotifier<String>('');
  bool _showControls = false;
  Timer? _hideTimer;

  bool _isMinimized = false;

  @override
  void initState() {
    super.initState();
    // NAYA: Global Back Button Observer register karo
    WidgetsBinding.instance.addObserver(this);
    _initVideoStream();
    _fetchRelatedVideos();
  }

  @override
  void dispose() {
    // NAYA: Observer ko memory se hatao
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _hideTimer?.cancel();
    _videoController?.dispose();
    yt.close();
    super.dispose();
  }

  // NAYA: Ye engine-level par Hardware Back Button ko catch karta hai
  @override
  Future<bool> didPopRoute() async {
    if (!_isMinimized) {
      // Agar full screen hai, toh minimize karo aur app ko close hone se roko
      setState(() {
        _isMinimized = true;
      });
      return true;
    }
    // Agar minimize hai, toh system ko aage badhne do (normal back button behaviour)
    return false;
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isPlaying) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _startHideTimer();
  }

  void _seekBackward() {
    if (_videoController == null) return;
    final newPosition = _videoController!.value.position - const Duration(seconds: 10);
    _videoController!.seekTo(newPosition < Duration.zero ? Duration.zero : newPosition);
    setState(() => _showControls = true);
    _startHideTimer();
  }

  void _seekForward() {
    if (_videoController == null) return;
    final newPosition = _videoController!.value.position + const Duration(seconds: 10);
    final maxDuration = _videoController!.value.duration;
    _videoController!.seekTo(newPosition > maxDuration ? maxDuration : newPosition);
    setState(() => _showControls = true);
    _startHideTimer();
  }

  String _formatPlayerTime(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String minutes = twoDigits(duration.inMinutes.remainder(60));
    String seconds = twoDigits(duration.inSeconds.remainder(60));
    return duration.inHours > 0 ? "${duration.inHours}:$minutes:$seconds" : "$minutes:$seconds";
  }

  String _formatViews(int views) {
    if (views >= 1000000) return '${(views / 1000000).toStringAsFixed(1)}M';
    if (views >= 1000) return '${(views / 1000).toStringAsFixed(0)}K';
    return views.toString();
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return "Live";
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return duration.inHours > 0 ? "${duration.inHours}:$twoDigitMinutes:$twoDigitSeconds" : "$twoDigitMinutes:$twoDigitSeconds";
  }

  Future<void> _initVideoStream() async {
    try {
      var manifest = await yt.videos.streamsClient.getManifest(widget.video.id);
      var streamInfo = manifest.muxed.withHighestBitrate();
      _videoController = VideoPlayerController.networkUrl(streamInfo.url)
        ..initialize().then((_) {
          if (mounted) {
            setState(() => _isLoadingStream = false);
            _videoController!.play();
            _startHideTimer();
            WakelockPlus.enable();
          }
        });

      _videoController!.addListener(() {
        if (mounted) {
          bool isCurrentlyPlaying = _videoController!.value.isPlaying;
          if (isCurrentlyPlaying != _isPlaying) {
            setState(() => _isPlaying = isCurrentlyPlaying);
            _isPlaying ? WakelockPlus.enable() : WakelockPlus.disable();
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() { _isLoadingStream = false; _errorMessage = "Stream load fail: $e"; });
    }
  }

  Future<void> _fetchRelatedVideos() async {
    try {
      var related = await yt.videos.getRelatedVideos(widget.video);
      if (mounted) setState(() { _relatedVideos = related?.toList() ?? []; _isLoadingRelated = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoadingRelated = false);
    }
  }

  Future<void> _startDownload(StreamInfo stream) async {

   /* ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download not working right now', style: TextStyle(color: Colors.white),), backgroundColor: Colors.redAccent,));
    return;*/

    bool hasPerm = await Permission.storage.request().isGranted;
    if (!hasPerm) hasPerm = await Permission.videos.request().isGranted;
    final Directory publicDir = Directory('/storage/emulated/0/Download/Expresso_Videos');
    if (!await publicDir.exists()) await publicDir.create(recursive: true);

    final safeTitle = widget.video.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
    final outputPath = "${publicDir.path}/$safeTitle.mp4";
    final videoTemp = "${publicDir.path}/temp_vid.mp4";
    final audioTemp = "${publicDir.path}/temp_aud.m4a";

    _progressNotifier.value = 0.0;
    _statusNotifier.value = "Starting...";
    _showProgressDialog();

    try {
      if (stream is VideoOnlyStreamInfo) {
        _statusNotifier.value = "Fetching audio track...";
        var manifest = await yt.videos.streamsClient.getManifest(widget.video.id);
        var audioStream = manifest.audioOnly.withHighestBitrate();

        _statusNotifier.value = "Downloading High-Res Video...";
        await _downloadStreamWithProgress(stream, videoTemp, 0.0, 0.45);
        _statusNotifier.value = "Downloading High-Quality Audio...";
        await _downloadStreamWithProgress(audioStream, audioTemp, 0.45, 0.90);
        _statusNotifier.value = "Merging Video & Audio (Please Wait)...";
        _progressNotifier.value = 0.95;
        await _mergeAudioAndVideo(videoTemp, audioTemp, outputPath);
      } else {
        _statusNotifier.value = "Downloading Muxed Video...";
        await _downloadStreamWithProgress(stream, outputPath, 0.0, 1.0);
      }

      _progressNotifier.value = 1.0;
      _statusNotifier.value = "Completed!";
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Saved to Downloads/Expresso_Videos"), backgroundColor: Colors.green));
    } catch (e) {
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Download Error: $e"), backgroundColor: Colors.red));
    }
  }

  Future<void> _downloadStreamWithProgress(StreamInfo streamInfo, String filePath, double startProgress, double endProgress) async {
    var stream = yt.videos.streamsClient.get(streamInfo);
    var fileStream = File(filePath).openWrite();
    int downloaded = 0, total = streamInfo.size.totalBytes, lastUpdate = 0;
    await for (final data in stream) {
      fileStream.add(data);
      downloaded += data.length;
      if (downloaded - lastUpdate > 256 * 1024 || downloaded == total) {
        lastUpdate = downloaded;
        if (total > 0 && mounted) _progressNotifier.value = startProgress + ((downloaded / total) * (endProgress - startProgress));
        await Future.delayed(Duration.zero);
      }
    }
    await fileStream.flush();
    await fileStream.close();
  }

  void _showProgressDialog() {
    showDialog(
      context: context, barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Downloading", style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double>(valueListenable: _progressNotifier, builder: (c, progress, _) => Column(children: [LinearProgressIndicator(value: progress, color: Colors.red, minHeight: 8), const SizedBox(height: 16), Text("${(progress * 100).toStringAsFixed(1)}%", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: Colors.red))])),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(valueListenable: _statusNotifier, builder: (c, status, _) => Text(status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 13))),
          ],
        ),
      ),
    );
  }

  Future<void> _mergeAudioAndVideo(String vPath, String aPath, String outPath) async {
    await FFmpegKit.execute('-i "$vPath" -i "$aPath" -c copy "$outPath"').then((session) async {
      if (ReturnCode.isSuccess(await session.getReturnCode())) {
        File(vPath).delete(); File(aPath).delete();
      } else throw Exception("FFmpeg Merging Failed");
    });
  }

  Future<void> _showDownloadBottomSheet(BuildContext context) async {
    setState(() => _selectedStream = null);
    showModalBottomSheet(context: context, isScrollControlled: true, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (context) => const SizedBox(height: 200, child: Center(child: CircularProgressIndicator(color: Colors.red))));
    try {
      var manifest = await yt.videos.streamsClient.getManifest(widget.video.id);
      var audioStreams = manifest.audioOnly.where((s) => s.container.name == 'mp4').toList();
      var muxedStreams = manifest.muxed.toList();
      var videoOnlyStreams = manifest.videoOnly.where((s) => s.container.name == 'mp4').toList();
      List<StreamInfo> allVideoStreams = [...muxedStreams];
      for (var videoOnly in videoOnlyStreams) {
        if (!allVideoStreams.any((s) => ((s is MuxedStreamInfo) ? s.videoResolution : (s as VideoOnlyStreamInfo).videoResolution) == videoOnly.videoResolution)) allVideoStreams.add(videoOnly);
      }
      allVideoStreams.sort((a, b) => ((b is MuxedStreamInfo) ? b.videoResolution : (b as VideoOnlyStreamInfo).videoResolution).compareTo(((a is MuxedStreamInfo) ? a.videoResolution : (a as VideoOnlyStreamInfo).videoResolution)));
      if (mounted) Navigator.pop(context);
      if (mounted) {
        showModalBottomSheet(
          context: context, isScrollControlled: true, backgroundColor: Colors.white, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          builder: (context) => StatefulBuilder(
            builder: (context, setSheetState) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(widget.video.thumbnails.lowResUrl, width: 80, height: 45, fit: BoxFit.cover)), const SizedBox(width: 12), Expanded(child: Text(widget.video.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)))]),
                    const Divider(height: 30),
                    const Row(children: [Icon(Icons.play_circle_fill, color: Colors.red), SizedBox(width: 8), Text("Video", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))]),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10, runSpacing: 10,
                      children: allVideoStreams.map((stream) {
                        final res = (stream is MuxedStreamInfo) ? stream.videoResolution : (stream as VideoOnlyStreamInfo).videoResolution;
                        return _buildRadioOption(title: res.toString(), subtitle: "${stream.size.totalMegaBytes.toStringAsFixed(2)}MB", format: "MP4", isSelected: _selectedStream == stream, onTap: () => setSheetState(() => _selectedStream = stream));
                      }).toList(),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(width: double.infinity, height: 50, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25))), onPressed: _selectedStream == null ? null : () { Navigator.pop(context); _startDownload(_selectedStream!); }, child: const Text("DOWNLOAD", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)))),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }

  Widget _buildRadioOption({required String title, required String subtitle, required String format, required bool isSelected, required VoidCallback onTap}) {
    double width = (MediaQuery.of(context).size.width - 42) / 2;
    return GestureDetector(
      onTap: onTap,
      child: Container(width: width, padding: const EdgeInsets.symmetric(vertical: 8), color: Colors.transparent, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: isSelected ? Colors.red : Colors.grey, size: 22), const SizedBox(width: 8), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: isSelected ? Colors.red : Colors.black)), const SizedBox(width: 4), Text(format, style: const TextStyle(fontSize: 12, color: Colors.grey))]), Text(subtitle, style: const TextStyle(fontSize: 13, color: Colors.grey))])])),
    );
  }

  Widget _buildActionChip(IconData icon, String label, {VoidCallback? onTap, required bool isDisabled}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: Opacity(opacity: isDisabled ? 0.4 : 1.0, child: InkWell(onTap: isDisabled ? null : onTap, borderRadius: BorderRadius.circular(20), child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(20)), child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 6), Text(label, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13))])))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      bottom: _isMinimized ? 60 + safeBottom : 0,
      left: 0,
      right: 0,
      height: _isMinimized ? 70 : size.height,
      child: Material(
        elevation: _isMinimized ? 10 : 0,
        child: _isMinimized ? _buildMiniPlayer() : _buildFullScreen(),
      ),
    );
  }

  Widget _buildMiniPlayer() {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity! < 0) setState(() => _isMinimized = false);
        if (details.primaryVelocity! > 0) widget.onClose();
      },
      onTap: () => setState(() => _isMinimized = false),
      child: Container(
        color: Colors.white,
        child: Column(
          children: [
            if (_videoController != null)
              ValueListenableBuilder(
                valueListenable: _videoController!,
                builder: (context, VideoPlayerValue value, child) {
                  double progress = value.duration.inMilliseconds == 0 ? 0 : value.position.inMilliseconds / value.duration.inMilliseconds;
                  return LinearProgressIndicator(value: progress, color: Colors.red, backgroundColor: Colors.transparent, minHeight: 2);
                },
              ),
            Expanded(
              child: Row(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: _videoController != null && _videoController!.value.isInitialized
                        ? VideoPlayer(_videoController!)
                        : Image.network(widget.video.thumbnails.lowResUrl, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(widget.video.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        Text(widget.video.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 11)),
                      ],
                    ),
                  ),
                  IconButton(icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow), onPressed: () => _isPlaying ? _videoController!.pause() : _videoController!.play()),
                  IconButton(icon: const Icon(Icons.close), onPressed: widget.onClose),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullScreen() {
    // NAYA: PopScope hata diya kyunki ye overlay me kaam nahi karta
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            GestureDetector(
              onVerticalDragEnd: (details) { if (details.primaryVelocity! > 0) setState(() => _isMinimized = true); },
              child: Container(
                color: Colors.black, padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    IconButton(icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white), onPressed: () => setState(() => _isMinimized = true)),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.settings, color: Colors.white), onPressed: () {}),
                  ],
                ),
              ),
            ),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                color: Colors.black,
                child: _isLoadingStream
                    ? Stack(fit: StackFit.expand, children: [Image.network(widget.video.thumbnails.highResUrl, fit: BoxFit.cover), const Center(child: CircularProgressIndicator(color: Colors.red))])
                    : _errorMessage.isNotEmpty ? Center(child: Text(_errorMessage, style: const TextStyle(color: Colors.white)))
                    : Stack(
                  fit: StackFit.expand,
                  children: [
                    VideoPlayer(_videoController!),
                    Row(children: [Expanded(child: GestureDetector(onDoubleTap: _seekBackward, onTap: _toggleControls, child: Container(color: Colors.transparent))), Expanded(child: GestureDetector(onDoubleTap: _seekForward, onTap: _toggleControls, child: Container(color: Colors.transparent)))]),
                    IgnorePointer(
                      ignoring: !_showControls,
                      child: AnimatedOpacity(
                        opacity: _showControls ? 1.0 : 0.0, duration: const Duration(milliseconds: 200),
                        child: Container(
                          color: Colors.black.withOpacity(0.5),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const SizedBox(height: 40),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  IconButton(icon: const Icon(Icons.replay_10, color: Colors.white, size: 40), onPressed: _seekBackward),
                                  GestureDetector(onTap: () { _isPlaying ? _videoController!.pause() : _videoController!.play(); _startHideTimer(); }, child: Container(decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black45), padding: const EdgeInsets.all(12), child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 45))),
                                  IconButton(icon: const Icon(Icons.forward_10, color: Colors.white, size: 40), onPressed: _seekForward),
                                ],
                              ),
                              ValueListenableBuilder(
                                valueListenable: _videoController!,
                                builder: (context, VideoPlayerValue value, child) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                                    child: Row(
                                      children: [
                                        Text(_formatPlayerTime(value.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
                                        const SizedBox(width: 10),
                                        Expanded(child: VideoProgressIndicator(_videoController!, allowScrubbing: true, colors: VideoProgressColors(playedColor: Colors.red, bufferedColor: Colors.white.withOpacity(0.5), backgroundColor: Colors.white.withOpacity(0.2)), padding: const EdgeInsets.symmetric(vertical: 8))),
                                        const SizedBox(width: 10),
                                        Text(_formatPlayerTime(value.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
                                        const SizedBox(width: 10),
                                        const Icon(Icons.fullscreen, color: Colors.white, size: 24),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    ValueListenableBuilder(
                      valueListenable: _videoController!,
                      builder: (context, VideoPlayerValue value, child) {
                        if (value.isBuffering) return const Center(child: CircularProgressIndicator(color: Colors.white));
                        return const SizedBox.shrink();
                      },
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.video.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), maxLines: 2, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 8),
                          Text("${_formatViews(widget.video.engagement.viewCount)} views", style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0),
                      child: Row(
                        children: [
                          const CircleAvatar(radius: 18, backgroundColor: Colors.grey, child: Icon(Icons.person, color: Colors.white)),
                          const SizedBox(width: 10),
                          Expanded(child: Text(widget.video.author, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ElevatedButton(onPressed: null, style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade300, disabledBackgroundColor: Colors.grey.shade200, disabledForegroundColor: Colors.grey.shade500, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), padding: const EdgeInsets.symmetric(horizontal: 16)), child: const Text("Subscribe")),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12.0), physics: const BouncingScrollPhysics(),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildActionChip(Icons.thumb_up_alt_outlined, "Like", isDisabled: true),
                          _buildActionChip(Icons.reply, "Share", isDisabled: false, onTap: () { SharePlus.instance.share(ShareParams(text: 'https://youtu.be/${widget.video.id}')); }),
                          _buildActionChip(Icons.copy, "Copy Raw URL", isDisabled: false, onTap: () async {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Extracting direct raw link..."), duration: Duration(seconds: 1)));
                            try {
                              var manifest = await yt.videos.streamsClient.getManifest(widget.video.id);
                              var directUrl = manifest.muxed.withHighestBitrate().url.toString();
                              await Clipboard.setData(ClipboardData(text: directUrl));
                              if (mounted) { ScaffoldMessenger.of(context).hideCurrentSnackBar(); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Raw Video URL Copied!"), backgroundColor: Colors.green)); }
                            } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to extract: $e"), backgroundColor: Colors.red)); }
                          }),
                          _buildActionChip(Icons.download, "Download", onTap: () => _showDownloadBottomSheet(context), isDisabled: true),
                          _buildActionChip(Icons.bookmark_border, "Save", isDisabled: true),
                        ],
                      ),
                    ),
                    const Divider(height: 30, thickness: 1),
                    if (_isLoadingRelated) const Center(child: CircularProgressIndicator(color: Colors.black))
                    else if (_relatedVideos.isEmpty) const Center(child: Text("No related videos found."))
                    else ListView.builder(
                        shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: _relatedVideos.length,
                        itemBuilder: (context, index) {
                          final relatedVid = _relatedVideos[index];
                          return InkWell(
                            onTap: () => widget.onPlayRelated(relatedVid),
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 12.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 160, height: 90, margin: const EdgeInsets.symmetric(horizontal: 12), color: Colors.grey.shade300,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.network(relatedVid.thumbnails.mediumResUrl, fit: BoxFit.cover, errorBuilder: (c, e, s) => const Icon(Icons.broken_image)),
                                        Positioned(bottom: 4, right: 4, child: Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), color: Colors.black87, child: Text(_formatDuration(relatedVid.duration), style: const TextStyle(color: Colors.white, fontSize: 10)))),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 12.0),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(relatedVid.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                                          const SizedBox(height: 4),
                                          Text(relatedVid.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
                                          Text("${_formatViews(relatedVid.engagement.viewCount)} views", style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}