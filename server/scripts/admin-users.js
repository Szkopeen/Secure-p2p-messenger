import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const SAFE_ID = /^[a-zA-Z0-9_.:@-]{3,128}$/;

loadDotEnv();

const files = {
  offlineQueue: process.env.OFFLINE_QUEUE_FILE || './data/offline-queue.json',
  profiles: process.env.PUBLIC_PROFILES_FILE || './data/public-profiles.json',
  directory: process.env.PUBLIC_DIRECTORY_FILE || './data/public-directory.json',
  bannedUsers: process.env.BANNED_USERS_FILE || './data/banned-users.json'
};

function loadDotEnv(file = '.env') {
  if (!fs.existsSync(file)) return;
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!process.env[key]) process.env[key] = value;
  }
}

const command = process.argv[2];
const userId = process.argv[3];
const flags = new Set(process.argv.slice(4));
const confirmed = flags.has('--yes') || flags.has('-y');

function usage(exitCode = 0) {
  console.log(`Uzycie:
  npm run admin:users -- list
  npm run admin:users -- show <userId>
  npm run admin:users -- delete <userId> --yes
  npm run admin:users -- ban <userId> --yes
  npm run admin:users -- unban <userId> --yes

Domyslnie delete usuwa dane relay i dodaje userId do banlisty.
Opcje:
  --no-ban   przy delete usuwa dane, ale nie blokuje ponownego polaczenia
  --yes      wykonuje zmiany; bez tego narzedzie tylko pokazuje co zrobi`);
  process.exit(exitCode);
}

function assertUserId(value) {
  if (!SAFE_ID.test(value || '')) {
    throw new Error('Niepoprawny userId. Dozwolone: litery, cyfry, _, ., :, @, -; dlugosc 3-128.');
  }
}

function readJson(file, fallback) {
  if (!fs.existsSync(file)) return structuredClone(fallback);
  const raw = fs.readFileSync(file, 'utf8').trim();
  if (!raw) return structuredClone(fallback);
  return JSON.parse(raw);
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function backupExistingFiles() {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupRoot = path.join('data', 'admin-backups', timestamp);
  let count = 0;

  for (const file of Object.values(files)) {
    if (!fs.existsSync(file)) continue;
    const target = path.join(backupRoot, path.basename(file));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(file, target);
    count += 1;
  }

  return count > 0 ? backupRoot : null;
}

function loadState() {
  const offlineQueue = readJson(files.offlineQueue, { v: 1, queues: {} });
  const profiles = readJson(files.profiles, { v: 1, profiles: {} });
  const directory = readJson(files.directory, { v: 1, users: {} });
  const bannedUsers = readJson(files.bannedUsers, { v: 1, users: [] });

  offlineQueue.queues ||= {};
  profiles.profiles ||= {};
  directory.users ||= {};
  if (!Array.isArray(bannedUsers.users)) bannedUsers.users = [];

  return { offlineQueue, profiles, directory, bannedUsers };
}

function saveState(state) {
  const savedAt = new Date().toISOString();
  writeJson(files.offlineQueue, { v: 1, savedAt, queues: state.offlineQueue.queues });
  writeJson(files.profiles, { v: 1, savedAt, profiles: state.profiles.profiles });
  writeJson(files.directory, { v: 1, savedAt, users: state.directory.users });
  writeJson(files.bannedUsers, {
    v: 1,
    savedAt,
    users: [...new Set(state.bannedUsers.users)].sort()
  });
}

function collectUserIds(state) {
  const ids = new Set([
    ...Object.keys(state.offlineQueue.queues),
    ...Object.keys(state.profiles.profiles),
    ...Object.keys(state.directory.users),
    ...state.bannedUsers.users
  ]);

  for (const items of Object.values(state.offlineQueue.queues)) {
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      const envelope = item?.envelope;
      if (typeof envelope?.from === 'string') ids.add(envelope.from);
      if (typeof envelope?.to === 'string') ids.add(envelope.to);
    }
  }

  return [...ids].sort();
}

