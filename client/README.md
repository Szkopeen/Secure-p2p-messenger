# Klient Flutter

Ten katalog zawiera aplikacje Secure P2P Messenger dla Windows, Androida i Linuxa. Klient laczy sie z self-hosted serwerem API v2, przechowuje lokalny vault i szyfruje tresc rozmow po stronie urzadzenia.

## Wymagania

- Flutter z SDK Dart zgodnym z `pubspec.yaml`.
- Toolchain platformy docelowej: Windows, Android albo Linux.
- Dzialajacy serwer HTTPS/WSS.

Web nie jest wspierany w aktualnym stanie projektu.

## Uruchomienie developerskie

```bash
flutter pub get
dart analyze
flutter test
flutter run -d windows
```

Dla Linuxa lub Androida zmien urzadzenie docelowe zgodnie z lokalnym srodowiskiem Flutter.

## Build produkcyjny

Klient powinien byc budowany z publicznym kluczem aktualizacji:

```bash
flutter build windows --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
flutter build apk --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
flutter build linux --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=<public-key-base64url> --dart-define=SECURE_CHAT_UPDATE_KEY_ID=<key-id>
```

Nie wpisuj prywatnego klucza podpisu do builda klienta. Klient dostaje tylko klucz publiczny.

## Konfiguracja uzytkownika

W aplikacji uzytkownik podaje adres serwera, login i haslo. Adres powinien wskazywac na HTTPS/WSS, np. `<domain>` albo prywatny adres dostepny przez VPN.

## Dane lokalne

Klient przechowuje:

- zaszyfrowany vault,
- ustawienia aplikacji,
- lokalne metadane rozmow,
- stan blokady PIN.

PIN jest blokada interfejsu. Nie nalezy go traktowac jako pelnego zamiennika silnego hasla konta i zabezpieczen systemowego magazynu kluczy.

## Kontrole przed commitem

```bash
dart format --output=none --set-exit-if-changed lib test
dart analyze
flutter test
```

Jezeli build Linuxa w CI nie przechodzi przez brak GStreamera, trzeba doinstalowac systemowe pakiety GStreamer w obrazie CI. To zaleznosc natywna uzywana przez biblioteki audio/wideo.
