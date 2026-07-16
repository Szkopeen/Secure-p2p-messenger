# Proces wydania

Ten proces dotyczy wydania serwera i klientow Secure P2P Messenger.

## 1. Przygotowanie

- Upewnij sie, ze repozytorium nie zawiera sekretow ani prywatnych danych.
- Sprawdz, czy wersja i build number sa poprawne.
- Zweryfikuj, czy `SECURE_CHAT_UPDATE_KEY_ID` odpowiada aktualnemu kluczowi publicznemu.
- Przygotuj notatki wydania bez prywatnych informacji.

## 2. Testy serwera

```bash
cd server
npm run check
npm test
```

## 3. Testy klienta

```bash
cd client
dart format --output=none --set-exit-if-changed lib test
dart analyze
flutter test
```

## 4. Buildy

Zbuduj platformy, ktore maja byc opublikowane:

```bash
flutter build windows --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
flutter build apk --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
flutter build linux --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
```

## 5. Manifest aktualizacji

```bash
cd server
npm run publish-update -- --version <version> --build <build-number> --windows <windows-zip> --linux <linux-zip> --android <android-apk> --notes "Opis zmian" --signing-key <private-key-pem> --key-id <key-id>
```

## 6. Wdrozenie serwera

Na serwerze Ubuntu:

1. zatrzymaj lub przelacz ruch zgodnie z lokalna procedura,
2. zaktualizuj kod,
3. zainstaluj zaleznosci,
4. uruchom testy,
5. zrestartuj usluge,
6. sprawdz logi i health endpoint.

## 7. Weryfikacja po wydaniu

Sprawdz:

- logowanie,
- WebSocket,
- pobieranie historii,
- tworzenie rozmowy,
- wysylke wiadomosci,
- pobranie manifestu,
- wykrycie aktualizacji przez klienta,
- brak dostepu publicznego do `/metrics`.

## 8. Rollback

Rollback serwera wymaga zgodnosci formatu danych. Przed migracjami trzymaj backup. Rollback klienta jest mozliwy tylko wtedy, gdy starszy klient nadal rozumie format danych i akceptuje aktualny klucz aktualizacji.
