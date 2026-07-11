import 'package:flutter/material.dart';

import '../app_state.dart';
import '../crypto/codec.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../platform/file_exporter.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.appState,
    required this.contact,
    super.key,
  });

  final AppState appState;
  final Contact contact;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final messages = widget.appState.messagesFor(widget.contact.userId);
        final p2p = widget.appState.isP2pConnected(widget.contact.userId);
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.contact.displayName),
                Text(
                  p2p ? 'P2P' : 'Relay',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Wyslij plik',
                onPressed: _sending ? null : _sendFile,
                icon: const Icon(Icons.attach_file),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    return _MessageBubble(message: messages[index]);
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          decoration: const InputDecoration(
                            hintText: 'Wiadomosc',
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                          onSubmitted: (_) => _sendText(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Wyslij',
                        onPressed: _sending ? null : _sendText,
                        icon: _sending
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _sendText() async {
    final text = _text.text;
    if (text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      await widget.appState.sendText(widget.contact, text);
      _text.clear();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendFile() async {
    setState(() => _sending = true);
    try {
      await widget.appState.sendFile(widget.contact);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.direction == MessageDirection.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text(
            message.payload.text ?? '',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }

    final outbound = message.direction == MessageDirection.outbound;
    final color = outbound
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Align(
      alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _PayloadView(payload: message.payload),
              const SizedBox(height: 6),
              Text(
                _statusLine(message, context),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLine(ChatMessage message, BuildContext context) {
    final time = TimeOfDay.fromDateTime(message.createdAt.toLocal()).format(context);
    final transport = message.transport == null ? '' : ' • ${message.transport}';
    return '${message.status.name}$transport • $time';
  }
}

class _PayloadView extends StatelessWidget {
  const _PayloadView({required this.payload});

  final PlainPayload payload;

  @override
  Widget build(BuildContext context) {
    return switch (payload.type) {
      PlainPayloadType.text => SelectableText(payload.text ?? ''),
      PlainPayloadType.file => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    payload.fileName ?? 'plik',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(_formatBytes(payload.fileSize ?? 0)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Zapisz',
              onPressed: payload.fileBytesBase64 == null
                  ? null
                  : () async {
                      try {
                        await saveReceivedFile(
                          fileName: payload.fileName ?? 'plik',
                          bytes: unb64(payload.fileBytesBase64!),
                          mimeType: payload.mimeType,
                        );
                      } catch (error) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(error.toString())),
                        );
                      }
                    },
              icon: const Icon(Icons.download),
            ),
          ],
        ),
    };
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
