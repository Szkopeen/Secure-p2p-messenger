# Aktualizacje aplikacji

Serwer Secure Chat udostepnia najnowsza wersje aplikacji przez HTTPS:

- `/updates/manifest.json` - manifest z numerem wersji, SHA-256 i nazwami plikow.
- `/updates/files/<plik>` - paczka ZIP albo APK do pobrania.

Aplikacja sprawdza manifest automatycznie po starcie. Ten sam test mozna uruchomic recznie w `Ustawienia -> Aktualizacje`.

Od tej wersji manifest aktualizacji musi byc podpisany Ed25519. Serwer moze
hostowac manifest i pliki, ale klient zaakceptuje tylko manifest podpisany
kluczem prywatnym, ktorego nie ma na serwerze.

## 0. Wygeneruj klucz podpisywania release

Zrob to raz, na zaufanym komputerze. Prywatnego klucza nie wrzucaj na GitHub.

```powershell
cd server
npm run generate-update-key -- --out .\secrets\update-signing-key.pem
```

Polecenie wypisze publiczny klucz do builda klienta:

```text
--dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=... --dart-define=SECURE_CHAT_UPDATE_KEY_ID=primary-ed25519-v1
```

Prywatny klucz:

```text
server\secrets\update-signing-key.pem
```

Folder `server/secrets/` jest ignorowany przez Git.

## 1. Zbuduj paczki

Najpierw zwieksz wersje w `client/pubspec.yaml`, np.:

```yaml
version: 1.0.1+2
```

Liczba po `+` to build. Musi byc wieksza niz w poprzedniej wydanej aplikacji.

Windows:

```powershell
cd client
flutter clean
flutter pub get
flutter build windows --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ --dart-define=SECURE_CHAT_UPDATE_KEY_ID=primary-ed25519-v1
Compress-Archive -Path ".\build\windows\x64\runner\Release\*" -DestinationPath "$env:USERPROFILE\Desktop\secure-p2p-windows.zip" -Force
```

Android:

```powershell
cd client
flutter build apk --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ --dart-define=SECURE_CHAT_UPDATE_KEY_ID=primary-ed25519-v1
Copy-Item ".\build\app\outputs\flutter-apk\app-release.apk" "$env:USERPROFILE\Desktop\secure-p2p-android.apk" -Force
```

Linux buduje sie na Linuxie:

```bash
cd ~/secure-p2p/client
flutter pub get
flutter build linux --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ --dart-define=SECURE_CHAT_UPDATE_KEY_ID=primary-ed25519-v1
cd build/linux/x64/release
zip -r ~/secure-p2p-linux.zip bundle
```

## 2. Wgraj paczki na serwer

Najprosciej wrzuc pliki do katalogu domowego na Raspberry Pi, np. przez GitHub, SCP, WinSCP albo pendrive.

Przyklad z komputera Windows przez SCP:

```powershell
scp "$env:USERPROFILE\Desktop\secure-p2p-windows.zip" user@server.example.com:~
scp "$env:USERPROFILE\Desktop\secure-p2p-android.apk" user@server.example.com:~
```

## 3. Podpisz manifest na zaufanym komputerze

Prywatny klucz release trzymaj poza produkcyjnym serwerem. Na komputerze
release wygeneruj manifest i katalog plikow:

```bash
cd server
npm run publish-update -- --version 1.0.1 --build 2 --windows ~/secure-p2p-windows.zip --android ~/secure-p2p-android.apk --signing-key ./secrets/update-signing-key.pem --key-id primary-ed25519-v1 --manifest ./updates/manifest.json --files-dir ./updates/files --notes "Aktualizacja komunikatora"
```

Jesli masz tez paczke Linux:

```bash
cd server
npm run publish-update -- --version 1.0.1 --build 2 --windows ~/secure-p2p-windows.zip --linux ~/secure-p2p-linux.zip --android ~/secure-p2p-android.apk --signing-key ./secrets/update-signing-key.pem --key-id primary-ed25519-v1 --manifest ./updates/manifest.json --files-dir ./updates/files --notes "Aktualizacja komunikatora"
```

`--build` musi byc wiekszy niz numer builda w aplikacji. Jesli aplikacja ma `version: 1.0.0+1`, kolejna publikacja powinna miec np. `--version 1.0.1 --build 2`.

Potem wyslij na produkcje tylko `server/updates/manifest.json` i
`server/updates/files/`. Prywatnego klucza nie wysylaj na serwer.
Katalog `server/updates/` utrzymuj jako niezapisywalny dla procesu serwera poza
momentem wdrozenia release. Endpoint manifestu i endpoint artefaktow odrzucaja
symlinki i sprawdzaja realna sciezke pliku, ale uprawnienia katalogu nadal sa
wazna warstwa ochrony.

## 4. Sprawdz, czy serwer widzi aktualizacje

```bash
curl https://chat.example.com/updates/manifest.json
```

W aplikacji wejdz w `Ustawienia -> Aktualizacje` i kliknij odswiezanie.

## 5. Co robi przycisk w aplikacji

Przycisk najpierw sprawdza podpis manifestu Ed25519 oraz `keyId`. Jesli podpis
jest niepoprawny, ma nieznany `keyId` albo go brakuje, aplikacja blokuje
aktualizacje. Dopiero potem pobiera paczke z serwera, porownuje
`Content-Length` z podpisanym `size`, przerywa strumien po przekroczeniu
rozmiaru, zapisuje do losowego pliku `.part` i sprawdza SHA-256 z manifestu.
Windows i Linux probuja od razu otworzyc folder z pobranym plikiem. Android
pobiera APK do katalogu aplikacji; system moze poprosic o zgode na instalowanie
aplikacji spoza sklepu.
