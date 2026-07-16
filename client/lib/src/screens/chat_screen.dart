import 'dart:async';

import 'package:audioplayers/audioplayers.dart' as audio;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../app_state.dart';
import '../crypto/codec.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../platform/file_exporter.dart';
import '../platform/media_cache.dart';

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
  final _search = TextEditingController();
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  final _inputFocus = FocusNode();
  List<ChatMessage> _visibleMessages = const [];
  int _lastMessageCount = 0;
  int _pendingSends = 0;
  int _scrollEpoch = 0;
  bool _didInitialScroll = false;
  bool _searchOpen = false;
  bool _dragging = false;
  String? _highlightedMessageId;
  String? _lastReadMarkMessageId;
  ChatMessage? _replyingTo;
  int _searchResultIndex = 0;

  bool get _isSending => _pendingSends > 0;
  String get _conversationId => widget.contact.userId;
  String get _conversationTitle => widget.contact.displayName;

  @override
  void dispose() {
    _text.dispose();
    _search.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final messages = widget.appState.messagesFor(_conversationId);
        _visibleMessages = messages;
        final contact = widget.contact;
        final online = widget.appState.isContactOnline(contact.userId);
        final searchResults = _searchResults(messages);
        final pinnedMessages =
            messages.where((message) => message.pinned).toList();
        _scheduleInitialScroll(messages.length);
        _handleMessageCountChange(messages.length);
        _scheduleMarkConversationRead(messages);

        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                _ContactAvatar(
                  contact: contact,
                  radius: 18,
                  online: online,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _conversationTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        online ? 'Online / Cloud' : 'Offline / Cloud',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Szukaj',
                onPressed: _toggleSearch,
                icon: Icon(_searchOpen ? Icons.search_off : Icons.search),
              ),
              IconButton(
                tooltip: 'Przypiete wiadomosci',
                onPressed: pinnedMessages.isEmpty
                    ? null
                    : () => _showPinnedMessages(pinnedMessages),
                icon: const Icon(Icons.push_pin_outlined),
              ),
              IconButton(
                tooltip: 'Wyslij plik',
                onPressed: _isSending ? null : _sendFile,
                icon: const Icon(Icons.attach_file),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'clear-local') {
                    unawaited(_confirmClearConversation());
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'clear-local',
                    child: _MessageMenuItem(
                      icon: Icons.delete_sweep_outlined,
                      label: 'Usun wiadomosci lokalnie',
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: DropTarget(
            onDragDone: _sendDroppedFiles,
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            child: Stack(
              children: [
                Column(
                  children: [
                    if (_searchOpen)
                      _SearchBar(
                        controller: _search,
                        resultCount: searchResults.length,
                        currentIndex: searchResults.isEmpty
                            ? 0
                            : (_searchResultIndex % searchResults.length) + 1,
                        onChanged: (_) => _onSearchChanged(messages),
                        onPrevious: searchResults.isEmpty
                            ? null
                            : () => _jumpSearchResult(messages, -1),
                        onNext: searchResults.isEmpty
                            ? null
                            : () => _jumpSearchResult(messages, 1),
                        onClose: _toggleSearch,
                      ),
                    Expanded(
                      child: ScrollablePositionedList.builder(
                        itemScrollController: _itemScrollController,
                        itemPositionsListener: _itemPositionsListener,
                        padding: const EdgeInsets.all(12),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final message = messages[index];
                          return _MessageBubble(
                            appState: widget.appState,
                            contact: widget.contact,
                            message: message,
                            senderName: _senderNameFor(message),
                            highlighted: message.id == _highlightedMessageId,
                            onReply: _startReply,
                            onJumpToMessage: _highlightAndScrollToMessage,
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_replyingTo != null) ...[
                              _ReplyComposerPreview(
                                message: _replyingTo!,
                                preview: _messagePreview(_replyingTo!),
                                onCancel: () =>
                                    setState(() => _replyingTo = null),
                              ),
                              const SizedBox(height: 8),
                            ],
                            Row(
                              children: [
                                Expanded(
                                  child: CallbackShortcuts(
                                    bindings: {
                                      const SingleActivator(
                                        LogicalKeyboardKey.enter,
                                      ): () => unawaited(_sendText()),
                                    },
                                    child: TextField(
                                      controller: _text,
                                      focusNode: _inputFocus,
                                      minLines: 1,
                                      maxLines: 6,
                                      keyboardType: TextInputType.multiline,
                                      textInputAction: TextInputAction.newline,
                                      decoration: const InputDecoration(
                                        hintText: 'Wiadomosc',
                                        prefixIcon: Icon(Icons.lock_outline),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton.filled(
                                  tooltip: 'Wyslij',
                                  onPressed: _sendText,
                                  icon: _isSending
                                      ? const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.send),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (_dragging)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.12),
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 16,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.upload_file),
                                  SizedBox(width: 10),
                                  Text('Upusc pliki tutaj'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _sendText() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      _inputFocus.requestFocus();
      return;
    }

    _text.clear();
    final reply = _replyingTo;
    setState(() => _replyingTo = null);
    _inputFocus.requestFocus();
    _incrementPendingSends();
    try {
      await widget.appState.sendText(
        widget.contact,
        text,
        replyToMessageId: reply?.id,
        replyPreview: reply == null ? null : _messagePreview(reply),
      );
    } catch (error) {
      _showError(error);
    } finally {
      _decrementPendingSends();
      if (mounted) _inputFocus.requestFocus();
    }
  }

  Future<void> _sendDroppedFiles(DropDoneDetails detail) async {
    if (detail.files.isEmpty) return;
    setState(() => _dragging = false);
    _incrementPendingSends();
    try {
      final reply = _replyingTo;
      setState(() => _replyingTo = null);
      for (final file in detail.files) {
        final bytes = await file.readAsBytes();
        await widget.appState.sendFileBytes(
          widget.contact,
          fileName: file.name,
          bytes: bytes,
          mimeType: file.mimeType,
          replyToMessageId: reply?.id,
          replyPreview: reply == null ? null : _messagePreview(reply),
        );
      }
    } catch (error) {
      _showError(error);
    } finally {
      _decrementPendingSends();
    }
  }

  Future<void> _confirmClearConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Usun lokalnie rozmowe'),
          content: const Text(
            'Wiadomosci znikna tylko u Ciebie. Druga osoba nadal bedzie miec swoja historie.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Usun'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await widget.appState.deleteConversationLocally(_conversationId);
    if (!mounted) return;
    setState(() {
      _highlightedMessageId = null;
      _lastMessageCount = 0;
    });
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _search.clear();
        _highlightedMessageId = null;
        _searchResultIndex = 0;
      }
    });
  }

  void _onSearchChanged(List<ChatMessage> messages) {
    final results = _searchResults(messages);
    setState(() {
      _searchResultIndex = 0;
      _highlightedMessageId = results.isEmpty ? null : results.first.id;
    });
    if (results.isNotEmpty) _highlightAndScrollToMessage(results.first.id);
  }

  List<ChatMessage> _searchResults(List<ChatMessage> messages) {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return messages
        .where((message) => _messageSearchText(message).contains(query))
        .toList(growable: false);
  }

  String _messageSearchText(ChatMessage message) {
    if (message.retracted) return 'wiadomosc usunieta';
    final text = switch (message.payload.type) {
      PlainPayloadType.text => message.payload.text?.toLowerCase() ?? '',
      PlainPayloadType.file => (message.payload.fileName ?? '').toLowerCase(),
      PlainPayloadType.retraction => 'wiadomosc usunieta',
      PlainPayloadType.reaction => 'reakcja',
      PlainPayloadType.pin => 'przypiecie',
      PlainPayloadType.receipt => 'potwierdzenie',
      PlainPayloadType.edit => message.payload.editedText?.toLowerCase() ?? '',
    };
    final reply = message.payload.replyPreview?.toLowerCase();
    return reply == null || reply.isEmpty ? text : '$text $reply';
  }

  void _jumpSearchResult(List<ChatMessage> messages, int direction) {
    final results = _searchResults(messages);
    if (results.isEmpty) return;
    final nextIndex =
        (_searchResultIndex + direction + results.length) % results.length;
    setState(() {
      _searchResultIndex = nextIndex;
      _highlightedMessageId = results[nextIndex].id;
    });
    _scrollToMessageId(results[nextIndex].id);
  }

  Future<void> _showPinnedMessages(List<ChatMessage> pinnedMessages) async {
    final selectedId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: pinnedMessages.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final message = pinnedMessages[index];
              return ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: Text(
                  _messagePreview(message),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  TimeOfDay.fromDateTime(
                    message.createdAt.toLocal(),
                  ).format(context),
                ),
                onTap: () {
                  Navigator.of(context).pop(message.id);
                },
              );
            },
          ),
        );
      },
    );
    if (selectedId != null) {
      _highlightAndScrollToMessage(selectedId);
    }
  }

  String _messagePreview(ChatMessage message) {
    if (message.retracted) return 'Wiadomosc usunieta';
    return switch (message.payload.type) {
      PlainPayloadType.text => message.payload.text ?? '',
      PlainPayloadType.file =>
        'Plik: ${message.payload.fileName ?? 'zalacznik'}',
      PlainPayloadType.retraction => 'Wiadomosc usunieta',
      PlainPayloadType.reaction => 'Reakcja na wiadomosc',
      PlainPayloadType.pin => 'Przypieto wiadomosc',
      PlainPayloadType.receipt => 'Potwierdzenie wiadomosci',
      PlainPayloadType.edit => 'Edytowano wiadomosc',
    };
  }

  void _scheduleMarkConversationRead(List<ChatMessage> messages) {
    String? newestUnreadId;
    for (final message in messages) {
      if (message.direction == MessageDirection.inbound &&
          message.status != MessageStatus.read &&
          !message.retracted &&
          (message.payload.type == PlainPayloadType.text ||
              message.payload.type == PlainPayloadType.file)) {
        newestUnreadId = message.id;
      }
    }
    if (newestUnreadId == null || newestUnreadId == _lastReadMarkMessageId) {
      return;
    }

    _lastReadMarkMessageId = newestUnreadId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(widget.appState.markConversationRead(widget.contact));
    });
  }

  String? _senderNameFor(ChatMessage message) {
    return null;
  }

  void _highlightAndScrollToMessage(String messageId) {
    if (!mounted) return;
    setState(() => _highlightedMessageId = messageId);
    _scrollToMessageId(messageId);
  }

  void _startReply(ChatMessage message) {
    if (message.direction == MessageDirection.system || message.retracted) {
      return;
    }
    setState(() => _replyingTo = message);
    _inputFocus.requestFocus();
  }

  void _scrollToMessageId(String messageId) {
    final index = _visibleMessages.indexWhere((message) {
      return message.id == messageId;
    });
    if (index < 0) return;

    final epoch = ++_scrollEpoch;

    void attempt(int remaining) {
      if (!mounted || epoch != _scrollEpoch) return;
      if (!_itemScrollController.isAttached) {
        if (remaining > 0) {
          Future<void>.delayed(
            const Duration(milliseconds: 60),
            () => attempt(remaining - 1),
          );
        }
        return;
      }

      _itemScrollController.scrollTo(
        index: index,
        alignment: 0.32,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      attempt(10);
    });
  }

  Future<void> _sendFile() async {
    _incrementPendingSends();
    try {
      final reply = _replyingTo;
      setState(() => _replyingTo = null);
      await widget.appState.sendFile(
        widget.contact,
        replyToMessageId: reply?.id,
        replyPreview: reply == null ? null : _messagePreview(reply),
      );
    } catch (error) {
      _showError(error);
    } finally {
      _decrementPendingSends();
    }
  }

  void _handleMessageCountChange(int messageCount) {
    if (messageCount == _lastMessageCount) return;
    final shouldScroll = messageCount > _lastMessageCount && _isNearBottom();
    _lastMessageCount = messageCount;
    if (shouldScroll) _scrollToBottom();
  }

  void _scheduleInitialScroll(int messageCount) {
    if (_didInitialScroll) return;
    _didInitialScroll = true;
    _lastMessageCount = messageCount;
    _scrollToBottom(jump: true);
  }

  bool _isNearBottom() {
    if (_visibleMessages.isEmpty) return true;
    final lastIndex = _visibleMessages.length - 1;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return true;
    return positions.any((position) {
      return position.index == lastIndex && position.itemTrailingEdge <= 1.12;
    });
  }

  void _scrollToBottom({bool jump = false}) {
    if (_visibleMessages.isEmpty) return;
    final lastIndex = _visibleMessages.length - 1;
    final epoch = ++_scrollEpoch;
    void attempt(int remaining) {
      if (!mounted || epoch != _scrollEpoch) return;
      if (!_itemScrollController.isAttached) {
        if (remaining > 0) {
          Future<void>.delayed(
            const Duration(milliseconds: 60),
            () => attempt(remaining - 1),
          );
        }
        return;
      }

      if (jump) {
        _itemScrollController.jumpTo(index: lastIndex, alignment: 1);
        Future<void>.delayed(const Duration(milliseconds: 80), () {
          if (!mounted || epoch != _scrollEpoch) return;
          if (!_itemScrollController.isAttached) return;
          _itemScrollController.jumpTo(index: lastIndex, alignment: 1);
        });
        return;
      }

      _itemScrollController.scrollTo(
        index: lastIndex,
        alignment: 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      attempt(10);
    });
  }

  void _incrementPendingSends() {
    if (!mounted) return;
    setState(() => _pendingSends += 1);
  }

  void _decrementPendingSends() {
    if (!mounted) return;
    setState(() {
      if (_pendingSends > 0) _pendingSends -= 1;
    });
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

class _ReplyComposerPreview extends StatelessWidget {
  const _ReplyComposerPreview({
    required this.message,
    required this.preview,
    required this.onCancel,
  });

  final ChatMessage message;
  final String preview;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final label = message.direction == MessageDirection.outbound
        ? 'Odpowiadasz na swoja wiadomosc'
        : 'Odpowiadasz';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 4,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: Theme.of(context).textTheme.labelMedium),
                  Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Anuluj odpowiedz',
              onPressed: onCancel,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplySnippet extends StatelessWidget {
  const _ReplySnippet({required this.preview, required this.onTap});

  final String preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color: Theme.of(context).colorScheme.primary,
              width: 4,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.reply, size: 16),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactAvatar extends StatelessWidget {
  const _ContactAvatar({
    required this.contact,
    required this.radius,
    required this.online,
  });

  final Contact contact;
  final double radius;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final bytes = _avatarBytes();
    final fallback = contact.displayName.isEmpty
        ? '?'
        : contact.displayName.substring(0, 1).toUpperCase();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundImage: bytes == null ? null : MemoryImage(bytes),
          child: bytes == null ? Text(fallback) : null,
        ),
        if (online)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: Colors.green.shade500,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Uint8List? _avatarBytes() {
    final raw = contact.avatarBytesBase64;
    if (raw == null || raw.isEmpty) return null;
    try {
      return unb64(raw);
    } catch (_) {
      return null;
    }
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.resultCount,
    required this.currentIndex,
    required this.onChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final TextEditingController controller;
  final int resultCount;
  final int currentIndex;
  final ValueChanged<String> onChanged;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Szukaj w rozmowie',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: onChanged,
              ),
            ),
            const SizedBox(width: 8),
            Text(resultCount == 0 ? '0' : '$currentIndex/$resultCount'),
            IconButton(
              tooltip: 'Poprzedni wynik',
              onPressed: onPrevious,
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: 'Nastepny wynik',
              onPressed: onNext,
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
            IconButton(
              tooltip: 'Zamknij',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

enum _MessageAction { reply, react, edit, retract, pin, unpin, deleteLocal }

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.appState,
    required this.contact,
    required this.message,
    required this.senderName,
    required this.highlighted,
    required this.onReply,
    required this.onJumpToMessage,
  });

  final AppState appState;
  final Contact contact;
  final ChatMessage message;
  final String? senderName;
  final bool highlighted;
  final ValueChanged<ChatMessage> onReply;
  final ValueChanged<String> onJumpToMessage;

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
            border: highlighted
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (senderName != null) ...[
                Text(
                  senderName!,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
                const SizedBox(height: 4),
              ],
              message.retracted
                  ? _RetractedMessageView(outbound: outbound)
                  : _PayloadView(
                      payload: message.payload,
                      onReplyTap: onJumpToMessage,
                    ),
              if (message.reactions.isNotEmpty) ...[
                const SizedBox(height: 8),
                _ReactionSummary(reactions: message.reactions),
              ],
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.pinned) ...[
                    const Icon(Icons.push_pin, size: 14),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      _statusLine(message, context),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  const SizedBox(width: 4),
                  _MessageActionsButton(
                    canReply: _canReply(message),
                    canReact: _canReact(message),
                    canEdit: _canEdit(message),
                    canRetract: _canRetract(message),
                    pinned: message.pinned,
                    onSelected: (action) => _handleAction(context, action),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLine(ChatMessage message, BuildContext context) {
    final time = TimeOfDay.fromDateTime(
      message.createdAt.toLocal(),
    ).format(context);
    final transport =
        message.transport == null ? '' : ' / ${message.transport}';
    final edited = message.editedAt == null ? '' : ' / edytowano';
    return '${_statusLabel(message.status)}$transport / $time$edited';
  }

  String _statusLabel(MessageStatus status) {
    return switch (status) {
      MessageStatus.pending => 'wysylanie',
      MessageStatus.sent => 'wyslano',
      MessageStatus.delivered => 'dostarczono',
      MessageStatus.read => 'odczytano',
      MessageStatus.failed => 'blad',
    };
  }

  bool _canEdit(ChatMessage message) {
    return message.direction == MessageDirection.outbound &&
        !message.retracted &&
        message.status != MessageStatus.failed &&
        message.payload.type == PlainPayloadType.text;
  }

  bool _canRetract(ChatMessage message) {
    return message.direction == MessageDirection.outbound &&
        !message.retracted &&
        message.status != MessageStatus.failed &&
        (message.payload.type == PlainPayloadType.text ||
            message.payload.type == PlainPayloadType.file);
  }

  bool _canReact(ChatMessage message) {
    return message.direction != MessageDirection.system &&
        !message.retracted &&
        message.payload.type != PlainPayloadType.retraction &&
        message.payload.type != PlainPayloadType.reaction &&
        message.payload.type != PlainPayloadType.pin &&
        message.payload.type != PlainPayloadType.receipt &&
        message.payload.type != PlainPayloadType.edit;
  }

  bool _canReply(ChatMessage message) {
    return message.direction != MessageDirection.system && !message.retracted;
  }

  Future<void> _handleAction(
    BuildContext context,
    _MessageAction action,
  ) async {
    try {
      switch (action) {
        case _MessageAction.reply:
          onReply(message);
          break;
        case _MessageAction.react:
          await _showReactionPicker(context);
          break;
        case _MessageAction.edit:
          await _showEditDialog(context);
          break;
        case _MessageAction.retract:
          await appState.retractMessage(contact, message);
          break;
        case _MessageAction.pin:
          await appState.setMessagePinned(contact, message, true);
          break;
        case _MessageAction.unpin:
          await appState.setMessagePinned(contact, message, false);
          break;
        case _MessageAction.deleteLocal:
          await appState.deleteMessageLocally(message.contactId, message.id);
          break;
      }
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _showEditDialog(BuildContext context) async {
    final controller = TextEditingController(text: message.payload.text ?? '');
    final edited = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edytuj wiadomosc'),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: 'Nowa tresc wiadomosci',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Zapisz'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (edited == null) return;
    await appState.editMessage(contact, message, edited);
  }

  Future<void> _showReactionPicker(BuildContext context) async {
    const emojis = ['❤️', '😂', '😮', '😢', '😡', '👍', '👎', '🔥'];
    final selected = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Reakcja'),
          content: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final emoji in emojis)
                IconButton.filledTonal(
                  tooltip: emoji,
                  onPressed: () => Navigator.of(context).pop(emoji),
                  icon: Text(emoji, style: const TextStyle(fontSize: 22)),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Anuluj'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(''),
              child: const Text('Usun moja reakcje'),
            ),
          ],
        );
      },
    );
    if (selected == null) return;
    await appState.reactToMessage(
      contact,
      message,
      selected.isEmpty ? null : selected,
    );
  }
}

