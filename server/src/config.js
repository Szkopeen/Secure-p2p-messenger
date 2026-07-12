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

export const config = Object.freeze({
  host: process.env.HOST || '0.0.0.0',
  port: readInt('PORT', 8443, 1, 65535),
  relayToken: process.env.RELAY_TOKEN || '',
  maxPayloadBytes: readInt('MAX_PAYLOAD_BYTES', 16 * 1024 * 1024, 1024, 64 * 1024 * 1024),
  offlineQueueTtlMs: readInt('OFFLINE_QUEUE_TTL_MS', 7 * 24 * 60 * 60 * 1000, 60_000, 30 * 24 * 60 * 60 * 1000),
  offlineQueueMaxPerUser: readInt('OFFLINE_QUEUE_MAX_PER_USER', 200, 1, 2000),
  profileAvatarMaxBytes: readInt('PROFILE_AVATAR_MAX_BYTES', 1024 * 1024, 1024, 1024 * 1024),
  offlineQueueFile: process.env.OFFLINE_QUEUE_FILE || './data/offline-queue.json',
  publicProfilesFile: process.env.PUBLIC_PROFILES_FILE || './data/public-profiles.json',
  publicDirectoryFile: process.env.PUBLIC_DIRECTORY_FILE || './data/public-directory.json',
  updateManifestFile: process.env.UPDATE_MANIFEST_FILE || './updates/manifest.json',
  updateFilesDir: process.env.UPDATE_FILES_DIR || './updates/files',
  rateLimitMessages: readInt('RATE_LIMIT_MESSAGES', 80, 1, 500),
  rateLimitWindowMs: readInt('RATE_LIMIT_WINDOW_MS', 10_000, 1000, 60_000),
  maxConnectionsPerUser: readInt('MAX_CONNECTIONS_PER_USER', 4, 1, 20),
  securityLogs: readBool('SECURITY_LOGS', false)
});

if (config.relayToken.length < 32) {
  throw new Error('RELAY_TOKEN musi miec minimum 32 znaki losowego sekretu.');
}
