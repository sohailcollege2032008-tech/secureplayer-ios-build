import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/announcement_model.dart';
import '../announcements_provider.dart';

class AnnouncementBannerList extends ConsumerWidget {
  const AnnouncementBannerList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(announcementsProvider);

    return state.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (announcements) {
        if (announcements.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Column(
            children: announcements
                .map((a) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: AnnouncementCard(announcement: a),
                    ))
                .toList(),
          ),
        );
      },
    );
  }
}

class AnnouncementCard extends StatefulWidget {
  const AnnouncementCard({super.key, required this.announcement, this.lectureTitle});

  final AnnouncementModel announcement;
  // Set when this card is a lecture-scoped update notice, so the notice
  // itself names the lecture instead of relying on the student to infer it
  // from which card it happens to be rendered above.
  final String? lectureTitle;

  @override
  State<AnnouncementCard> createState() => AnnouncementCardState();
}

class AnnouncementCardState extends State<AnnouncementCard> {
  bool _expanded = false;

  bool get _isExpandable {
    final body = widget.announcement.body;
    return body.length > 150 || body.contains('\n');
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFFFA726);
    const cardBg = Color(0xFF1A1A2E);
    final body = widget.announcement.body;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(10),
        border: const Border(
          left: BorderSide(color: accent, width: 3.5),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.campaign_rounded, color: Color(0xFFFFA726), size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.announcement.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (widget.lectureTitle != null) ...[
            const SizedBox(height: 4),
            Text(
              widget.lectureTitle!,
              style: const TextStyle(
                color: accent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 6),
          _expanded
              ? _buildRichText(body)
              : Text(
                  body,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
          if (_isExpandable) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                _expanded ? 'Show less ▴' : 'Show more ▾',
                style: const TextStyle(
                  color: Color(0xFFFFA726),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRichText(String text) {
    final regex = RegExp(
      r'\[([^\]]+)\]\((https?://[^\)]+)\)|(https?://\S+)',
    );
    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in regex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      final label = match.group(1);
      final url = match.group(2) ?? match.group(3)!;
      final displayText = label ?? url;

      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => launchUrl(
            Uri.parse(url),
            mode: LaunchMode.externalApplication,
          ),
          child: Text(
            displayText,
            style: const TextStyle(
              color: Colors.lightBlueAccent,
              fontSize: 13,
              height: 1.5,
              decoration: TextDecoration.underline,
              decorationColor: Colors.lightBlueAccent,
            ),
          ),
        ),
      ));

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          height: 1.5,
        ),
        children: spans,
      ),
    );
  }
}
