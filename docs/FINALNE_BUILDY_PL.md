# Finalne buildy klienta

Ten dokument opisuje przygotowanie finalnych paczek klienta dla Windows, Androida i Linuxa.

## Przed buildem

1. Uruchom testy serwera.
2. Uruchom testy klienta.
3. Sprawdz formatowanie.
4. Upewnij sie, ze masz publiczny klucz aktualizacji i `keyId`.
5. Nie trzymaj prywatnego klucza podpisu w katalogu klienta.

## Kontrole

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

## Windows

```bash
cd client
flutter build windows --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
```

Spakuj katalog release do ZIP i nazwij plik wersja oraz platforma, np. `secure-chat-windows-1.0.1.zip`.

## Android

```bash
cd client
flutter build apk --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
```

APK podpisuj zgodnie z konfiguracja lokalnego keystore. Keystore nie moze byc w repozytorium.

## Linux

```bash
cd client
flutter build linux --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
```

Srodowisko budujace Linuxa musi miec zaleznosci natywne wymagane przez Fluttera i biblioteki audio/wideo, w tym GStreamer.

## Publikacja

Po zbudowaniu artefaktow opublikuj manifest:

```bash
cd server
npm run publish-update -- --version <version> --build <build-number> --windows <windows-zip> --linux <linux-zip> --android <android-apk> --notes "Opis zmian" --signing-key <private-key-pem> --key-id <key-id>
```

Na serwerze Ubuntu manifest i pliki musza trafic do katalogow ustawionych w `UPDATE_MANIFEST_FILE` i `UPDATE_FILES_DIR`.

## Lista kontrolna

- Build number jest wiekszy niz w poprzednim wydaniu.
- Manifest jest podpisany.
- `keyId` zgadza sie z buildem klienta.
- SHA-256 artefaktow w manifeście odpowiada plikom.
- Klient widzi aktualizacje z testowego konta.
- Prywatne klucze i lokalne sciezki nie trafily do commita.
