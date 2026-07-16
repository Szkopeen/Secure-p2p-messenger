# Wdrozenie Secure Chat cloud-only

Ten dokument opisuje aktualny tryb projektu: konto cloud, HTTPS/WSS przez reverse proxy i jednorazowe tickety WebSocket. Stary tryb relay ze wspolnym sekretem zostal usuniety z aktywnej sciezki serwera i klienta.

## Minimalna konfiguracja `.env`

```bash
HOST=127.0.0.1
PORT=8443
REGISTRATION_MODE=disabled
ADMIN_TOKEN=TU_WKLEJ_LOSOWY_SEKRET_ADMIN_MINIMUM_32_ZNAKI
METRICS_ALLOWED_IPS=127.0.0.1,::1,::ffff:127.0.0.1
SESSION_TTL_HOURS=72
SESSION_IDLE_TTL_HOURS=24
METRICS_STORAGE_CACHE_SECONDS=15
MAX_PAYLOAD_BYTES=16777216
MAX_CONNECTIONS_PER_USER=12
V2_DATA_DIR=/opt/secure-p2p/app/server/data-v2
UPDATE_MANIFEST_FILE=/opt/secure-p2p/app/server/updates/manifest.json
UPDATE_FILES_DIR=/opt/secure-p2p/app/server/updates/files
```

`REGISTRATION_MODE=open` wlaczaj tylko na czas kontrolowanego tworzenia kont. Po utworzeniu kont testowych lub produkcyjnych wroc do `disabled`.
`MAX_PAYLOAD_BYTES` ogranicza pojedyncza ramke WebSocket. Serwer akceptuje
wartosci do 16 MiB dla zgodnosci z istniejacymi wdrozeniami, ale nowe
instancje moga zostawic bezpieczniejsze domyslne `65536`.
`/metrics` wymaga jednoczesnie `x-admin-token` oraz adresu z
`METRICS_ALLOWED_IPS`. Dla publicznego reverse proxy trzymaj metryki na
localhost, Tailscale albo innej sieci administracyjnej; nie wystawiaj ich jako
zwyklego publicznego endpointu.

## Reverse proxy

Node.js powinien sluchac lokalnie na `127.0.0.1:8443`, a publiczny TLS powinien obslugiwac Caddy albo nginx.

Przyklad przeplywu:

```text
https://chat.twojadomena.pl -> Caddy/nginx -> http://127.0.0.1:8443
wss://chat.twojadomena.pl/v2/ws -> Caddy/nginx -> ws://127.0.0.1:8443/v2/ws
```

Klient laczy sie adresem `https://chat.twojadomena.pl`. Poza localhostem aplikacja wymaga HTTPS/WSS.

## WebSocket

Klient nie wysyla dlugotrwalego tokenu sesji w URL ani w naglowku handshake. Przeplyw jest taki:

1. zwykle zadanie HTTPS z `Authorization: Bearer` pobiera `/v2/ws-ticket`,
2. serwer wydaje krotko zyjacy ticket,
3. klient otwiera `/v2/ws`,
4. pierwsza ramka WebSocket zawiera `{ "type": "auth", "ticket": "..." }`,
5. serwer atomowo zuzywa ticket i odrzuca ponowne uzycie.

## Smoke test

1. Uruchom serwer i sprawdz `/healthz`.
2. Tymczasowo ustaw `REGISTRATION_MODE=open` i utworz dwa konta.
3. Ustaw `REGISTRATION_MODE=disabled` i zrestartuj usluge.
4. Zaloguj dwa klienty przez adres HTTPS.
5. Wyszukaj kontakt po dokladnym loginie, porownaj safety number i wyslij
   wiadomosc.
6. Zamknij klienta, uruchom ponownie i sprawdz lokalna historie.
7. Zaloguj to samo konto na drugim urzadzeniu i sprawdz synchronizacje.
8. Uniewaznij stare urzadzenie testowe i upewnij sie, ze traci sesje.

## Diagnostyka

```bash
sudo systemctl status secure-p2p --no-pager
sudo journalctl -u secure-p2p -n 100 --no-pager
sudo systemctl status caddy --no-pager
curl https://chat.twojadomena.pl/healthz
curl -H "x-admin-token: $ADMIN_TOKEN" http://127.0.0.1:8443/metrics
```

`/healthz` jest publiczne i zwraca tylko prosty status OK. Szczegoly KDF i
storage sa pod `/metrics`, chronione `x-admin-token` i allowlista adresow IP.

## Backup SQLite

Aktywna baza cloud jest w `V2_DATA_DIR`:

```text
/opt/secure-p2p/app/server/data-v2/secure-chat.sqlite
/opt/secure-p2p/app/server/data-v2/secure-chat.sqlite-wal
/opt/secure-p2p/app/server/data-v2/secure-chat.sqlite-shm
```

Kopia online:

```bash
cd /opt/secure-p2p/app/server
npm run backup-sqlite -- --out /backup/secure-chat.sqlite
```

Kopia offline: zatrzymaj `secure-p2p`, skopiuj komplet `.sqlite`, `.sqlite-wal`
i `.sqlite-shm`, a potem uruchom usluge. Restore wykonuj z kompletu plikow z
tej samej chwili albo z pliku `.backup`.
