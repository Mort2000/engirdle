import 'package:flutter/services.dart';

/// A user-picked document from the Android Storage Access Framework
/// (ACTION_OPEN_DOCUMENT): user-granted URI access only, no storage
/// permission (design §6.1).
class PickedDocument {
  const PickedDocument({
    required this.uri,
    required this.displayName,
    required this.mimeType,
    required this.bytes,
  });

  /// Content URI; readable only for this process unless the caller persists
  /// the grant (the importer reads the bytes immediately and never does).
  final Uri uri;

  /// System-provided display name and MIME hint; the import module still
  /// validates the real type (§7.2: DocumentSource 只携带受控 URI 及提示).
  final String? displayName;
  final String? mimeType;

  /// The document bytes, read before the grant lapses.
  final Uint8List bytes;
}

/// The SAF seam: pick one document and read its bytes. Production talks to
/// the Kotlin channel below; tests inject an in-memory implementation.
abstract class DocumentPicker {
  /// Null when the user cancels the system picker.
  Future<PickedDocument?> pickDocument();
}

class MethodChannelDocumentPicker implements DocumentPicker {
  const MethodChannelDocumentPicker();

  static const _channel = MethodChannel('com.engirdle.mobile/documents');

  @override
  Future<PickedDocument?> pickDocument() async {
    final picked = await _channel.invokeMapMethod<String, Object?>(
      'pickDocument',
    );
    if (picked == null) return null;
    final uri = Uri.parse(picked['uri']! as String);
    final bytes = await _channel.invokeMethod<Uint8List>('readBytes', {
      'uri': picked['uri'],
    });
    if (bytes == null) {
      throw PlatformException(
        code: 'unreadable',
        message: 'could not read ${picked['uri']}',
      );
    }
    return PickedDocument(
      uri: uri,
      displayName: picked['name'] as String?,
      mimeType: picked['mime'] as String?,
      bytes: bytes,
    );
  }
}

/// In-memory test double.
class FakeDocumentPicker implements DocumentPicker {
  FakeDocumentPicker([List<PickedDocument> queue = const []])
    : _queue = List.of(queue);

  final List<PickedDocument> _queue;
  int pickCount = 0;

  @override
  Future<PickedDocument?> pickDocument() async {
    pickCount += 1;
    if (_queue.isEmpty) return null;
    return _queue.removeAt(0);
  }
}
