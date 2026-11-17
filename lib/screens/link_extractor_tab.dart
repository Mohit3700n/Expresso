import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class LinkExtractorTab extends StatefulWidget {
  const LinkExtractorTab({super.key});

  @override
  State<LinkExtractorTab> createState() => _LinkExtractorTabState();
}

class _LinkExtractorTabState extends State<LinkExtractorTab> {
  final TextEditingController _urlController = TextEditingController();

  bool _isExtracting = false;
  String _extractedUrl = '';
  String _videoTitle = '';
  String _errorMessage = '';

  // CRITICAL: Apne PC ka Local IP address yahan dalo (e.g., 192.168.1.5)
  // Emulator ke liye '10.0.2.2' chalega agar server PC pe chal raha hai
  final String _localServerIp = '10.138.59.253:8000';

  Future<void> _extractLink() async {
    final inputUrl = _urlController.text.trim();
    if (inputUrl.isEmpty) {
      setState(() => _errorMessage = "Pehle koi valid link paste karo bhai!");
      return;
    }

    setState(() {
      _isExtracting = true;
      _errorMessage = '';
      _extractedUrl = '';
      _videoTitle = '';
    });

    try {
      // Tere FastAPI server ko hit karega jo localhost pe chal raha hai
      final uri = Uri.parse('http://$_localServerIp/extract?url=${Uri.encodeComponent(inputUrl)}');
      final response = await http.get(uri).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success') {
          setState(() {
            _extractedUrl = data['direct_url'] ?? '';
            _videoTitle = data['title'] ?? 'Unknown Title';
          });
        } else {
          setState(() => _errorMessage = "Extraction failed on server side.");
        }
      } else {
        setState(() => _errorMessage = "Server phek raha hai error: HTTP ${response.statusCode}");
      }
    } catch (e) {
      setState(() => _errorMessage = "PC server se connect nahi ho paya!\nCheck karo uvicorn chal raha hai ya nahi: $e");
    } finally {
      setState(() => _isExtracting = false);
    }
  }

  void _pasteFromClipboard() async {
    ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      _urlController.text = data.text!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header UI
                const Row(
                  children: [
                    Icon(Icons.link, color: Colors.blueAccent, size: 32),
                    SizedBox(width: 8),
                    Text(
                      "Universal Extractor",
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  "YT, Insta, FB ka link dalo aur local yt-dlp engine se direct video URL nikalo.",
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 24),

                // Text Input Box with built-in Paste Button
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    hintText: 'Paste video link here...',
                    prefixIcon: const Icon(Icons.insert_link),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.assignment, color: Colors.blueAccent),
                      onPressed: _pasteFromClipboard,
                      tooltip: "Paste from device",
                    ),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.blueAccent, width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Extract Button
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    onPressed: _isExtracting ? null : _extractLink,
                    child: _isExtracting
                        ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text("Extracting via Local PC...", style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    )
                        : const Text("EXTRACT RAW URL", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 20),

                // Error Box
                if (_errorMessage.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                    child: Text(_errorMessage, style: TextStyle(color: Colors.red.shade800, fontSize: 13)),
                  ),

                // Success Result View
                if (_extractedUrl.isNotEmpty) ...[
                  const Divider(height: 40),
                  const Text("Extracted Data:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey)),
                  const SizedBox(height: 10),

                  // Video Title Card
                  Text(
                    _videoTitle,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 16),

                  // Raw URL Display Box
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade300)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Direct Streamable Link (Expires soon):",
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blueGrey),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _extractedUrl,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.black87),
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Copy URL Button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: const BorderSide(color: Colors.blueAccent),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.copy, color: Colors.blueAccent),
                      label: const Text("Copy Raw Link to Clipboard", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _extractedUrl));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("✅ Raw URL Copied! Ready for VLC / IDM."), backgroundColor: Colors.green),
                        );
                      },
                    ),
                  ),
                ]
              ],
            ),
          ),
        ),
      ),
    );
  }
}