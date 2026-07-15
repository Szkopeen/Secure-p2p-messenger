# Wdrozenie Secure Chat cloud-only

Ten dokument opisuje aktualny tryb projektu: konto cloud, HTTPS/WSS przez reverse proxy i jednorazowe tickety WebSocket. Stary tryb relay ze wspolnym sekretem zostal usuniety z aktywnej sciezki serwera i klienta.

## Minimalna konfiguracja `.env`

```bash
HOST=127.0.0.1
PORT=8443
REGISTRATION_MODE=disabled
ADMIN_TOKEN=TU_WKLEJ_LOSOWY_SEKRET_ADMIN_MINIMUM_32_ZNAKI
MAX_PAYLOAD_BYTES=16777216
MAX_CONNECTIONS_PER_USER=12
V2_DATA_DIR=/opt/secure-p2p/app/server/data-v2
UPDATE_MANIFEST_FILE=/opt/secure-p2p/app/server/updates/manifest.json
UPDATE_FILES_DIR=/opt/secure-p2p/app/server/updates/files
```

`REGISTRATION_MODE=open` wlaczaj tylko na czas kontrolowanego tworzenia kont. Po utworzeniu kont testowych lub produkcyjnych wroc do `disabled`.

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
5. Dodaj kontakt z listy uzytkownikow, porownaj safety number i wyslij wiadomosc.
6. Zamknij klienta, uruchom ponownie i sprawdz lokalna historie.
7. Zaloguj to samo konto na drugim urzadzeniu i sprawdz synchronizacje.
8. Uniewaznij stare urzadzenie testowe i upewnij sie, ze traci sesje.

## Diagnostyka

```bash
sudo systemctl status secure-p2p-relay --no-pager
sudo journalctl -u secure-p2p-relay -n 100 --no-pager
sudo systemctl status caddy --no-pager
curl https://chat.twojadomena.pl/healthz
```

Nazwa uslugi systemd moze nadal zawierac `relay` historycznie, ale aktywny transport aplikacji to cloud API `/v2`.