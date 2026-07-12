#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const SERVER_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SAFE_USER_ID = /^[a-zA-Z0-9_.:@-]{3,128}$/;

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function loadDotEnv(filePath) {
  if (!fs.existsSync(filePath)) return {};
  const result = {};
  const lines = fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const separator = trimmed.indexOf('=');
    if (separator <= 0) continue;
    const key = trimmed.slice(0, separator).trim();
    let value = trimmed.slice(separator + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}

const dotEnv = loadDotEnv(path.join(SERVER_DIR, '.env'));

function setting(name, fallback) {
  return process.env[name] || dotEnv[name] || fallback;
}

function resolveServerPath(value) {
  return path.isAbsolute(value) ? value : path.resolve(SERVER_DIR, value);
}

const dataFiles = {
  knownUsers: {
    label: 'znani uzytkownicy',
    path: resolveServerPath(setting('KNOWN_USERS_FILE', './data/known-users.json')),
    empty: { v: 1, users: {} }
  },
  profiles: {
    label: 'profile publiczne',
    path: resolveServerPath(setting('PUBLIC_PROFILES_FILE', './data/public-profiles.json')),
    empty: { v: 1, profiles: {} }
  },
  directory: {
    label: 'publiczna lista',
    path: resolveServerPath(setting('PUBLIC_DIRECTORY_FILE', './data/public-directory.json')),
    empty: { v: 1, users: {} }
  },
  offlineQueue: {
    label: 'kolejki offline',
    path: resolveServerPath(setting('OFFLINE_QUEUE_FILE', './data/offline-queue.json')),
    empty: { v: 1, queues: {} }
  },
  bannedUsers: {
    label: 'banlista',
    path: resolveServerPath(setting('BANNED_USERS_FILE', './data/banned-users.json')),
    empty: { v: 1, users: [] }
  }
};

function readJson(definition) {
  if (!fs.existsSync(definition.path)) return clone(definition.empty);
  const raw = fs.readFileSync(definition.path, 'utf8');
  if (!raw.trim()) return clone(definition.empty);
  return JSON.parse(raw);
}

function normalizeState(state) {
  if (!state.knownUsers || state.knownUsers.v !== 1 || !state.knownUsers.users) {
    state.knownUsers = clone(dataFiles.knownUsers.empty);
  }
  if (!state.profiles || state.profiles.v !== 1 || !state.profiles.profiles) {
    state.profiles = clone(dataFiles.profiles.empty);
  }
  if (!state.directory || state.directory.v !== 1 || !state.directory.users) {
    state.directory = clone(dataFiles.directory.empty);
  }
  if (!state.offlineQueue || state.offlineQueue.v !== 1 || !state.offlineQueue.queues) {
    state.offlineQueue = clone(dataFiles.offlineQueue.empty);
  }
  if (!state.bannedUsers || state.bannedUsers.v !== 1 || !Array.isArray(state.bannedUsers.users)) {
    state.bannedUsers = clone(dataFiles.bannedUsers.empty);
  }
  return state;
}

function readState() {
  return normalizeState({
    knownUsers: readJson(dataFiles.knownUsers),
    profiles: readJson(dataFiles.profiles),
    directory: readJson(dataFiles.directory),
    offlineQueue: readJson(dataFiles.offlineQueue),
    bannedUsers: readJson(dataFiles.bannedUsers)
  });
}

function backupExistingFiles(changedKeys) {
  const timestamp = new Date().toISOString().replaceAll(':', '-').replaceAll('.', '-');
  const backupDir = path.join(SERVER_DIR, 'data', 'admin-backups', timestamp);
  let copied = 0;
  for (const key of changedKeys) {
    const definition = dataFiles[key];
    if (!definition || !fs.existsSync(definition.path)) continue;
    fs.mkdirSync(backupDir, { recursive: true });
    fs.copyFileSync(definition.path, path.join(backupDir, path.basename(definition.path)));
    copied += 1;
  }
  return copied > 0 ? backupDir : null;
}

function writeJson(definition, value) {
  fs.mkdirSync(path.dirname(definition.path), { recursive: true });
  const payload = {
    ...value,
    v: 1,
    savedAt: new Date().toISOString()
  };
  fs.writeFileSync(definition.path, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function writeState(state, changedKeys) {
  if (changedKeys.size === 0) return null;
  const backupDir = backupExistingFiles(changedKeys);
  for (const key of changedKeys) {
    writeJson(dataFiles[key], state[key]);
  }
  return backupDir;
}

function envelopeForQueueItem(item) {
  if (!item || typeof item !== 'object') return null;
  if (item.envelope && typeof item.envelope === 'object') return item.envelope;
  return item;
}

function collectUserIds(state) {
  const ids = new Set();
  for (const id of Object.keys(state.knownUsers.users)) ids.add(id);
  for (const id of Object.keys(state.profiles.profiles)) ids.add(id);
  for (const id of Object.keys(state.directory.users)) ids.add(id);
  for (const id of state.bannedUsers.users) ids.add(id);

  for (const [queueOwner, items] of Object.entries(state.offlineQueue.queues)) {
    ids.add(queueOwner);
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      const envelope = envelopeForQueueItem(item);
      if (typeof envelope?.from === 'string') ids.add(envelope.from);
      if (typeof envelope?.to === 'string') ids.add(envelope.to);
    }
  }

  return Array.from(ids).sort((left, right) => left.localeCompare(right));
}

function summarizeUser(state, userId) {
  const known = state.knownUsers.users[userId] || null;
  const profile = state.profiles.profiles[userId] || null;
  const directory = state.directory.users[userId] || null;
  const queueIn = Array.isArray(state.offlineQueue.queues[userId])
    ? state.offlineQueue.queues[userId].length
    : 0;
  let queueOut = 0;
  for (const items of Object.values(state.offlineQueue.queues)) {
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      const envelope = envelopeForQueueItem(item);
      if (envelope?.from === userId) queueOut += 1;
    }
  }

  return {
    userId,
    displayName: directory?.displayName || null,
    known: Boolean(known),
    directory: Boolean(directory),
    profile: Boolean(profile),
    banned: state.bannedUsers.users.includes(userId),
    queuedIn: queueIn,
    queuedOut: queueOut,
    firstSeenAt: known?.firstSeenAt || null,
    lastSeenAt: known?.lastSeenAt || null,
    lastDeviceId: known?.lastDeviceId || null,
    identityPublicKey: known?.identityPublicKey || directory?.identityPublicKey || null
  };
}

function printList(state) {
  const userIds = collectUserIds(state);
  if (userIds.length === 0) {
    console.log('Brak zapisanych uzytkownikow w danych relay.');
    console.log('Uwaga: aktywni online uzytkownicy pojawia sie tutaj po ponownym polaczeniu z relay po tej aktualizacji.');
    return;
  }

  console.log(`Znaleziono zapisanych uzytkownikow: ${userIds.length}`);
  for (const userId of userIds) {
    const user = summarizeUser(state, userId);
    const name = user.displayName ? `"${user.displayName}"` : '-';
    const lastSeen = user.lastSeenAt || '-';
    console.log(
      `${user.userId} | nazwa=${name} | known=${user.known ? 'tak' : 'nie'} | katalog=${user.directory ? 'tak' : 'nie'} | profil=${user.profile ? 'tak' : 'nie'} | banned=${user.banned ? 'tak' : 'nie'} | offline_in=${user.queuedIn} | offline_out=${user.queuedOut} | last_seen=${lastSeen}`
    );
  }
}

function printShow(state, userId) {
  const summary = summarizeUser(state, userId);
  console.log(JSON.stringify(summary, null, 2));
}

function assertUserId(userId) {
  if (!SAFE_USER_ID.test(userId || '')) {
    throw new Error('Podaj poprawny userId, np. npm run admin:users -- show USER_ID');
  }
}

function ensureYes(flags, action) {
  if (flags.has('--yes')) return true;
  console.log(`Tryb testowy: ${action} nie zostalo zapisane. Dodaj --yes, zeby wykonac operacje.`);
  return false;
}

function deleteUser(state, userId, flags) {
  assertUserId(userId);
  const changed = new Set();

  if (state.knownUsers.users[userId]) {
    delete state.knownUsers.users[userId];
    changed.add('knownUsers');
  }
  if (state.profiles.profiles[userId]) {
    delete state.profiles.profiles[userId];
    changed.add('profiles');
  }
  if (state.directory.users[userId]) {
    delete state.directory.users[userId];
    changed.add('directory');
  }

  let changedQueue = false;
  for (const [queueOwner, items] of Object.entries(state.offlineQueue.queues)) {
    if (queueOwner === userId) {
      delete state.offlineQueue.queues[queueOwner];
      changedQueue = true;
      continue;
    }
    if (!Array.isArray(items)) continue;
    const filtered = items.filter((item) => {
      const envelope = envelopeForQueueItem(item);
      return envelope?.from !== userId && envelope?.to !== userId;
    });
    if (filtered.length !== items.length) {
      state.offlineQueue.queues[queueOwner] = filtered;
      changedQueue = true;
    }
  }
  if (changedQueue) changed.add('offlineQueue');

  if (!flags.has('--no-ban') && !state.bannedUsers.users.includes(userId)) {
    state.bannedUsers.users.push(userId);
    state.bannedUsers.users.sort((left, right) => left.localeCompare(right));
    changed.add('bannedUsers');
  }

  console.log('Podsumowanie przed usunieciem:');
  console.log(JSON.stringify(summarizeUser(readState(), userId), null, 2));
  if (!ensureYes(flags, `usuniecie ${userId}`)) return;

  const backupDir = writeState(state, changed);
  console.log(`Usunieto dane userId: ${userId}`);
  if (!flags.has('--no-ban')) console.log('UserId dodany do banlisty.');
  if (backupDir) console.log(`Backup: ${backupDir}`);
}

function banUser(state, userId, flags) {
  assertUserId(userId);
  if (!state.bannedUsers.users.includes(userId)) {
    state.bannedUsers.users.push(userId);
    state.bannedUsers.users.sort((left, right) => left.localeCompare(right));
  }
  if (!ensureYes(flags, `blokada ${userId}`)) return;
  const backupDir = writeState(state, new Set(['bannedUsers']));
  console.log(`Zablokowano userId: ${userId}`);
  if (backupDir) console.log(`Backup: ${backupDir}`);
}

function unbanUser(state, userId, flags) {
  assertUserId(userId);
  const before = state.bannedUsers.users.length;
  state.bannedUsers.users = state.bannedUsers.users.filter((id) => id !== userId);
  if (!ensureYes(flags, `odblokowanie ${userId}`)) return;
  const changed = before === state.bannedUsers.users.length ? new Set() : new Set(['bannedUsers']);
  const backupDir = writeState(state, changed);
  console.log(`Odblokowano userId: ${userId}`);
  if (backupDir) console.log(`Backup: ${backupDir}`);
}

function printHelp() {
  console.log(`Uzycie:
  npm run admin:users -- list
  npm run admin:users -- show USER_ID
  npm run admin:users -- delete USER_ID --yes
  npm run admin:users -- delete USER_ID --yes --no-ban
  npm run admin:users -- ban USER_ID --yes
  npm run admin:users -- unban USER_ID --yes

Pliki danych:
  known users:   ${dataFiles.knownUsers.path}
  profiles:      ${dataFiles.profiles.path}
  directory:     ${dataFiles.directory.path}
  offline queue: ${dataFiles.offlineQueue.path}
  banned users:  ${dataFiles.bannedUsers.path}`);
}

function main() {
  const [command, userId, ...rest] = process.argv.slice(2);
  const flags = new Set(rest);
  const state = readState();

  switch (command) {
    case 'list':
      printList(state);
      break;
    case 'show':
      assertUserId(userId);
      printShow(state, userId);
      break;
    case 'delete':
      deleteUser(state, userId, flags);
      break;
    case 'ban':
      banUser(state, userId, flags);
      break;
    case 'unban':
      unbanUser(state, userId, flags);
      break;
    case 'help':
    case '--help':
    case '-h':
    case undefined:
      printHelp();
      break;
    default:
      throw new Error(`Nieznana komenda: ${command}`);
  }
}

try {
  main();
} catch (error) {
  console.error(error.message || String(error));
  process.exit(1);
}
