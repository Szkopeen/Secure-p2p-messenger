# Aktualizacje aplikacji

Relay udostepnia najnowsza wersje aplikacji przez HTTPS:

- `/updates/manifest.json` - manifest z numerem wersji, SHA-256 i nazwami plikow.
- `/updates/files/<plik>` - paczka ZIP albo APK do pobrania.

Aplikacja sprawdza manifest automatycznie po starcie. Ten sam test mozna uruchomic recznie w `Ustawienia -> Aktualizacje`.

## 1. Zbuduj paczki

Najpierw zwieksz wersje w `client/pubspec.yaml`, np.:

```yaml
version: 1.0.1+2
```

Liczba po `+` to build. Musi byc wieksza niz w poprzedniej wydanej aplikacji.

Windows:

```powershell
cd "C:\Users\ulkhh\Documents\New project\client"
flutter clean
flutter pub get
flutter build windows --release
Compress-Archive -Path ".\build\windows\x64\runner\Release\*" -DestinationPath "$env:USERPROFILE\Desktop\secure-p2p-windows.zip" -Force
```

Android:

```powershell
cd "C:\Users\ulkhh\Documents\New project\client"
flutter build apk --release
Copy-Item ".\build\app\outputs\flutter-apk\app-release.apk" "$env:USERPROFILE\Desktop\secure-p2p-android.apk" -Force
```

Linux buduje sie na Linuxie:

```bash
cd ~/secure-p2p/client
flutter pub get
flutter build linux --release
cd build/linux/x64/release
zip -r ~/secure-p2p-linux.zip bundle
```

## 2. Wgraj paczki na serwer

Najprosciej wrzuc pliki do katalogu domowego na Raspberry Pi, np. przez GitHub, SCP, WinSCP albo pendrive.

Przyklad z komputera Windows przez SCP:

```powershell
scp "$env:USERPROFILE\Desktop\secure-p2p-windows.zip" szkpn@chat.szkpn.pl:~
scp "$env:USERPROFILE\Desktop\secure-p2p-android.apk" szkpn@chat.szkpn.pl:~
```

## 3. Opublikuj manifest na serwerze

Na Raspberry Pi:

```bash
cd /opt/secure-p2p/app/server
npm run publish-update -- --version 1.0.1 --build 2 --windows ~/secure-p2p-windows.zip --android ~/secure-p2p-android.apk --notes "Aktualizacja komunikatora"
```

Jesli masz tez paczke Linux:

```bash
cd /opt/secure-p2p/app/server
npm run publish-update -- --version 1.0.1 --build 2 --windows ~/secure-p2p-windows.zip --linux ~/secure-p2p-linux.zip --android ~/secure-p2p-android.apk --notes "Aktualizacja komunikatora"
```

`--build` musi byc wiekszy niz numer builda w aplikacji. Jesli aplikacja ma `version: 1.0.0+1`, kolejna publikacja powinna miec np. `--version 1.0.1 --build 2`.

## 4. Sprawdz, czy relay widzi aktualizacje

```bash
curl https://chat.szkpn.pl/updates/manifest.json
```

W aplikacji wejdz w `Ustawienia -> Aktualizacje` i kliknij odswiezanie.

## 5. Co robi przycisk w aplikacji

Przycisk pobiera paczke z relay i sprawdza jej SHA-256 z manifestu. Windows i Linux probuja od razu otworzyc folder z pobranym plikiem. Android pobiera APK do katalogu aplikacji; system moze poprosic o zgode na instalowanie aplikacji spoza sklepu.
