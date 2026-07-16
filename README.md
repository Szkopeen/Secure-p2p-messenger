# Secure P2P Messenger

Secure P2P Messenger to self-hosted komunikator z klientem Flutter i serwerem API v2. Aktualna wersja dziala w trybie cloud relay: serwer przechowuje konta, sesje i zaszyfrowana historie, a tresc rozmow pozostaje szyfrowana po stronie klienta.

Repozytorium nie powinno zawierac prywatnych danych, prawdziwych domen, adresow IP, tokenow, kluczy ani lokalnych sciezek. Wszystkie przyklady ponizej uzywaja placeholderow.

## Aktualny stan

- Klient: Flutter dla Windows, Androida i Linuxa.
- Serwer: Node.js 24+ uruchamiany na serwerze Ubuntu.
- Dane serwera: lokalny katalog `V2_DATA_DIR`, pliki stanu aplikacji i katalog aktualizacji.
- Transport: HTTPS i WSS za reverse proxy.
- Rejestracja: `disabled`, `invite` albo `open`.
- Aktualizacje klienta: podpisany manifest Ed25519 i artefakty dla Windows, Linuxa oraz Androida.
- Web build nie jest wspierany.

## Bezpieczenstwo w tej wersji

Zaimplementowane mechanizmy:

- szyfrowanie tresci rozmow po stronie klienta,
- koperty `memberKeys` z AAD v2 przypisanym do rozmowy, odbiorcy, epoki klucza i urzadzenia,
- podpisy urzadzen oraz kontrola epok listy urzadzen,
- liczniki i hash-chain dla wiadomosci w rozmowie,
- lokalny log key transparency dostepny przez `/v2/key-transparency`,
- oddzielne limity logowania, WebSocket pre-auth, kont, rozmow i przestrzeni dyskowej,
- ochrona `/metrics` oparta o jawnie zaufane proxy i allowliste IP,
- bezpieczniejsze serwowanie manifestu i plikow aktualizacji bez podazania za symlinkami,
- lokalna blokada aplikacji PIN z utrwalaniem stanu blokady.

Wazne ograniczenia:

- to nie jest implementacja protokolu Signal,
- pelny Double Ratchet i post-compromise security nie sa jeszcze zakonczone,
- OPAQUE/PAKE nie jest jeszcze uzywany do logowania,
- key transparency jest lokalnym logiem na self-hosted serwerze, bez zewnetrznych swiadkow,
- PIN chroni interfejs aplikacji, a nie zastapi silnego hasla i bezpiecznego magazynu kluczy systemu.

## Struktura repozytorium

```text
client/   Aplikacja Flutter.
server/   Serwer API v2, WebSocket, aktualizacje i testy bezpieczenstwa.
docs/     Instrukcje wdrozenia, protokolu, aktualizacji i modelu zagrozen.
```

## Szybki start: serwer

```bash
cd server
npm install
cp .env.example .env
npm test
npm start
```

Minimalne ustawienia produkcyjne w `.env`:

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

Na produkcji wystaw serwer przez HTTPS/WSS z reverse proxy na serwerze Ubuntu. Szczegoly sa w [docs/DEPLOYMENT_PL.md](docs/DEPLOYMENT_PL.md).

## Szybki start: klient

```bash
cd client
flutter pub get
dart analyze
flutter test
flutter run -d windows
```

Build z weryfikacja podpisanych aktualizacji:

```bash
flutter build windows --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
flutter build apk --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
flutter build linux --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
```

## Testy i formatowanie

```bash
cd server
npm run check
npm test
```

```bash
cd client
dart format --output=none --set-exit-if-changed lib test
dart analyze
flutter test
```

## Dokumentacja

- [docs/OD_ZERA_DO_DZIALANIA_PL.md](docs/OD_ZERA_DO_DZIALANIA_PL.md) - uruchomienie od zera.
- [docs/DEPLOYMENT_PL.md](docs/DEPLOYMENT_PL.md) - wdrozenie na serwerze Ubuntu.
- [docs/ZDALNY_DOSTEP_UBUNTU_PL.md](docs/ZDALNY_DOSTEP_UBUNTU_PL.md) - zdalny dostep administracyjny do serwera Ubuntu.
- [docs/PROTOCOL_V2.md](docs/PROTOCOL_V2.md) - aktualny opis protokolu v2.
- [docs/THREAT_MODEL_PL.md](docs/THREAT_MODEL_PL.md) - model zagrozen.
- [docs/SECURITY_ROADMAP_PL.md](docs/SECURITY_ROADMAP_PL.md) - mapa dalszych prac bezpieczenstwa.
- [docs/AKTUALIZACJE_PL.md](docs/AKTUALIZACJE_PL.md) - podpisane aktualizacje.
- [docs/RELEASE_PROCESS_PL.md](docs/RELEASE_PROCESS_PL.md) - proces wydania.
- [docs/FINALNE_BUILDY_PL.md](docs/FINALNE_BUILDY_PL.md) - finalne buildy.
- [docs/PRIVACY_HISTORY_CLEANUP_PL.md](docs/PRIVACY_HISTORY_CLEANUP_PL.md) - czyszczenie historii repo po przypadkowym wycieku danych.

## Zasady prywatnosci repozytorium

- Nie commituj `.env`, prywatnych kluczy, tokenow, prawdziwych domen ani adresow IP.
- Nie commituj lokalnych sciezek, nazw kont systemowych ani danych autora.
- W dokumentacji uzywaj placeholderow: `<domain>`, `<server-ip>`, `<admin-token>`, `<repo-dir>`.
- Jezeli sekret trafil do historii Git, uznaj go za spalony i natychmiast go obroc.
