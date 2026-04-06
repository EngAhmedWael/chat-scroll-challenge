import 'dart:async';
import 'package:chat/GeminiStreamManager.dart';
import 'package:cross_cache/cross_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flyer_chat_image_message/flyer_chat_image_message.dart';
import 'package:flyer_chat_text_message/flyer_chat_text_message.dart';
import 'package:flyer_chat_text_stream_message/flyer_chat_text_stream_message.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

const Duration _kChunkAnimationDuration = Duration(milliseconds: 350);

// كم pixel من الأسفل يعتبر "في الأسفل"
const double _kScrollThreshold = 80.0;

class GeminiChatScreen extends StatefulWidget {
  final String geminiApiKey;
  const GeminiChatScreen({super.key, required this.geminiApiKey});

  @override
  State<GeminiChatScreen> createState() => _GeminiChatScreenState();
}

class _GeminiChatScreenState extends State<GeminiChatScreen> {
  final _uuid = const Uuid();
  final _crossCache = CrossCache();
  final _scrollController = ScrollController();
  final _chatController = InMemoryChatController();
  final _currentUser = const User(id: 'me');
  final _agent = const User(id: 'agent');

  late final GenerativeModel _model;
  late ChatSession _chatSession;
  late final GeminiStreamManager _streamManager;

  bool _isStreaming = false;
  StreamSubscription? _currentStreamSubscription;
  String? _currentStreamId;

  // ✅ الحل الأساسي: تتبع حالة الـ auto-scroll
  bool _autoScroll = true;
  // منع listener من التداخل أثناء الـ scroll البرنامجي
  bool _isProgrammaticScroll = false;

  @override
  void initState() {
    super.initState();
    _streamManager = GeminiStreamManager(
      chatController: _chatController,
      chunkAnimationDuration: _kChunkAnimationDuration,
    );
    _model = GenerativeModel(
      model: 'gemini-2.5-flash-lite',
      apiKey: widget.geminiApiKey,
      safetySettings: [
        SafetySetting(HarmCategory.dangerousContent, HarmBlockThreshold.none),
      ],
    );
    _chatSession = _model.startChat();

    // ✅ Scenario 2 & 4: مراقبة الـ scroll
    _scrollController.addListener(_onScroll);
  }

  // ✅ منطق تحديد هل المستخدم "في الأسفل" أم لا
  void _onScroll() {
    if (_isProgrammaticScroll) return;
    if (!_scrollController.hasClients) return;

    final pos = _scrollController.position;
    final distanceFromBottom = pos.maxScrollExtent - pos.pixels;

    if (distanceFromBottom <= _kScrollThreshold) {
      // Scenario 4: رجع للأسفل → شغّل auto-scroll مجدداً
      if (!_autoScroll) {
        setState(() => _autoScroll = true);
      }
    } else {
      // Scenario 2: سكرل لفوق يدوياً → أوقف auto-scroll
      if (_autoScroll) {
        setState(() => _autoScroll = false);
      }
    }
  }

