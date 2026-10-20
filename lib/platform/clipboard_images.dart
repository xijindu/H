import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../chat/outgoing_attachment.dart';

class ClipboardImageReadResult {
  const ClipboardImageReadResult({
    this.attachments = const [],
    this.availableImageCount = 0,
    this.failedImageCount = 0,
  });

  final List<OutgoingAttachment> attachments;
  final int availableImageCount;
  final int failedImageCount;
}

class ClipboardImageData {
  const ClipboardImageData({required this.data, required this.mimeType});

  final Uint8List data;
  final String mimeType;
}

/// Copies clipboard image payloads into owned temporary files for the composer.
///
/// Mithka's owned channel hands the composer every image item the platform can
/// expose.
class ClipboardImageService {
  const ClipboardImageService._();

  static Future<ClipboardImageReadResult> storeImages(
    List<ClipboardImageData> payloads, {
    required int limit,
  }) async {
    if (limit <= 0 || payloads.isEmpty) {
      return const ClipboardImageReadResult();
    }
    final directory = await getTemporaryDirectory();
    await directory.create(recursive: true);
    final selected = payloads.take(limit).toList(growable: false);
    final attachments = <OutgoingAttachment>[];
    var failures = 0;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    for (var index = 0; index < selected.length; index++) {
      final payload = selected[index];
      final extension = _extensionForMime(payload.mimeType);
      final path =
          '${directory.path}${Platform.pathSeparator}'
          'mithka-clipboard-$timestamp-$index.$extension';
      try {
        final file = File(path);
        await file.writeAsBytes(payload.data, flush: true);
        attachments.add(
          OutgoingAttachment(
            path: path,
            kind: extension == 'gif'
                ? OutgoingAttachmentKind.animation
                : OutgoingAttachmentKind.photo,
            fileName: Uri.file(path).pathSegments.last,
          ),
        );
      } on FileSystemException {
        failures++;
      }
    }

    final resolved = await resolveAttachmentListDimensions(attachments);
    return ClipboardImageReadResult(
      attachments: List.unmodifiable(resolved),
      availableImageCount: payloads.length,
      failedImageCount: failures,
    );
  }

  static String _extensionForMime(String mimeType) =>
      switch (mimeType.toLowerCase()) {
        'image/jpeg' || 'image/jpg' => 'jpg',
        'image/gif' => 'gif',
        'image/webp' => 'webp',
        'image/heic' => 'heic',
        'image/heif' => 'heif',
        _ => 'png',
      };
}
