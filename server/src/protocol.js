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

export function validateRelay(message, senderUserId = null) {
  if (!isObject(message) || message.v !== 1 || message.type !== 'relay') {
    return 'Niepoprawny pakiet relay.';
  }
  if (!isMessageId(message.id)) return 'Niepoprawne id pakietu.';
  if (!isSafeId(message.to)) return 'Niepoprawny adresat.';
  if (!isObject(message.payload)) return 'Relay wymaga obiektu payload.';

  if (message.payload.protocol === 'secure-p2p-e2ee/v1') {
    return null;
  }

  if (message.payload.protocol === 'secure-p2p-device-sync/v1') {
    if (senderUserId !== null && message.to !== senderUserId) {
      return 'Synchronizacja urzadzen moze isc tylko do wlasnego konta.';
    }
    return null;
  }

  return 'Relay przyjmuje tylko pakiety E2EE v1 albo device-sync v1.';
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

export function validateDirectoryUpdate(message) {
  if (!isObject(message) || message.v !== 1 || message.type !== 'directory_update') {
    return 'Niepoprawny pakiet directory_update.';
  }
  if (typeof message.enabled !== 'boolean') return 'Brak pola enabled.';
  if (message.displayName !== undefined && message.displayName !== null) {
    if (typeof message.displayName !== 'string' || message.displayName.length > 80) {
      return 'Niepoprawna nazwa publiczna.';
    }
  }
  if (typeof message.identityPublicKey !== 'string' || message.identityPublicKey.length > 256) {
    return 'Niepoprawny klucz publiczny.';
  }
  return null;
}

export function validateDirectoryQuery(message) {
  if (!isObject(message) || message.v !== 1 || message.type !== 'directory_query') {
    return 'Niepoprawny pakiet directory_query.';
  }
  return null;
}

export function validateContactRequest(message) {
  if (!isObject(message) || message.v !== 1 || message.type !== 'contact_request') {
    return 'Niepoprawny pakiet contact_request.';
  }
  if (!isMessageId(message.id)) return 'Niepoprawne id zaproszenia.';
  if (!isSafeId(message.to)) return 'Niepoprawny adresat.';
  if (message.displayName !== undefined && message.displayName !== null) {
    if (typeof message.displayName !== 'string' || message.displayName.length > 80) {
      return 'Niepoprawna nazwa wyswietlana.';
    }
  }
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

export function validateProfileQuery(message) {
  if (!isObject(message) || message.v !== 1 || message.type !== 'profile_query') {
    return 'Niepoprawny pakiet profile_query.';
  }
  if (!Array.isArray(message.contacts) || message.contacts.length > 200) {
    return 'Lista kontaktow jest niepoprawna.';
  }
  for (const contact of message.contacts) {
    if (!isSafeId(contact)) return 'Lista kontaktow zawiera niepoprawny identyfikator.';
  }
  return null;
}

export function validateProfileUpdate(message, maxAvatarBytes) {
  if (!isObject(message) || message.v !== 1 || message.type !== 'profile_update') {
    return 'Niepoprawny pakiet profile_update.';
  }
  const profile = message.profile;
  if (!isObject(profile) || profile.v !== 1) return 'Niepoprawny profil.';
  if (profile.avatarBytes !== undefined && profile.avatarBytes !== null) {
    if (typeof profile.avatarBytes !== 'string') return 'Niepoprawny avatar.';
    if (Buffer.byteLength(profile.avatarBytes, 'base64') > maxAvatarBytes) {
      return 'Avatar jest za duzy.';
    }
  }
  if (profile.avatarMimeType !== undefined && profile.avatarMimeType !== null) {
    if (typeof profile.avatarMimeType !== 'string') return 'Niepoprawny avatarMimeType.';
    if (!['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/bmp'].includes(profile.avatarMimeType)) {
      return 'Nieobslugiwany typ avatara.';
    }
  }
  if (profile.updatedAt !== undefined && profile.updatedAt !== null) {
    if (typeof profile.updatedAt !== 'string' || Number.isNaN(Date.parse(profile.updatedAt))) {
      return 'Niepoprawny updatedAt profilu.';
    }
  }
  return null;
}