  // ✅ scroll برنامجي للأسفل
  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _isProgrammaticScroll = true;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    // أعطِ frame واحد ثم أعد الـ flag
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isProgrammaticScroll = false;
    });
  }

  @override
  void dispose() {
    _currentStreamSubscription?.cancel();
    _streamManager.dispose();
    _chatController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _crossCache.dispose();
    super.dispose();
  }

  void _stopCurrentStream() {
    if (_currentStreamSubscription != null && _currentStreamId != null) {
      _currentStreamSubscription!.cancel();
      _currentStreamSubscription = null;
      setState(() => _isStreaming = false);
      if (_currentStreamId != null) {
        _streamManager.errorStream(_currentStreamId!, 'Stream stopped by user');
        _currentStreamId = null;
      }
    }
  }

  void _handleStreamError(
    String streamId,
    dynamic error,
    TextStreamMessage? streamMessage,
  ) async {
    debugPrint('Generation error for $streamId: $error');
    if (streamMessage != null) {
      await _streamManager.errorStream(streamId, error);
    }
    if (mounted) {
      setState(() => _isStreaming = false);
    }
    _currentStreamSubscription = null;
    _currentStreamId = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Gemini Chat')),
      body: ChangeNotifierProvider.value(
        value: _streamManager,
        child: Chat(
          builders: Builders(
            chatAnimatedListBuilder: (context, itemBuilder) {
              return ChatAnimatedList(
                scrollController: _scrollController,
                itemBuilder: itemBuilder,
              );
            },
            imageMessageBuilder:
                (
                  context,
                  message,
                  index, {
                  required bool isSentByMe,
                  MessageGroupStatus? groupStatus,
                }) => FlyerChatImageMessage(
                  message: message,
                  index: index,
                  showTime: false,
                  showStatus: false,
                ),
            composerBuilder: (context) => _Composer(
              isStreaming: _isStreaming,
              onStop: _stopCurrentStream,
            ),
            textMessageBuilder:
                (
                  context,
                  message,
                  index, {
                  required bool isSentByMe,
                  MessageGroupStatus? groupStatus,
                }) => FlyerChatTextMessage(
                  message: message,
                  index: index,
                  showTime: false,
                  showStatus: false,
                  receivedBackgroundColor: Colors.transparent,
                  padding: message.authorId == _agent.id
                      ? EdgeInsets.zero
                      : const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                ),
            textStreamMessageBuilder:
                (
                  context,
                  message,
                  index, {
                  required bool isSentByMe,
                  MessageGroupStatus? groupStatus,
                }) {
                  final streamState = context
                      .watch<GeminiStreamManager>()
                      .getState(message.streamId);
                  return FlyerChatTextStreamMessage(
                    message: message,
                    index: index,
                    streamState: streamState,
                    chunkAnimationDuration: _kChunkAnimationDuration,
                    showTime: false,
                    showStatus: false,
                    receivedBackgroundColor: Colors.transparent,
                    padding: message.authorId == _agent.id
                        ? EdgeInsets.zero
                        : const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                  );
                },
          ),
          chatController: _chatController,
          crossCache: _crossCache,
          currentUserId: _currentUser.id,
          onAttachmentTap: _handleAttachmentTap,
          onMessageSend: _handleMessageSend,
          resolveUser: (id) => Future.value(switch (id) {
            'me' => _currentUser,
            'agent' => _agent,
            _ => null,
          }),
          theme: ChatTheme.fromThemeData(theme),
        ),
      ),
    );
  }

  void _handleMessageSend(String text) async {
    // ✅ Scenario 3: عند إرسال رسالة → أعد تفعيل auto-scroll وانزل للأسفل
    setState(() => _autoScroll = true);

    await _chatController.insertMessage(
      TextMessage(
        id: _uuid.v4(),
        authorId: _currentUser.id,
        createdAt: DateTime.now().toUtc(),
        text: text,
        metadata: isOnlyEmoji(text) ? {'isOnlyEmoji': true} : null,
      ),
    );

    // انزل بعد إضافة الرسالة
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    _sendContent(Content.text(text));
  }

  void _handleAttachmentTap() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    await _crossCache.downloadAndSave(image.path);
    await _chatController.insertMessage(
      ImageMessage(
        id: _uuid.v4(),
        authorId: _currentUser.id,
        createdAt: DateTime.now().toUtc(),
        source: image.path,
      ),
    );

    // ✅ انزل بعد إضافة الصورة
    setState(() => _autoScroll = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    final bytes = await _crossCache.get(image.path);
    _sendContent(Content.data('image/jpeg', bytes));
  }

  void _sendContent(Content content) async {
    final streamId = _uuid.v4();
    _currentStreamId = streamId;
    TextStreamMessage? streamMessage;
    var messageInserted = false;

    setState(() => _isStreaming = true);

    Future<void> createAndInsertMessage() async {
      if (messageInserted || !mounted) return;
      messageInserted = true;
      streamMessage = TextStreamMessage(
        id: streamId,
        authorId: _agent.id,
        createdAt: DateTime.now().toUtc(),
        streamId: streamId,
      );
      await _chatController.insertMessage(streamMessage!);
      _streamManager.startStream(streamId, streamMessage!);
    }

    try {
      final response = _chatSession.sendMessageStream(content);
      _currentStreamSubscription = response.listen(
        (chunk) async {
          if (chunk.text != null) {
            final textChunk = chunk.text!;
            if (textChunk.isEmpty) return;

            if (!messageInserted) {
              await createAndInsertMessage();
            }
            if (streamMessage == null) return;

            _streamManager.addChunk(streamId, textChunk);

            // ✅ Scenario 1: auto-scroll مع كل chunk
            if (_autoScroll) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _scrollToBottom(),
              );
            }
          }
        },
        onDone: () async {
          if (streamMessage != null) {
            await _streamManager.completeStream(streamId);
          }
          if (mounted) {
            setState(() => _isStreaming = false);
            // scroll أخير بعد اكتمال الرسالة
            if (_autoScroll) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _scrollToBottom(),
              );
            }
          }
          _currentStreamSubscription = null;
          _currentStreamId = null;
        },
        onError: (error) async {
          _handleStreamError(streamId, error, streamMessage);
        },
      );
    } catch (error) {
      _handleStreamError(streamId, error, streamMessage);
    }
  }
}

