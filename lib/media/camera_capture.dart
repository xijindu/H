import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../chat/media_library_saver.dart';
import 'app_camera_view.dart';

class CameraCapture {
  const CameraCapture(this.file, {this.albumResult});

  final XFile file;
  final MediaLibrarySaveResult? albumResult;

  bool get albumWriteFailed =>
      albumResult != null && albumResult != MediaLibrarySaveResult.saved;
}

Future<CameraCapture?> captureComposerPhoto(
  BuildContext context, {
  required bool saveToAlbum,
}) async {
  if (!saveToAlbum) {
    final result = await Navigator.of(context).push<AppCameraResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            const AppCameraView(allowVideo: true, allowGallery: false),
      ),
    );
    final file = result?.file;
    return file == null ? null : CameraCapture(file);
  }

  final shot = await ImagePicker().pickImage(source: ImageSource.camera);
  if (shot == null) return null;
  if (!Platform.isIOS) return CameraCapture(shot);
  return CameraCapture(
    shot,
    albumResult: await MediaLibrarySaver.savePreparedFile(
      File(shot.path),
      isVideo: false,
    ),
  );
}
