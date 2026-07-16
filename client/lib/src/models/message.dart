enum MessageDirection { inbound, outbound, system }

enum MessageStatus { pending, sent, delivered, read, failed }

enum PlainPayloadType {
  text,
  file,
  retraction,
  reaction,
  pin,
  receipt,
  edit,
}

enum ReceiptKind { delivered, read }

class PlainPayload {
  const PlainPayload.text(this.text, {this.replyToMessageId, this.replyPreview})
      : type = PlainPayloadType.text,
        fileName = null,
        mimeType = null,
        fileBytesBase64 = null,
        fileSize = null,
        targetMessageId = null,
        reactionEmoji = null,
        pinPinned = null,
        receiptKind = null,
        editedText = null;

  const PlainPayload.file({
    required this.fileName,
    required this.fileBytesBase64,
    required this.fileSize,
    this.mimeType,
    this.replyToMessageId,
    this.replyPreview,
  })  : type = PlainPayloadType.file,
        text = null,
        targetMessageId = null,
        reactionEmoji = null,
        pinPinned = null,
        receiptKind = null,
        editedText = null;

  const PlainPayload.retraction({required this.targetMessageId})
      : type = PlainPayloadType.retraction,
        text = null,
        fileName = null,
        mimeType = null,
        fileBytesBase64 = null,
        fileSize = null,
        reactionEmoji = null,
        pinPinned = null,
        receiptKind = null,
        editedText = null,
        replyToMessageId = null,
        replyPreview = null;

  const PlainPayload.reaction({
    required this.targetMessageId,
    this.reactionEmoji,
  })  : type = PlainPayloadType.reaction,
        text = null,
        fileName = null,
        mimeType = null,
        fileBytesBase64 = null,
        fileSize = null,
        pinPinned = null,
        receiptKind = null,
        editedText = null,
        replyToMessageId = null,
        replyPreview = null;

  const PlainPayload.pin({
    required this.targetMessageId,
    required this.pinPinned,
  })  : type = PlainPayloadType.pin,
        text = null,
        fileName = null,
        mimeType = null,
        fileBytesBase64 = null,
        fileSize = null,
        reactionEmoji = null,
        receiptKind = null,
        editedText = null,
        replyToMessageId = null,
        replyPreview = null;

  const PlainPayload.receipt({
    required this.targetMessageId,
    required this.receiptKind,
  })  : type = PlainPayloadType.receipt,
        text = null,
        fileName = null,
        mimeType = null,
        fileBytesBase64 = null,
        fileSize = null,
        reactionEmoji = null,
        pinPinned = null,
        editedText = null,
        replyToMessageId = null,
        replyPreview = null;

  const PlainPayload.edit({
    required this.targetMessageId,
    required this.editedText,
  })  : type = PlainPayloadType.edit,
        text = null,
        fileName = null,
        mimeType = null,
        fileBytesBase64 = null,
        fileSize = null,
        reactionEmoji = null,
        pinPinned = null,
        receiptKind = null,
        replyToMessageId = null,
        replyPreview = null;

  final PlainPayloadType type;
  final String? text;
  final String? fileName;
  final String? mimeType;
  final String? fileBytesBase64;
  final int? fileSize;
  final String? targetMessageId;
  final String? reactionEmoji;
  final bool? pinPinned;
  final ReceiptKind? receiptKind;
  final String? editedText;
  final String? replyToMessageId;
  final String? replyPreview;

  Map<String, dynamic> toJson() => switch (type) {
        PlainPayloadType.text => {
            'v': 1,
            'type': 'text',
            'text': text,
            if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
            if (replyPreview != null) 'replyPreview': replyPreview,
          },
        PlainPayloadType.file => {
            'v': 1,
            'type': 'file',
            'fileName': fileName,
            'mimeType': mimeType,
            'fileSize': fileSize,
            'fileBytes': fileBytesBase64,
            if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
            if (replyPreview != null) 'replyPreview': replyPreview,
          },
        PlainPayloadType.retraction => {
            'v': 1,
            'type': 'retraction',
            'targetMessageId': targetMessageId,
          },
        PlainPayloadType.reaction => {
            'v': 1,
            'type': 'reaction',
            'targetMessageId': targetMessageId,
            'emoji': reactionEmoji,
          },
        PlainPayloadType.pin => {
            'v': 1,
            'type': 'pin',
            'targetMessageId': targetMessageId,
            'pinned': pinPinned,
          },
        PlainPayloadType.receipt => {
            'v': 1,
            'type': 'receipt',
            'targetMessageId': targetMessageId,
            'kind': receiptKind?.name,
          },
        PlainPayloadType.edit => {
            'v': 1,
            'type': 'edit',
            'targetMessageId': targetMessageId,
            'text': editedText,
          },
      };