class _MessageActionsButton extends StatelessWidget {
  const _MessageActionsButton({
    required this.canReply,
    required this.canReact,
    required this.canEdit,
    required this.canRetract,
    required this.pinned,
    required this.onSelected,
  });

  final bool canReply;
  final bool canReact;
  final bool canEdit;
  final bool canRetract;
  final bool pinned;
  final ValueChanged<_MessageAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_MessageAction>(
      tooltip: 'Opcje wiadomosci',
      icon: const Icon(Icons.more_vert, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 180),
      itemBuilder: (context) => [
        if (canReply)
          const PopupMenuItem(
            value: _MessageAction.reply,
            child: _MessageMenuItem(
              icon: Icons.reply_outlined,
              label: 'Odpowiedz',
            ),
          ),
        if (canReact)
          const PopupMenuItem(
            value: _MessageAction.react,
            child: _MessageMenuItem(
              icon: Icons.add_reaction_outlined,
              label: 'Reaguj',
            ),
          ),
        if (canEdit)
          const PopupMenuItem(
            value: _MessageAction.edit,
            child: _MessageMenuItem(icon: Icons.edit_outlined, label: 'Edytuj'),
          ),
        if (canReact)
          PopupMenuItem(
            value: pinned ? _MessageAction.unpin : _MessageAction.pin,
            child: _MessageMenuItem(
              icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
              label: pinned ? 'Odepnij' : 'Przypnij',
            ),
          ),
        if (canRetract)
          const PopupMenuItem(
            value: _MessageAction.retract,
            child: _MessageMenuItem(
              icon: Icons.undo,
              label: 'Cofnij dla wszystkich',
            ),
          ),
        const PopupMenuItem(
          value: _MessageAction.deleteLocal,
          child: _MessageMenuItem(
            icon: Icons.delete_outline,
            label: 'Usun lokalnie',
          ),
        ),
      ],
      onSelected: onSelected,
    );
  }
}

