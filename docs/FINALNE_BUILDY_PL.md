# Finalne buildy aplikacji

Flutter nie cross-kompiluje desktopowego Linuxa z Windowsa. Windows buduj na Windowsie, Linux na Linuxie, Android na komputerze z Android SDK.

## Windows ZIP

```powershell
cd "C:\Users\ulkhh\Documents\New project\client"
flutter clean
flutter pub get
flutter build windows --release
Compress-Archive -Path ".\build\windows\x64\runner\Release\*" -DestinationPath "$env:USERPROFILE\Desktop\secure-p2p-windows.zip" -Force
```

## Android APK

```powershell
cd "C:\Users\ulkhh\Documents\New project\client"
flutter clean
flutter pub get
flutter build apk --release
Copy-Item ".\build\app\outputs\flutter-apk\app-release.apk" "$env:USERPROFILE\Desktop\secure-p2p-android.apk" -Force
```

## Linux ZIP

Na Linuxie zainstaluj narzedzia:

```bash
sudo apt update
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev libsqlite3-dev zip
```

Zbuduj paczke:

```bash
cd ~/secure-p2p/client
flutter clean
flutter pub get
flutter build linux --release
cd build/linux/x64/release
zip -r ~/secure-p2p-linux.zip bundle
```

## Publikacja aktualizacji na relay

Najpierw zwieksz `version:` w `client/pubspec.yaml`, np. `1.0.1+2`. Liczba po `+` musi rosnac.

Wgraj paczki na Raspberry Pi i uruchom:

```bash
cd /opt/secure-p2p/app/server
npm run publish-update -- --version 1.0.1 --build 2 --windows ~/secure-p2p-windows.zip --linux ~/secure-p2p-linux.zip --android ~/secure-p2p-android.apk --notes "Nowa wersja aplikacji"
```

Aplikacja sprawdzi manifest przy starcie. Po pobraniu aktualizacji Windows i Linux sprobuja otworzyc pobrany plik; Android zapisze APK i system poprosi o zgode na instalacje spoza sklepu.
