import 'dotenv/config';
import crypto from 'node:crypto';
import http from 'node:http';
import process from 'node:process';
import { WebSocketServer, WebSocket } from 'ws';
import { config } from './config.js';
import {
  safeJsonParse,
  validateHello,
  validatePresenceQuery,
  validateRelay,
  validateSignal
} from './protocol.js';
import { SlidingWindowRateLimiter } from './rateLimiter.js';

const users = new Map();

function audit(message, fields = {}) {
  if (!config.securityLogs) return;
  const safeFields = { ...fields };
  delete safeFields.payload;
  delete safeFields.relayToken;
  console.info(JSON.stringify({ time: new Date().toISOString(), message, ...safeFields }));
}

function timingSafeTokenEquals(received) {
  const expected = Buffer.from(config.relayToken, 'utf8');
  const actual = Buffer.from(String(received || ''), 'utf8');
  if (actual.length !== expected.length) return false;
  return crypto.timingSafeEqual(actual, expected);
}

function send(ws, message) {
  if (ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify(message));
}

function closeWithError(ws, code, reason) {
  try {
    send(ws, { v: 1, type: 'error', code, reason });
    ws.close(code, reason.slice(0, 120));
  } catch {
    ws.terminate();
  }
}

function registerClient(state, ws) {
  const existing = users.get(state.userId) || new Map();
  if (existing.size >= config.maxConnectionsPerUser) {
    closeWithError(ws, 1008, 'Za duzo aktywnych polaczen dla uzytkownika.');
    return false;
  }

  existing.set(state.connectionId, { ws, state });
  users.set(state.userId, existing);
  return true;
}

function unregisterClient(state) {
  if (!state.userId) return;
  const existing = users.get(state.userId);
  if (!existing) return;
  existing.delete(state.connectionId);
  if (existing.size === 0) users.delete(state.userId);
}

function forwardToUser(to, envelope) {
  const recipients = users.get(to);
  if (!recipients || recipients.size === 0) {
    return 0;
  }

  let delivered = 0;
  for (const { ws } of recipients.values()) {
    if (ws.readyState === WebSocket.OPEN) {
      send(ws, envelope);
      delivered += 1;
    }
  }
  return delivered;
}

function handleHello(ws, state, message) {
  const error = validateHello(message);
  if (error) {
    closeWithError(ws, 1008, error);
    return;
  }

  if (!timingSafeTokenEquals(message.relayToken)) {
    audit('Nieudana autoryzacja relay', { userId: message.userId });
    closeWithError(ws, 1008, 'Niepoprawna autoryzacja.');
    return;
  }

  state.authenticated = true;
  state.userId = message.userId;
  state.deviceId = message.deviceId;
  state.identityPublicKey = message.identityPublicKey;

  if (!registerClient(state, ws)) return;

  audit('Polaczono klienta', { userId: state.userId, deviceId: state.deviceId });
  send(ws, {
    v: 1,
    type: 'hello_ok',
    connectionId: state.connectionId,
    serverTime: new Date().toISOString(),
    maxPayloadBytes: config.maxPayloadBytes
  });
}

function handleRelay(ws, state, message) {
  const error = validateRelay(message);
  if (error) {
    send(ws, { v: 1, type: 'error', id: message.id, code: 'bad_relay', reason: error });
    return;
  }

  const envelope = {
    v: 1,
    type: 'deliver',
    kind: 'relay',
    id: message.id,
    from: state.userId,
    to: message.to,
    sentAt: new Date().toISOString(),
    payload: message.payload
  };

  const deliveredConnections = forwardToUser(message.to, envelope);
  send(ws, {
    v: 1,
    type: 'sent',
    id: message.id,
    to: message.to,
    transport: 'relay',
    deliveredConnections
  });
}

function handleSignal(ws, state, message) {
  const error = validateSignal(message);
  if (error) {
    send(ws, { v: 1, type: 'error', id: message.id, code: 'bad_signal', reason: error });
    return;
  }

  const envelope = {
    v: 1,
    type: 'deliver',
    kind: 'signal',
    id: message.id,
    from: state.userId,
    to: message.to,
    signalType: message.signalType,
    sentAt: new Date().toISOString(),
    payload: message.payload
  };

  const deliveredConnections = forwardToUser(message.to, envelope);
  send(ws, {
    v: 1,
    type: 'sent',
    id: message.id,
    to: message.to,
    transport: 'signal',
    deliveredConnections
  });
}

function handlePresenceQuery(ws, message) {
  const error = validatePresenceQuery(message);
  if (error) {
    send(ws, { v: 1, type: 'error', code: 'bad_presence', reason: error });
    return;
  }

  const result = {};
  for (const contact of message.contacts) {
    result[contact] = users.has(contact);
  }

  send(ws, {
    v: 1,
    type: 'presence',
    contacts: result,
    serverTime: new Date().toISOString()
  });
}

const httpServer = http.createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, {
      'content-type': 'application/json',
      'cache-control': 'no-store'
    });
    res.end(JSON.stringify({ ok: true, time: new Date().toISOString() }));
    return;
  }

  res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
  res.end('Not found');
});

const wss = new WebSocketServer({
  server: httpServer,
  maxPayload: config.maxPayloadBytes,
  perMessageDeflate: false
});

wss.on('connection', (ws, request) => {
  const state = {
    authenticated: false,
    connectionId: crypto.randomUUID(),
    userId: null,
    deviceId: null,
    identityPublicKey: null,
    limiter: new SlidingWindowRateLimiter(config.rateLimitMessages, config.rateLimitWindowMs),
    remoteAddress: request.socket.remoteAddress
  };

  ws.on('message', (raw, isBinary) => {
    if (!state.limiter.allow()) {
      closeWithError(ws, 1008, 'Przekroczono limit liczby pakietow.');
      return;
    }

    if (isBinary) {
      closeWithError(ws, 1003, 'Serwer przyjmuje tylko JSON tekstowy.');
      return;
    }

    const parsed = safeJsonParse(raw.toString('utf8'));
    if (!parsed.ok) {
      closeWithError(ws, 1007, parsed.error);
      return;
    }

    const message = parsed.value;
    if (!state.authenticated) {
      handleHello(ws, state, message);
      return;
    }

    switch (message.type) {
      case 'relay':
        handleRelay(ws, state, message);
        break;
      case 'signal':
        handleSignal(ws, state, message);
        break;
      case 'presence_query':
        handlePresenceQuery(ws, message);
        break;
      case 'ping':
        send(ws, { v: 1, type: 'pong', serverTime: new Date().toISOString() });
        break;
      default:
        send(ws, { v: 1, type: 'error', code: 'unknown_type', reason: 'Nieznany typ pakietu.' });
    }
  });

  ws.on('close', () => {
    unregisterClient(state);
    audit('Rozlaczono klienta', { userId: state.userId, deviceId: state.deviceId });
  });

  ws.on('error', () => {
    unregisterClient(state);
  });
});

const heartbeat = setInterval(() => {
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.ping();
    }
  }
}, 30_000);

function shutdown(signal) {
  audit('Zamykanie serwera', { signal });
  clearInterval(heartbeat);
  for (const client of wss.clients) {
    client.close(1001, 'Server shutdown');
  }
  httpServer.close(() => process.exit(0));
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

httpServer.listen(config.port, config.host, () => {
  console.info(`Secure relay listening on ${config.host}:${config.port}`);
});
