# Podpisane aktualizacje

Aktualizacje klienta sa publikowane przez serwer jako podpisany manifest i pliki artefaktow. Klient weryfikuje podpis Ed25519 przed pokazaniem aktualizacji.

## Elementy systemu

- `UPDATE_MANIFEST_FILE` - sciezka do manifestu JSON.
- `UPDATE_FILES_DIR` - katalog z paczkami aktualizacji.
- `UPDATE_SIGNING_KEY_FILE` - prywatny klucz Ed25519 uzywany tylko przy publikacji.
- `SECURE_CHAT_UPDATE_PUBLIC_KEY` - publiczny klucz zaszyty w buildzie klienta.
- `SECURE_CHAT_UPDATE_KEY_ID` - identyfikator aktualnego klucza.

Prywatny klucz podpisu nie moze trafic do repozytorium ani do klienta.

## Generowanie klucza

```bash
cd server
npm run generate-update-key -- --out ./secrets/update-signing-key.pem
```

Skrypt zapisze prywatny klucz oraz plik z publicznym kluczem raw base64url. Do builda klienta trafia tylko publiczny klucz.

## Build klienta

```bash
cd client
flutter build windows --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
flutter build apk --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
flutter build linux --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
```

`<key-id>` powinien byc stabilny dla danej pary kluczy, np. `primary-ed25519-v1`.

## Publikacja manifestu

```bash
cd server
npm run publish-update -- --version 1.0.1 --build 2 --windows ./secure-chat-windows.zip --linux ./secure-chat-linux.zip --android ./secure-chat.apk --notes "Opis zmian" --signing-key ./secrets/update-signing-key.pem --key-id <key-id>
```

Skrypt:

- kopiuje artefakty do `UPDATE_FILES_DIR`,
- liczy SHA-256 kazdego pliku,
- tworzy manifest v2,
- podpisuje sekcje `latest`,
- zapisuje manifest w `UPDATE_MANIFEST_FILE`.

## Wdrozenie na serwerze Ubuntu

Na produkcji trzymaj pliki np. w:

```text
/var/lib/secure-chat/updates/manifest.json
/var/lib/secure-chat/updates/files/
```

Proces serwera powinien miec prawo odczytu tych plikow. Konto publikujace aktualizacje moze miec prawo zapisu, ale nie powinno byc tym samym kontem, ktore obsluguje ruch publiczny, jezeli infrastruktura pozwala na rozdzielenie rol.

## Rotacja klucza

Rotacja wymaga:

1. wygenerowania nowego klucza,
2. ustawienia nowego `SECURE_CHAT_UPDATE_PUBLIC_KEY` i `SECURE_CHAT_UPDATE_KEY_ID`,
3. zbudowania nowej wersji klienta,
4. publikacji kolejnych manifestow z nowym `keyId`.

Po wycieku prywatnego klucza stare manifesty i artefakty nalezy uznac za niezaufane.
