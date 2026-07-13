import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../crypto/codec.dart';

typedef SignalSender = FutureOr<void> Function(
  String to,
  String signalType,
  Map<String, dynamic> payload,
);

typedef SecurePacketReceiver = FutureOr<void> Function(
  String from,
  Map<String, dynamic> encryptedPacket,
);

typedef PeerStateChanged = void Function(String peerId, bool connected);

class _PeerState {
  _PeerState(this.connection);

  final RTCPeerConnection connection;
  RTCDataChannel? dataChannel;
  bool remoteDescriptionSet = false;
  final pendingCandidates = <RTCIceCandidate>[];
}

class WebRtcTransport {
  WebRtcTransport({
    required this.localUserId,
    required this.sendSignal,
    required this.onSecurePacket,
    this.onPeerStateChanged,
    this.iceServers = const [],
  });

  final String localUserId;
  final SignalSender sendSignal;
  final SecurePacketReceiver onSecurePacket;
  final PeerStateChanged? onPeerStateChanged;

  /// Domyslnie pusto: prywatnosc ponad skutecznosc NAT traversal.
  /// Mozesz podac wlasny STUN/TURN, jesli chcesz poprawic szanse P2P.
  final List<Map<String, dynamic>> iceServers;

  final Map<String, _PeerState> _peers = {};

  Future<void> ensureStarted(String peerId, {required bool initiator}) async {
    final peer = await _getOrCreatePeer(peerId);
    if (!initiator || peer.dataChannel != null) return;

    final init = RTCDataChannelInit()
      ..ordered = true
      ..maxRetransmits = 5;
    final channel =
        await peer.connection.createDataChannel('secure-packets', init);
    _bindDataChannel(peerId, peer, channel);

    final offer = await peer.connection.createOffer(<String, dynamic>{});
    await peer.connection.setLocalDescription(offer);
    await sendSignal(peerId, 'webrtc-offer', {
      'type': offer.type,
      'sdp': offer.sdp,
    });
  }

  Future<void> handleSignal(
    String from,
    String signalType,
    Map<String, dynamic> payload,
  ) async {
    switch (signalType) {
      case 'webrtc-offer':
        await _handleOffer(from, payload);
        break;
      case 'webrtc-answer':
        await _handleAnswer(from, payload);
        break;
      case 'webrtc-candidate':
        await _handleCandidate(from, payload);
        break;
    }
  }

  Future<bool> sendEncryptedPacket(
      String peerId, Map<String, dynamic> packet) async {
    final channel = _peers[peerId]?.dataChannel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }

    channel.send(
      RTCDataChannelMessage(
        jsonEncode({
          'v': 1,
          'type': 'secure-packet',
          'from': localUserId,
          'payload': packet,
        }),
      ),
    );
    return true;
  }

  Future<void> dispose() async {
    for (final peer in _peers.values) {
      await peer.dataChannel?.close();
      await peer.connection.close();
    }
    _peers.clear();
  }

  Future<_PeerState> _getOrCreatePeer(String peerId) async {
    final existing = _peers[peerId];
    if (existing != null) return existing;

    final connection = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    final peer = _PeerState(connection);
    _peers[peerId] = peer;

    connection.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      sendSignal(peerId, 'webrtc-candidate', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    connection.onDataChannel = (channel) {
      _bindDataChannel(peerId, peer, channel);
    };

    connection.onConnectionState = (state) {
      final connected =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      onPeerStateChanged?.call(peerId, connected);
    };

    return peer;
  }

  Future<void> _handleOffer(String from, Map<String, dynamic> payload) async {
    final peer = await _getOrCreatePeer(from);
    await peer.connection.setRemoteDescription(
      RTCSessionDescription(
        requiredString(payload, 'sdp'),
        requiredString(payload, 'type'),
      ),
    );
    peer.remoteDescriptionSet = true;
    await _flushCandidates(peer);

    final answer = await peer.connection.createAnswer(<String, dynamic>{});
    await peer.connection.setLocalDescription(answer);
    await sendSignal(from, 'webrtc-answer', {
      'type': answer.type,
      'sdp': answer.sdp,
    });
  }

  Future<void> _handleAnswer(String from, Map<String, dynamic> payload) async {
    final peer = await _getOrCreatePeer(from);
    await peer.connection.setRemoteDescription(
      RTCSessionDescription(
        requiredString(payload, 'sdp'),
        requiredString(payload, 'type'),
      ),
    );
    peer.remoteDescriptionSet = true;
    await _flushCandidates(peer);
  }

  Future<void> _handleCandidate(
      String from, Map<String, dynamic> payload) async {
    final peer = await _getOrCreatePeer(from);
    final candidate = RTCIceCandidate(
      requiredString(payload, 'candidate'),
      payload['sdpMid'] as String?,
      payload['sdpMLineIndex'] as int?,
    );

    if (!peer.remoteDescriptionSet) {
      peer.pendingCandidates.add(candidate);
      return;
    }

    await peer.connection.addCandidate(candidate);
  }

  Future<void> _flushCandidates(_PeerState peer) async {
    for (final candidate in peer.pendingCandidates) {
      await peer.connection.addCandidate(candidate);
    }
    peer.pendingCandidates.clear();
  }

  void _bindDataChannel(
      String peerId, _PeerState peer, RTCDataChannel channel) {
    peer.dataChannel = channel;

    channel.onDataChannelState = (state) {
      onPeerStateChanged?.call(
          peerId, state == RTCDataChannelState.RTCDataChannelOpen);
    };

    channel.onMessage = (message) {
      if (message.isBinary) return;
      final decoded = jsonDecode(message.text);
      final map = asStringKeyMap(decoded, 'p2pMessage');
      if (map['v'] != 1 || map['type'] != 'secure-packet') return;
      final from = requiredString(map, 'from');
      if (from != peerId) return;
      final packet = asStringKeyMap(map['payload'], 'payload');
      onSecurePacket(from, packet);
    };
  }
}
