# Od zera do dzialania

Ten przewodnik prowadzi od pustego serwera Ubuntu do dzialajacego self-hosted komunikatora.

## 1. Przygotuj serwer Ubuntu

Potrzebujesz:

- dostepu SSH,
- domeny albo prywatnego adresu dostepnego dla klientow,
- Node.js 24+,
- reverse proxy z TLS,
- konta systemowego dla uslugi.

Nie wpisuj prawdziwych sekretow do repozytorium. Trzymaj je w pliku env poza katalogiem projektu.

## 2. Skopiuj kod

Przykladowy katalog:

```text
/opt/secure-chat/app
```

W katalogu `server` zainstaluj zaleznosci:

```bash
npm install --omit=dev
```

Dla pierwszych testow developerskich mozna uzyc pelnego `npm install`.

## 3. Utworz katalogi danych

```text
/var/lib/secure-chat/data-v2
/var/lib/secure-chat/updates/files
```

Konto uslugi musi miec prawo zapisu do tych katalogow.

## 4. Skonfiguruj serwer

Utworz plik poza repozytorium, np.:

```text
/etc/secure-chat/server.env
```

Minimalna tresc:

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

## 5. Uruchom kontrole

```bash
cd /opt/secure-chat/app/server
npm run check
npm test
```

## 6. Uruchom usluge

Skonfiguruj systemd zgodnie z [DEPLOYMENT_PL.md](DEPLOYMENT_PL.md), a potem wystaw reverse proxy z HTTPS/WSS.

## 7. Przygotuj klienta

W katalogu `client`:

```bash
flutter pub get
dart analyze
flutter test
flutter build windows --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
```

Analogicznie zbuduj APK albo Linux release, jezeli potrzebujesz tych platform.

## 8. Utworz pierwsze konto

Najbezpieczniej ustaw `REGISTRATION_MODE=invite` i tworz konta przez zaproszenia administracyjne. `ADMIN_TOKEN` przechowuj jak sekret produkcyjny.

Po utworzeniu konta:

- zaloguj klienta,
- sprawdz utworzenie rozmowy,
- wyslij wiadomosc testowa,
- sprawdz synchronizacje po restarcie klienta.

## 9. Wlacz backup

Backup musi obejmowac katalog danych, katalog aktualizacji, plik env i prywatny klucz podpisu aktualizacji. Backup powinien byc szyfrowany.

## 10. Publikuj aktualizacje

Korzystaj z [AKTUALIZACJE_PL.md](AKTUALIZACJE_PL.md). Nie publikuj niepodpisanych manifestow.
