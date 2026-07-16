# Serwer API v2

Ten katalog zawiera serwer Node.js dla Secure P2P Messenger. Serwer obsluguje konta, sesje, rozmowy, WebSocket, podpisane aktualizacje, limity bezpieczenstwa i lokalny log key transparency.

## Wymagania

- Node.js 24 lub nowszy.
- npm.
- Serwer Ubuntu dla wdrozenia produkcyjnego.
- Reverse proxy z HTTPS/WSS.

## Start lokalny

```bash
npm install
cp .env.example .env
npm test
npm start
```

Domyslnie serwer nasluchuje na `127.0.0.1:8443`. W produkcji nie wystawiaj go bezposrednio do internetu; uzyj reverse proxy.

## Najwazniejsze zmienne

```env
HOST=127.0.0.1
PORT=8443
REGISTRATION_MODE=invite
ADMIN_TOKEN=<losowy-sekret-minimum-32-znaki>
TRUSTED_PROXIES=127.0.0.1,::1,::ffff:127.0.0.1
METRICS_ALLOWED_IPS=127.0.0.1,::1,::ffff:127.0.0.1
V2_DATA_DIR=/var/lib/secure-chat/data-v2
UPDATE_MANIFEST_FILE=/var/lib/secure-chat/updates/manifest.json
UPDATE_FILES_DIR=/var/lib/secure-chat/updates/files
```

`ADMIN_TOKEN` sluzy tylko do operacji administracyjnych, np. tworzenia zaproszen. Nie commituj go i nie uzywaj jako hasla konta.

## Rejestracja

`REGISTRATION_MODE` moze miec wartosci:

- `disabled` - rejestracja wylaczona,
- `invite` - konto mozna utworzyc tylko z zaproszeniem,
- `open` - rejestracja otwarta, przydatna tylko w testach.

## Aktualizacje

Serwer publikuje:

- `GET /updates/manifest.json`,
- `GET /updates/files/<plik>`.

Manifest musi byc podpisany kluczem Ed25519. Prywatny klucz podpisu trzymaj poza repozytorium.

```bash
npm run generate-update-key -- --out ./secrets/update-signing-key.pem
npm run publish-update -- --version 1.0.1 --build 2 --windows ./build.zip --notes "Opis zmian" --signing-key ./secrets/update-signing-key.pem --key-id <key-id>
```

## Kontrole

```bash
npm run check
npm test
```

Testy obejmuja m.in. limity, walidacje kopert kluczy, WebSocket pre-auth, aktualizacje, metryki i wybrane scenariusze regresji bezpieczenstwa.

## Backup

Dane produkcyjne znajduja sie w `V2_DATA_DIR` i katalogu aktualizacji. Backup powinien obejmowac:

- katalog danych v2,
- katalog `updates`,
- prywatny klucz podpisu aktualizacji,
- konfiguracje `.env` przechowywana poza repozytorium.

Backup musi byc szyfrowany i testowany przez probne odtworzenie.
