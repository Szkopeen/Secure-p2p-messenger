enum MessageDirection { inbound, outbound, system }

enum MessageStatus { pending, sent, delivered, failed }

enum PlainPayloadType { text, file }

class PlainPayload {
  const PlainPayload.text(this.text)
      : type = PlainPayloadType.text,
        fileName = null,
        mimeType = null,
        fileBytesBase64 = null,
        fileSize = null;

  const PlainPayload.file({
    required this.fileName,
    required this.fileBytesBase64,
    required this.fileSize,
    this.mimeType,
  })  : type = PlainPayloadType.file,
        text = null;

  final PlainPayloadType type;
  final String? text;
  final String? fileName;
  final String? mimeType;
  final String? fileBytesBase64;
  final int? fileSize;

  Map<String, dynamic> toJson() => switch (type) {
        PlainPayloadType.text => {
            'v': 1,
            'type': 'text',
            'text': text,
          },
        PlainPayloadType.file => {
            'v': 1,
            'type': 'file',
            'fileName': fileName,
            'mimeType': mimeType,
            'fileSize': fileSize,
            'fileBytes': fileBytesBase64,
          },
      };

  factory PlainPayload.fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'text':
        return PlainPayload.text(json['text'] as String? ?? '');
      case 'file':
        return PlainPayload.file(
          fileName: json['fileName'] as String? ?? 'plik',
          mimeType: json['mimeType'] as String?,
          fileSize: json['fileSize'] as int? ?? 0,
          fileBytesBase64: json['fileBytes'] as String? ?? '',
        );
      default:
        throw const FormatException('Nieznany typ payloadu.');
    }
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.contactId,
    required this.direction,
    required this.payload,
    required this.createdAt,
    required this.status,
    this.transport,
    this.error,
  });

  final String id;
  final String contactId;
  final MessageDirection direction;
  final PlainPayload payload;
  final DateTime createdAt;
  final MessageStatus status;
  final String? transport;
  final String? error;

  ChatMessage copyWith({
    MessageStatus? status,
    String? transport,
    String? error,
  }) {
    return ChatMessage(
      id: id,
      contactId: contactId,
      direction: direction,
      payload: payload,
      createdAt: createdAt,
      status: status ?? this.status,
      transport: transport ?? this.transport,
      error: error ?? this.error,
    );
  }
}
