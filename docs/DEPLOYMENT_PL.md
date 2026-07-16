# Wdrozenie na serwerze Ubuntu

Ten dokument opisuje produkcyjne uruchomienie serwera API v2 na serwerze Ubuntu. Nie uzywaj prawdziwych sekretow ani prywatnych danych w repozytorium.

## Model wdrozenia

```text
Internet
  -> reverse proxy HTTPS/WSS
  -> 127.0.0.1:8443
  -> Node.js server
  -> /var/lib/secure-chat
```

Serwer Node.js powinien nasluchiwac lokalnie. Publiczny ruch TLS konczy reverse proxy.

## Pakiety

Zainstaluj Node.js 24+, npm oraz reverse proxy. Konkretny sposob instalacji zalezy od obrazu serwera i polityki aktualizacji systemu.

W CI albo buildzie Linuxa klienta moga byc potrzebne natywne pakiety GStreamer, poniewaz aplikacja korzysta z bibliotek audio/wideo.

## Katalogi

Przykladowy uklad:

```text
/opt/secure-chat/app
/var/lib/secure-chat/data-v2
/var/lib/secure-chat/updates/manifest.json
/var/lib/secure-chat/updates/files
/etc/secure-chat/server.env
```

`server.env` musi byc poza repozytorium i czytelny tylko dla konta uslugi.

## Konfiguracja

Minimalna konfiguracja produkcyjna:

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

`TRUSTED_PROXIES` powinno zawierac tylko adresy reverse proxy, ktorym serwer naprawde ufa. Nie dopisuj calej sieci lokalnej bez potrzeby.

## Usluga systemd

Przykladowy plik uslugi:

```ini
[Unit]
Description=Secure Chat API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/secure-chat/app/server
EnvironmentFile=/etc/secure-chat/server.env
ExecStart=/usr/bin/npm start
Restart=on-failure
RestartSec=5
User=secure-chat
Group=secure-chat
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/secure-chat

[Install]
WantedBy=multi-user.target
```

Dostosuj sciezke do `npm`, jezeli Node.js jest instalowany inaczej.

## Reverse proxy

Reverse proxy musi przekazywac:

- zwykle zadania HTTP,
- WebSocket dla API v2,
- naglowki `X-Forwarded-For` i `X-Forwarded-Proto` tylko z zaufanego proxy.

Endpoint `/metrics` powinien byc dostepny tylko administracyjnie, np. z localhosta, VPN albo zaufanej sieci monitoringu.

## Backup

Backupuj:

- `V2_DATA_DIR`,
- katalog `updates`,
- plik env z konfiguracja,
- prywatny klucz podpisu aktualizacji.

Backup szyfruj i testuj odtworzenie. Bez testu odtworzenia backup jest tylko nadzieja.

## Aktualizacja kodu

Przed restartem uslugi wykonaj:

```bash
cd /opt/secure-chat/app/server
npm install --omit=dev
npm run check
npm test
```

Po wdrozeniu sprawdz:

- health endpoint,
- logi systemd,
- logowanie klienta,
- pobieranie manifestu aktualizacji,
- WebSocket.
