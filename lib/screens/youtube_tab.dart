import 'package:flutter/material.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'video_player_screen.dart';

class YouTubeTab extends StatefulWidget {
  const YouTubeTab({super.key});

  @override
  State<YouTubeTab> createState() => _YouTubeTabState();
}

class _YouTubeTabState extends State<YouTubeTab> {
  final YoutubeExplode yt = YoutubeExplode();
  List<Video> _videos = [];
  bool _isLoading = true;
  String _errorMessage = '';

  final List<String> categories = ['Trending', 'Music', 'Gaming', 'Flutter', 'Podcasts', 'News'];
  int _selectedCategoryIndex = 0;

  @override
  void initState() {
    super.initState();
    _fetchVideos(categories[_selectedCategoryIndex]);
  }

  @override
  void dispose() {
    yt.close();
    super.dispose();
  }

  Future<void> _fetchVideos(String query) async {
    setState(() { _isLoading = true; _errorMessage = ''; });
    try {
      var searchResults = await yt.search.search('$query -live');
      List<Video> parsedVideos = [];
      var iterator = searchResults.iterator;
      while (true) {
        try { if (!iterator.moveNext()) break; parsedVideos.add(iterator.current); } catch (_) {}
      }
      if (mounted) setState(() { _videos = parsedVideos; if (_videos.isEmpty) _errorMessage = "No playable videos found."; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _errorMessage = 'Failed to load: $e'; _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            floating: true, backgroundColor: Colors.white, elevation: 0,
            title: const Row(children: [Icon(Icons.smart_display, color: Colors.red, size: 32), SizedBox(width: 8), Text("YouTube", style: TextStyle(color: Colors.black, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: -1))]),
            actions: [
              IconButton(icon: const Icon(Icons.cast, color: Colors.black), onPressed: () {}),
              IconButton(icon: const Icon(Icons.notifications_none, color: Colors.black), onPressed: () {}),
              IconButton(
                icon: const Icon(Icons.search, color: Colors.black),
                onPressed: () async {
                  final selectedVideo = await showSearch(context: context, delegate: VideoSearchDelegate());
                  // NAYA MAGIC: Push nahi, seedha Overlay call karo
                  if (selectedVideo != null) VideoPlayerScreen.play(context, selectedVideo);
                },
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 12.0), child: CircleAvatar(radius: 14, backgroundColor: Colors.grey, child: Icon(Icons.person, size: 18, color: Colors.white))),
            ],
          ),
          SliverToBoxAdapter(
            child: Container(
              color: Colors.white, height: 50,
              child: ListView.builder(
                scrollDirection: Axis.horizontal, physics: const BouncingScrollPhysics(), itemCount: categories.length,
                itemBuilder: (context, index) {
                  bool isSelected = _selectedCategoryIndex == index;
                  return GestureDetector(
                    onTap: () { setState(() => _selectedCategoryIndex = index); _fetchVideos(categories[index]); },
                    child: Padding(
                      padding: EdgeInsets.only(left: index == 0 ? 12.0 : 8.0, right: index == categories.length - 1 ? 12.0 : 0, top: 8.0, bottom: 8.0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(color: isSelected ? Colors.black : Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
                        alignment: Alignment.center,
                        child: Text(categories[index], style: TextStyle(color: isSelected ? Colors.white : Colors.black87, fontWeight: FontWeight.w500)),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (_isLoading) const SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: Colors.red)))
          else if (_errorMessage.isNotEmpty) SliverFillRemaining(child: Center(child: Text(_errorMessage, style: const TextStyle(color: Colors.red))))
          else SliverList(
              delegate: SliverChildBuilderDelegate(
                    (context, index) => YouTubeVideoCard(
                    video: _videos[index],
                    // OVERLAY CALL
                    onTap: () => VideoPlayerScreen.play(context, _videos[index])
                ),
                childCount: _videos.length,
              ),
            ),
        ],
      ),
    );
  }
}

class VideoSearchDelegate extends SearchDelegate<Video?> {
  final YoutubeExplode yt = YoutubeExplode();
  @override
  String get searchFieldLabel => 'Search YouTube...';
  @override
  List<Widget>? buildActions(BuildContext context) => [if (query.isNotEmpty) IconButton(icon: const Icon(Icons.clear), onPressed: () => query = '')];
  @override
  Widget? buildLeading(BuildContext context) => IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => close(context, null));
  @override
  Widget buildResults(BuildContext context) {
    if (query.trim().isEmpty) return const SizedBox();
    return FutureBuilder(
      future: yt.search.search('$query -live'),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: Colors.red));
        if (snapshot.data == null) return const Center(child: Text("No videos found."));
        List<Video> results = [];
        var iterator = snapshot.data!.iterator;
        while (true) { try { if (!iterator.moveNext()) break; results.add(iterator.current); } catch (_) {} }
        return ListView.builder(
          physics: const BouncingScrollPhysics(), itemCount: results.length,
          itemBuilder: (context, index) => YouTubeVideoCard(video: results[index], onTap: () => close(context, results[index])),
        );
      },
    );
  }
  @override
  Widget buildSuggestions(BuildContext context) => const Center(child: Text("Type to search"));
}

class YouTubeVideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onTap;
  const YouTubeVideoCard({super.key, required this.video, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            height: 220, width: double.infinity, color: Colors.grey.shade300,
            child: Image.network(video.thumbnails.highResUrl, fit: BoxFit.cover, errorBuilder: (c, e, s) => const Icon(Icons.broken_image, size: 50)),
          ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CircleAvatar(radius: 20, backgroundColor: Colors.blueGrey, child: Icon(Icons.person, color: Colors.white)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(video.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis),
                      Text(video.author, style: TextStyle(fontSize: 13, color: Colors.grey.shade700), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}