  factory PlainPayload.fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'text':
        return PlainPayload.text(
          json['text'] as String? ?? '',
          replyToMessageId: json['replyToMessageId'] as String?,
          replyPreview: json['replyPreview'] as String?,
        );
      case 'file':
        return PlainPayload.file(
          fileName: json['fileName'] as String? ?? 'plik',
          mimeType: json['mimeType'] as String?,
          fileSize: json['fileSize'] as int? ?? 0,
          fileBytesBase64: json['fileBytes'] as String? ?? '',
          replyToMessageId: json['replyToMessageId'] as String?,
          replyPreview: json['replyPreview'] as String?,
        );
      case 'retraction':
        final targetMessageId = json['targetMessageId'] as String?;
        if (targetMessageId == null || targetMessageId.isEmpty) {
          throw const FormatException(
            'Brak identyfikatora cofanej wiadomosci.',
          );
        }
        return PlainPayload.retraction(
          targetMessageId: targetMessageId,
        );
      case 'reaction':
        final targetMessageId = json['targetMessageId'] as String?;
        if (targetMessageId == null || targetMessageId.isEmpty) {
          throw const FormatException(
            'Brak identyfikatora wiadomosci dla reakcji.',
          );
        }
        return PlainPayload.reaction(
          targetMessageId: targetMessageId,
          reactionEmoji: json['emoji'] as String?,
        );
      case 'pin':
        final targetMessageId = json['targetMessageId'] as String?;
        if (targetMessageId == null || targetMessageId.isEmpty) {
          throw const FormatException(
            'Brak identyfikatora wiadomosci dla przypiecia.',
          );
        }
        return PlainPayload.pin(
          targetMessageId: targetMessageId,
          pinPinned: json['pinned'] == true,
        );
      case 'receipt':
        final targetMessageId = json['targetMessageId'] as String?;
        if (targetMessageId == null || targetMessageId.isEmpty) {
          throw const FormatException(
            'Brak identyfikatora wiadomosci dla potwierdzenia.',
          );
        }
        return PlainPayload.receipt(
          targetMessageId: targetMessageId,
          receiptKind: ReceiptKind.values.byName(
            json['kind'] as String? ?? 'delivered',
          ),
        );
      case 'edit':
        final targetMessageId = json['targetMessageId'] as String?;
        if (targetMessageId == null || targetMessageId.isEmpty) {
          throw const FormatException(
            'Brak identyfikatora edytowanej wiadomosci.',
          );
        }
        return PlainPayload.edit(
          targetMessageId: targetMessageId,
          editedText: json['text'] as String? ?? '',
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
    this.retracted = false,
    this.pinned = false,
    this.reactions = const {},
    this.editedAt,
    this.senderId,
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
  final bool pinned;
  final Map<String, String> reactions;
  final DateTime? editedAt;
  final String? senderId;
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
        'pinned': pinned,
        'reactions': reactions,
        'editedAt': editedAt?.toUtc().toIso8601String(),
        'senderId': senderId,
        'transport': transport,
        'error': error,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      contactId: json['contactId'] as String,
      direction: MessageDirection.values.byName(json['direction'] as String),
      payload: PlainPayload.fromJson(
        (json['payload'] as Map).cast<String, dynamic>(),
      ),
      createdAt: DateTime.parse(json['createdAt'] as String),
      status: MessageStatus.values.byName(json['status'] as String),
      retracted: json['retracted'] == true,
      pinned: json['pinned'] == true,
      reactions: ((json['reactions'] as Map?) ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      editedAt: json['editedAt'] == null
          ? null
          : DateTime.parse(json['editedAt'] as String),
      senderId: json['senderId'] as String?,
      transport: json['transport'] as String?,
      error: json['error'] as String?,
    );
  }

  ChatMessage copyWith({
    PlainPayload? payload,
    MessageStatus? status,
    bool? retracted,
    bool? pinned,
    Map<String, String>? reactions,
    DateTime? editedAt,
    bool clearEditedAt = false,
    String? senderId,
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
      pinned: pinned ?? this.pinned,
      reactions: reactions ?? this.reactions,
      editedAt: clearEditedAt ? null : editedAt ?? this.editedAt,
      senderId: senderId ?? this.senderId,
      transport: transport ?? this.transport,
      error: error ?? this.error,
    );
  }
}
