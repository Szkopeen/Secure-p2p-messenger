#!/usr/bin/env node
import 'dotenv/config';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const platforms = ['windows', 'linux', 'android'];

function usage() {
  return `
Uzycie:
  node scripts/publish-update.js --version 1.0.1 --build 2 --windows ./secure-p2p-windows.zip --linux ./secure-p2p-linux.zip --android ./secure-p2p-android.apk --notes "Opis zmian"

Opcje:
  --version      Wersja widoczna w aplikacji, np. 1.0.1
  --build        Numer builda. Musi rosnac przy kazdej aktualizacji.
  --windows      Sciezka do paczki ZIP dla Windows.
  --linux        Sciezka do paczki ZIP dla Linuxa.
  --android      Sciezka do APK dla Androida.
  --notes        Opis zmian. Mozesz podac kilka razy.
  --manifest     Sciezka manifestu. Domyslnie UPDATE_MANIFEST_FILE albo ./updates/manifest.json.
  --files-dir    Katalog plikow. Domyslnie UPDATE_FILES_DIR albo ./updates/files.
`.trim();
}

function readArgs(argv) {
  const args = { notes: [] };
  for (let index = 0; index < argv.length; index++) {
    const key = argv[index];
    if (!key.startsWith('--')) {
      throw new Error(`Nieznany argument: ${key}`);
    }
    const name = key.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) {
      throw new Error(`Brak wartosci dla --${name}`);
    }
    index++;
    if (name === 'notes') {
      args.notes.push(value);
    } else {
      args[name] = value;
    }
  }
  return args;
}

function requireText(args, key) {
  const value = args[key]?.trim();
  if (!value) throw new Error(`Brak wymaganego --${key}`);
  return value;
}

function sha256File(filePath) {
  const hash = crypto.createHash('sha256');
  const data = fs.readFileSync(filePath);
  hash.update(data);
  return hash.digest('hex');
}

function copyArtifact(filesDir, sourcePath) {
  const absoluteSource = path.resolve(sourcePath);
  if (!fs.existsSync(absoluteSource)) {
    throw new Error(`Plik nie istnieje: ${absoluteSource}`);
  }
  const stat = fs.statSync(absoluteSource);
  if (!stat.isFile()) {
    throw new Error(`To nie jest plik: ${absoluteSource}`);
  }

  fs.mkdirSync(filesDir, { recursive: true });
  const fileName = path.basename(absoluteSource);
  const destination = path.join(filesDir, fileName);
  fs.copyFileSync(absoluteSource, destination);

  return {
    file: fileName,
    sha256: sha256File(destination),
    size: fs.statSync(destination).size
  };
}

function main() {
  const args = readArgs(process.argv.slice(2));
  const version = requireText(args, 'version');
  const buildNumber = Number.parseInt(requireText(args, 'build'), 10);
  if (!Number.isInteger(buildNumber) || buildNumber < 1) {
    throw new Error('--build musi byc dodatnia liczba calkowita.');
  }

  const manifestFile = path.resolve(
    args.manifest || process.env.UPDATE_MANIFEST_FILE || './updates/manifest.json'
  );
  const filesDir = path.resolve(
    args['files-dir'] || process.env.UPDATE_FILES_DIR || './updates/files'
  );

  const artifacts = {};
  for (const platform of platforms) {
    if (args[platform]) {
      artifacts[platform] = copyArtifact(filesDir, args[platform]);
    }
  }
  if (Object.keys(artifacts).length === 0) {
    throw new Error('Podaj przynajmniej jedna paczke: --windows, --linux albo --android.');
  }

  const manifest = {
    v: 1,
    latest: {
      version,
      buildNumber,
      releasedAt: new Date().toISOString(),
      notes: args.notes.length > 0 ? args.notes : ['Nowa wersja aplikacji.'],
      artifacts
    }
  };

  fs.mkdirSync(path.dirname(manifestFile), { recursive: true });
  fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');

  console.log(`Zapisano manifest: ${manifestFile}`);
  console.log(`Pliki aktualizacji: ${filesDir}`);
  for (const [platform, artifact] of Object.entries(artifacts)) {
    console.log(`${platform}: ${artifact.file} sha256=${artifact.sha256}`);
  }
}

try {
  main();
} catch (error) {
  console.error(error.message);
  console.error('');
  console.error(usage());
  process.exit(1);
}
