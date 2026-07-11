const SAFE_ID = /^[a-zA-Z0-9_.:@-]{3,128}$/;
const MESSAGE_ID = /^[a-zA-Z0-9_.:@-]{8,160}$/;
const SIGNAL_TYPES = new Set([
  'crypto-handshake-init',
  'crypto-handshake-accept',
  'webrtc-offer',
  'webrtc-answer',
  'webrtc-candidate'
]);

export function safeJsonParse(data) {
  if (typeof data !== 'string') {
    return { ok: false, error: 'Oczekiwano tekstowego JSON.' };
  }

  try {
    const parsed = JSON.parse(data);
    return { ok: true, value: parsed };
  } catch {
    return { ok: false, error: 'Niepoprawny JSON.' };
  }
}

export function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isSafeId(value) {
  return typeof value === 'string' && SAFE_ID.test(value);
}

function isMessageId(value) {
  return typeof value === 'string' && MESSAGE_ID.test(value);
}

export function validateHello(message) {
  if (!isObject(message) || message.v !== 1 || message.type !== 'hello') {
    return 'Pierwszy pakiet musi byc hello v1.';
  }
  if (!isSafeId(message.userId)) return 'Niepoprawny userId.';
  if (!isSafeId(message.deviceId)) return 'Niepoprawny deviceId.';
  if (typeof message.relayToken !== 'string') return 'Brak relayToken.';
  if (typeof message.identityPublicKey !== 'string' || message.identityPublicKey.length > 256) {
    return 'Niepoprawny identityPublicKey.';
  }
  return null;
}

export function validateRelay(message) {
  if (!isObject(message) || message.v !== 1 || message.type !== 'relay') {
    return 'Niepoprawny pakiet relay.';
  }
  if (!isMessageId(message.id)) return 'Niepoprawne id pakietu.';
  if (!isSafeId(message.to)) return 'Niepoprawny adresat.';
  if (!isObject(message.payload)) return 'Relay wymaga obiektu payload.';
  if (message.payload.protocol !== 'secure-p2p-e2ee/v1') {
    return 'Relay przyjmuje tylko pakiety E2EE v1.';
  }
  return null;
}

export function validateSignal(message) {
  if (!isObject(message) || message.v !== 1 || message.type !== 'signal') {
    return 'Niepoprawny pakiet signal.';
  }
  if (!isMessageId(message.id)) return 'Niepoprawne id pakietu.';
  if (!isSafeId(message.to)) return 'Niepoprawny adresat.';
  if (typeof message.signalType !== 'string' || !SIGNAL_TYPES.has(message.signalType)) {
    return 'Niepoprawny typ sygnalizacji.';
  }
  if (!isObject(message.payload)) return 'Signal wymaga obiektu payload.';
  return null;
}

export function validatePresenceQuery(message) {
  if (!isObject(message) || message.v !== 1 || message.type !== 'presence_query') {
    return 'Niepoprawny pakiet presence_query.';
  }
  if (!Array.isArray(message.contacts) || message.contacts.length > 200) {
    return 'Lista kontaktow jest niepoprawna.';
  }
  for (const contact of message.contacts) {
    if (!isSafeId(contact)) return 'Lista kontaktow zawiera niepoprawny identyfikator.';
  }
  return null;
}
