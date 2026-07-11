enum MessageDirection { inbound, outbound, system }

enum MessageStatus { pending, sent, delivered, failed }

enum PlainPayloadType { text, file, retraction }

class PlainPayload {
  const PlainPayload.text(this.text)
      : type = PlainPayloadType.text,
        fileName = null,
        mimeType = null,
        fileBytesBase64 = null,
        fileSize = null,
        targetMessageId = null;

  const PlainPayload.file({
    required this.fileName,
    required this.fileBytesBase64,
    required this.fileSize,
    this.mimeType,
  })  : type = PlainPayloadType.file,
        text = null,
        targetMessageId = null;

  const PlainPayload.retraction({
    required this.targetMessageId,
  })  : type = PlainPayloadType.retraction,
        text = null,
        fileName = null,
        mimeType = null,
        fileBytesBase64 = null,
        fileSize = null;

  final PlainPayloadType type;
  final String? text;
  final String? fileName;
  final String? mimeType;
  final String? fileBytesBase64;
  final int? fileSize;
  final String? targetMessageId;

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
        PlainPayloadType.retraction => {
            'v': 1,
            'type': 'retraction',
            'targetMessageId': targetMessageId,
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
      case 'retraction':
        final targetMessageId = json['targetMessageId'] as String?;
        if (targetMessageId == null || targetMessageId.isEmpty) {
          throw const FormatException(
              'Brak identyfikatora cofanej wiadomosci.');
        }
        return PlainPayload.retraction(targetMessageId: targetMessageId);
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
    this.retracted = false,
    this.transport,
    this.error,
  });

  final String id;
  final String contactId;
  final MessageDirection direction;
  final PlainPayload payload;
  final DateTime createdAt;
  final MessageStatus status;
  final bool retracted;
  final String? transport;
  final String? error;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'id': id,
        'contactId': contactId,
        'direction': direction.name,
        'payload': payload.toJson(),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'status': status.name,
        'retracted': retracted,
        'transport': transport,
        'error': error,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      contactId: json['contactId'] as String,
      direction: MessageDirection.values.byName(json['direction'] as String),
      payload: PlainPayload.fromJson(
          (json['payload'] as Map).cast<String, dynamic>()),
      createdAt: DateTime.parse(json['createdAt'] as String),
      status: MessageStatus.values.byName(json['status'] as String),
      retracted: json['retracted'] == true,
      transport: json['transport'] as String?,
      error: json['error'] as String?,
    );
  }

  ChatMessage copyWith({
    PlainPayload? payload,
    MessageStatus? status,
    bool? retracted,
    String? transport,
    String? error,
  }) {
    return ChatMessage(
      id: id,
      contactId: contactId,
      direction: direction,
      payload: payload ?? this.payload,
      createdAt: createdAt,
      status: status ?? this.status,
      retracted: retracted ?? this.retracted,
      transport: transport ?? this.transport,
      error: error ?? this.error,
    );
  }
}