class _MessageMenuItem extends StatelessWidget {
  const _MessageMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)],
    );
  }
}

class _ReactionSummary extends StatelessWidget {
  const _ReactionSummary({required this.reactions});

  final Map<String, String> reactions;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, int>{};
    for (final emoji in reactions.values) {
      grouped[emoji] = (grouped[emoji] ?? 0) + 1;
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final entry in grouped.entries)
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                entry.value > 1 ? '${entry.key} ${entry.value}' : entry.key,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
      ],
    );
  }
}

class _RetractedMessageView extends StatelessWidget {
  const _RetractedMessageView({required this.outbound});

  final bool outbound;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.block, size: 18),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            outbound
                ? 'Usunieto wyslana wiadomosc.'
                : 'Wiadomosc zostala usunieta.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
          ),
        ),
      ],
    );
  }
}

class _PayloadView extends StatelessWidget {
  const _PayloadView({required this.payload, required this.onReplyTap});

  final PlainPayload payload;
  final ValueChanged<String> onReplyTap;

  @override
  Widget build(BuildContext context) {
    final body = switch (payload.type) {
      PlainPayloadType.text => SelectableText(payload.text ?? ''),
      PlainPayloadType.retraction => const Text('Wiadomosc zostala usunieta.'),
      PlainPayloadType.reaction => const Text('Reakcja na wiadomosc.'),
      PlainPayloadType.pin => const Text('Przypieto wiadomosc.'),
      PlainPayloadType.receipt => const Text('Potwierdzono wiadomosc.'),
      PlainPayloadType.edit => const Text('Edytowano wiadomosc.'),
      PlainPayloadType.file => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isImagePayload(payload)) ...[
              _ImagePreview(payload: payload),
              const SizedBox(height: 8),
            ] else if (_isAudioPayload(payload)) ...[
              _AudioPreview(payload: payload),
              const SizedBox(height: 8),
            ] else if (_isVideoPayload(payload)) ...[
              _VideoPreview(payload: payload),
              const SizedBox(height: 8),
            ],
            Row(
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
          ],
        ),
    };

    final replyToMessageId = payload.replyToMessageId;
    final replyPreview = payload.replyPreview;
    if (replyToMessageId == null ||
        replyToMessageId.isEmpty ||
        replyPreview == null ||
        replyPreview.isEmpty) {
      return body;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _ReplySnippet(
          preview: replyPreview,
          onTap: () => onReplyTap(replyToMessageId),
        ),
        const SizedBox(height: 8),
        body,
      ],
    );
  }

  bool _isImagePayload(PlainPayload payload) {
    if (payload.fileBytesBase64 == null) return false;
    final mimeType = payload.mimeType?.toLowerCase();
    if (mimeType != null && mimeType.startsWith('image/')) return true;
    final name = payload.fileName?.toLowerCase() ?? '';
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp') ||
        name.endsWith('.bmp');
  }

  bool _isAudioPayload(PlainPayload payload) {
    if (payload.fileBytesBase64 == null) return false;
    final mimeType = payload.mimeType?.toLowerCase();
    if (mimeType != null && mimeType.startsWith('audio/')) return true;
    final name = payload.fileName?.toLowerCase() ?? '';
    return name.endsWith('.mp3') ||
        name.endsWith('.wav') ||
        name.endsWith('.ogg') ||
        name.endsWith('.m4a') ||
        name.endsWith('.aac') ||
        name.endsWith('.flac');
  }

  bool _isVideoPayload(PlainPayload payload) {
    if (payload.fileBytesBase64 == null) return false;
    final mimeType = payload.mimeType?.toLowerCase();
    if (mimeType != null && mimeType.startsWith('video/')) return true;
    final name = payload.fileName?.toLowerCase() ?? '';
    return name.endsWith('.mp4') ||
        name.endsWith('.mov') ||
        name.endsWith('.webm') ||
        name.endsWith('.mkv') ||
        name.endsWith('.avi');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _AudioPreview extends StatefulWidget {
  const _AudioPreview({required this.payload});

  final PlainPayload payload;

  @override
  State<_AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<_AudioPreview> {
  final _player = audio.AudioPlayer();
  audio.PlayerState _state = audio.PlayerState.stopped;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _state = state);
    });
  }

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playing = _state == audio.PlayerState.playing;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filledTonal(
              tooltip: playing ? 'Pauza' : 'Odtworz',
              onPressed: _toggle,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                widget.payload.fileName ?? 'audio',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggle() async {
    if (_state == audio.PlayerState.playing) {
      await _player.pause();
      return;
    }

    final raw = widget.payload.fileBytesBase64;
    if (raw == null || raw.isEmpty) return;
    await _player.play(audio.BytesSource(unb64(raw)));
  }
}