class _Composer extends StatefulWidget {
  final bool isStreaming;
  final VoidCallback? onStop;

  const _Composer({this.isStreaming = false, this.onStop});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _key = GlobalKey();
  late final TextEditingController _textController;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController();
    _focusNode = FocusNode();
    _focusNode.onKeyEvent = _handleKeyEvent;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        HardwareKeyboard.instance.isShiftPressed) {
      _handleSubmitted(_textController.text);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(covariant _Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;
    final onAttachmentTap = context.read<OnAttachmentTapCallback?>();
    final theme = context.select(
      (ChatTheme t) => (
        bodyMedium: t.typography.bodyMedium,
        onSurface: t.colors.onSurface,
        surfaceContainerHigh: t.colors.surfaceContainerHigh,
        surfaceContainerLow: t.colors.surfaceContainerLow,
      ),
    );

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: ClipRect(
        child: Container(
          key: _key,
          color: theme.surfaceContainerLow,
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.only(
                  bottom: bottomSafeArea,
                ).add(const EdgeInsets.all(8.0)),
                child: Row(
                  children: [
                    if (onAttachmentTap != null)
                      IconButton(
                        icon: const Icon(Icons.attachment),
                        color: theme.onSurface.withValues(alpha: 0.5),
                        onPressed: onAttachmentTap,
                      )
                    else
                      const SizedBox.shrink(),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        decoration: InputDecoration(
                          hintText: 'Type a message',
                          hintStyle: theme.bodyMedium.copyWith(
                            color: theme.onSurface.withValues(alpha: 0.5),
                          ),
                          border: const OutlineInputBorder(
                            borderSide: BorderSide.none,
                            borderRadius: BorderRadius.all(Radius.circular(24)),
                          ),
                          filled: true,
                          fillColor: theme.surfaceContainerHigh.withValues(
                            alpha: 0.8,
                          ),
                          hoverColor: Colors.transparent,
                        ),
                        style: theme.bodyMedium.copyWith(
                          color: theme.onSurface,
                        ),
                        onSubmitted: _handleSubmitted,
                        textInputAction: TextInputAction.newline,
                        autocorrect: true,
                        autofocus: false,
                        textCapitalization: TextCapitalization.sentences,
                        focusNode: _focusNode,
                        minLines: 1,
                        maxLines: 3,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: widget.isStreaming
                          ? const Icon(Icons.stop_circle)
                          : const Icon(Icons.send),
                      color: theme.onSurface.withValues(alpha: 0.5),
                      onPressed: widget.isStreaming
                          ? widget.onStop
                          : () => _handleSubmitted(_textController.text),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _measure() {
    if (!mounted) return;
    final renderBox = _key.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      final height = renderBox.size.height;
      final bottomSafeArea = MediaQuery.of(context).padding.bottom;
      context.read<ComposerHeightNotifier>().setHeight(height - bottomSafeArea);
    }
  }

  void _handleSubmitted(String text) {
    if (text.isNotEmpty) {
      context.read<OnMessageSendCallback?>()?.call(text);
      _textController.clear();
    }
  }
}