function userSummary(state, id) {
  let queuedIncoming = 0;
  let queuedOutgoing = 0;

  const ownQueue = state.offlineQueue.queues[id];
  if (Array.isArray(ownQueue)) queuedIncoming += ownQueue.length;

  for (const [queueOwner, items] of Object.entries(state.offlineQueue.queues)) {
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      const envelope = item?.envelope;
      if (queueOwner !== id && envelope?.to === id) queuedIncoming += 1;
      if (envelope?.from === id) queuedOutgoing += 1;
    }
  }

  return {
    userId: id,
    displayName: state.directory.users[id]?.displayName || null,
    inDirectory: Boolean(state.directory.users[id]),
    hasProfile: Boolean(state.profiles.profiles[id]),
    banned: state.bannedUsers.users.includes(id),
    queuedIncoming,
    queuedOutgoing
  };
}

function printSummary(summary) {
  console.log([
    summary.userId,
    summary.displayName ? `name="${summary.displayName}"` : 'name=-',
    `directory=${summary.inDirectory ? 'yes' : 'no'}`,
    `profile=${summary.hasProfile ? 'yes' : 'no'}`,
    `banned=${summary.banned ? 'yes' : 'no'}`,
    `queued_in=${summary.queuedIncoming}`,
    `queued_out=${summary.queuedOutgoing}`
  ].join(' | '));
}

function deleteUser(state, id, shouldBan) {
  const summaryBefore = userSummary(state, id);
  let removedQueuedItems = 0;

  delete state.profiles.profiles[id];
  delete state.directory.users[id];

  const ownQueue = state.offlineQueue.queues[id];
  if (Array.isArray(ownQueue)) removedQueuedItems += ownQueue.length;
  delete state.offlineQueue.queues[id];

  for (const [queueOwner, items] of Object.entries(state.offlineQueue.queues)) {
    if (!Array.isArray(items)) continue;
    const filtered = items.filter((item) => {
      const envelope = item?.envelope;
      const remove = envelope?.from === id || envelope?.to === id;
      if (remove) removedQueuedItems += 1;
      return !remove;
    });
    if (filtered.length === 0) {
      delete state.offlineQueue.queues[queueOwner];
    } else {
      state.offlineQueue.queues[queueOwner] = filtered;
    }
  }

  if (shouldBan && !state.bannedUsers.users.includes(id)) {
    state.bannedUsers.users.push(id);
  }

  return { ...summaryBefore, removedQueuedItems, willBan: shouldBan };
}

function setBan(state, id, banned) {
  const before = state.bannedUsers.users.includes(id);
  if (banned && !before) state.bannedUsers.users.push(id);
  if (!banned) state.bannedUsers.users = state.bannedUsers.users.filter((value) => value !== id);
  return { before, after: banned };
}

try {
  if (!command || command === 'help' || command === '--help' || command === '-h') usage();
  const state = loadState();

  if (command === 'list') {
    const ids = collectUserIds(state);
    if (ids.length === 0) {
      console.log('Brak zapisanych uzytkownikow w danych relay.');
      process.exit(0);
    }
    for (const id of ids) printSummary(userSummary(state, id));
    process.exit(0);
  }

  if (!userId) usage(1);
  assertUserId(userId);

  if (command === 'show') {
    printSummary(userSummary(state, userId));
    process.exit(0);
  }

  if (command === 'delete') {
    const shouldBan = !flags.has('--no-ban');
    const result = deleteUser(state, userId, shouldBan);
    console.log('Plan usuniecia:');
    printSummary(result);
    console.log(`queued_removed=${result.removedQueuedItems}`);
    console.log(`ban_after_delete=${shouldBan ? 'yes' : 'no'}`);

    if (!confirmed) {
      console.log('Tryb podgladu. Dodaj --yes, zeby wykonac zmiany.');
      process.exit(0);
    }

    const backup = backupExistingFiles();
    saveState(state);
    console.log(`Usunieto userId: ${userId}`);
    if (backup) console.log(`Backup: ${backup}`);
    process.exit(0);
  }

  if (command === 'ban' || command === 'unban') {
    const targetBan = command === 'ban';
    const result = setBan(state, userId, targetBan);
    console.log(`ban_before=${result.before ? 'yes' : 'no'}`);
    console.log(`ban_after=${result.after ? 'yes' : 'no'}`);

    if (!confirmed) {
      console.log('Tryb podgladu. Dodaj --yes, zeby wykonac zmiany.');
      process.exit(0);
    }

    const backup = backupExistingFiles();
    saveState(state);
    console.log(`${targetBan ? 'Zablokowano' : 'Odblokowano'} userId: ${userId}`);
    if (backup) console.log(`Backup: ${backup}`);
    process.exit(0);
  }

  usage(1);
} catch (error) {
  console.error(`Blad: ${error.message}`);
  process.exit(1);
}
