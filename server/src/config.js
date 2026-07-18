import process from 'node:process';

function readInt(name, fallback, min, max) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number.parseInt(raw, 10);
  if (!Number.isFinite(value) || value < min || value > max) {
    throw new Error(`${name} musi byc liczba z zakresu ${min}-${max}`);
  }
  return value;
}

function readBool(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  return ['1', 'true', 'yes', 'tak'].includes(raw.toLowerCase());
}

function readList(name, fallback = []) {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  return raw.split(',').map((value) => value.trim()).filter(Boolean);
}

const MAX_MESSAGE_ENVELOPE_BYTES = 32 * 1024 * 1024;
const MAX_WEBSOCKET_PAYLOAD_BYTES = MAX_MESSAGE_ENVELOPE_BYTES;

export const config = Object.freeze({
  host: process.env.HOST || '127.0.0.1',
  port: readInt('PORT', 8443, 1, 65535),
  adminToken: process.env.ADMIN_TOKEN || '',
  maxPayloadBytes: readInt('MAX_PAYLOAD_BYTES', MAX_MESSAGE_ENVELOPE_BYTES, 1024, MAX_WEBSOCKET_PAYLOAD_BYTES),
  v2DataDir: process.env.V2_DATA_DIR || './data-v2',
  messageMaxBytes: readInt('MESSAGE_MAX_BYTES', MAX_MESSAGE_ENVELOPE_BYTES, 16 * 1024, MAX_MESSAGE_ENVELOPE_BYTES),
  messagesPerConversation: readInt('MESSAGES_PER_CONVERSATION', 50_000, 100, 1_000_000),
  conversationQuotaBytes: readInt('CONVERSATION_QUOTA_BYTES', 256 * 1024 * 1024, 1024 * 1024, 10 * 1024 * 1024 * 1024),
  accountQuotaBytes: readInt('ACCOUNT_QUOTA_BYTES', 1024 * 1024 * 1024, 1024 * 1024, 100 * 1024 * 1024 * 1024),
  instanceQuotaBytes: readInt('INSTANCE_QUOTA_BYTES', 10 * 1024 * 1024 * 1024, 1024 * 1024, 1024 * 1024 * 1024 * 1024),
  dailyAccountQuotaBytes: readInt('DAILY_ACCOUNT_QUOTA_BYTES', 100 * 1024 * 1024, 1024 * 1024, 10 * 1024 * 1024 * 1024),
  minFreeDiskBytes: readInt('MIN_FREE_DISK_BYTES', 512 * 1024 * 1024, 0, 100 * 1024 * 1024 * 1024),
  sessionTtlHours: readInt('SESSION_TTL_HOURS', 72, 1, 24 * 30),
  sessionIdleTtlHours: readInt('SESSION_IDLE_TTL_HOURS', 24, 1, 24 * 30),
  wsPreAuthTimeoutMs: readInt('WS_PREAUTH_TIMEOUT_MS', 5000, 1000, 30000),
  wsPreAuthMaxGlobal: readInt('WS_PREAUTH_MAX_GLOBAL', 500, 1, 100000),
  wsPreAuthMaxPerIp: readInt('WS_PREAUTH_MAX_PER_IP', 8, 1, 1000),
  wsPreAuthMaxPerWindow: readInt('WS_PREAUTH_MAX_PER_WINDOW', 30, 1, 10000),
  wsPreAuthWindowMs: readInt('WS_PREAUTH_WINDOW_MS', 10000, 1000, 60000),
  wsPreAuthMaxUniqueIps: readInt('WS_PREAUTH_MAX_UNIQUE_IPS', 10000, 100, 1000000),
  metricsStorageCacheSeconds: readInt('METRICS_STORAGE_CACHE_SECONDS', 15, 1, 300),
  metricsAllowedIps: readList('METRICS_ALLOWED_IPS', ['127.0.0.1', '::1', '::ffff:127.0.0.1']),
  updateManifestFile: process.env.UPDATE_MANIFEST_FILE || './updates/manifest.json',
  updateFilesDir: process.env.UPDATE_FILES_DIR || './updates/files',
  trustedProxies: readList('TRUSTED_PROXIES', ['127.0.0.1', '::1', '::ffff:127.0.0.1']),
  registrationMode:
    process.env.REGISTRATION_MODE?.trim().toLowerCase() || 'disabled'
});

if (!['disabled', 'invite', 'open'].includes(config.registrationMode)) {
  throw new Error('REGISTRATION_MODE musi miec wartosc disabled, invite albo open.');
}

if (config.adminToken && config.adminToken.length < 32) {
  throw new Error('ADMIN_TOKEN musi miec minimum 32 znaki losowego sekretu albo byc pusty.');
}