class _VideoPreview extends StatelessWidget {
  const _VideoPreview({required this.payload});

  final PlainPayload payload;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _showVideoDialog(context),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Icon(
              Icons.play_circle_fill,
              size: 56,
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showVideoDialog(BuildContext context) async {
    final raw = payload.fileBytesBase64;
    if (raw == null || raw.isEmpty) return;

    String? path;
    try {
      path = await writeTempMediaFile(
        fileName: payload.fileName ?? 'video.mp4',
        bytes: unb64(raw),
      );
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _VideoPlayerDialog(path: path!),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (path != null) {
        await deleteTempMediaFile(path);
      }
    }
  }
}

class _VideoPlayerDialog extends StatefulWidget {
  const _VideoPlayerDialog({required this.path});

  final String path;

  @override
  State<_VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<_VideoPlayerDialog> {
  late final Player _player;
  late final VideoController _controller;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    unawaited(_player.open(Media(widget.path)));
  }

  @override
  void dispose() {
    unawaited(_disposePlayerAndMedia());
    super.dispose();
  }

  Future<void> _disposePlayerAndMedia() async {
    try {
      await _player.dispose();
    } finally {
      await deleteTempMediaFile(widget.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Video(controller: _controller),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton.filled(
                tooltip: 'Zamknij',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.payload});

  final PlainPayload payload;

  @override
  Widget build(BuildContext context) {
    final bytes = unb64(payload.fileBytesBase64!);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _showImageDialog(context, bytes),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320, maxHeight: 240),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }

  void _showImageDialog(BuildContext context, Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: EdgeInsets.zero,
          child: SizedBox.expand(
            child: Stack(
              children: [
                Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 5,
                    child: Image.memory(bytes),
                  ),
                ),
                Positioned(
                  top: 16,
                  right: 16,
                  child: IconButton.filled(
                    tooltip: 'Zamknij',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
