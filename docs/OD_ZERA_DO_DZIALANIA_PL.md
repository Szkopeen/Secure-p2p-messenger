# Od zera do dzialania Secure Chat

Aktualna wersja projektu dziala w trybie cloud-only. Stary tryb P2P/relay ze wspolnym sekretem zostal usuniety z aktywnej sciezki, bo pozwalal posiadaczowi wspolnego sekretu deklarowac cudza tozsamosc.

## 1. Serwer

Na maszynie docelowej zainstaluj Node.js 20+, skopiuj katalog projektu i przejdz do serwera:

```bash
cd /opt/secure-p2p/app/server
npm install
cp .env.example .env
nano .env
```

Minimalne zmienne:

```bash
HOST=127.0.0.1
PORT=8443
REGISTRATION_MODE=disabled
ADMIN_TOKEN=TU_WKLEJ_LOSOWY_SEKRET_ADMIN_MINIMUM_32_ZNAKI
V2_DATA_DIR=/opt/secure-p2p/app/server/data-v2
```

Losowy sekret administratora wygenerujesz lokalnie:

```bash
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
```

## 2. TLS i publiczny adres

Wystaw serwer przez Caddy albo nginx. Node.js powinien zostac za reverse proxy i sluchac tylko na localhost.

```text
Klient HTTPS/WSS -> Caddy/nginx -> 127.0.0.1:8443
```

W aplikacji wpisuj adres HTTPS, np. `https://chat.twojadomena.pl`.

## 3. Pierwsze konta

1. Na krotki czas ustaw `REGISTRATION_MODE=open`.
2. Uruchom serwer.
3. Utworz pierwsze konta w aplikacji.
4. Ustaw `REGISTRATION_MODE=disabled`.
5. Zrestartuj usluge.

Docelowy system zaproszen powinien byc osobny, jednorazowy i hashowany po stronie serwera. Do czasu jego wdrozenia uzywaj tylko `disabled` albo kontrolowanego `open`.

## 4. Sprawdzenie

```bash
curl https://chat.twojadomena.pl/healthz
npm run check
```

Po stronie klienta:

```powershell
flutter test
```

Nastepnie uruchom dwa klienty, zaloguj dwa konta, dodaj kontakt, porownaj safety number i wyslij wiadomosc testowa.

## 5. Uwagi bezpieczenstwa

- WebSocket uzywa jednorazowego ticketu z `/v2/ws-ticket`, a nie tokenu w URL.
- Sekret vaultu nie jest wysylany do serwera.
- Backend plikowy JSON nadal jest prototypowy i wymaga migracji do SQLite/PostgreSQL przed wieksza produkcja.
- Projekt nie jest odpowiednikiem Signala i nie jest przeznaczony dla scenariuszy wysokiego ryzyka.