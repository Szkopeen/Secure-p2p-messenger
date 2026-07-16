# Proces wydawniczy Secure Chat

Cel: kazdy build ma miec znany commit, znane wersje narzedzi, podpisany
manifest aktualizacji i zapisane hashe artefaktow. To jest proces
powtarzalny i audytowalny; bit-for-bit reproducible build wymaga jeszcze
zamrozenia toolchainow na osobnych runnerach.

## 1. Zamkniecie zmian

```bash
git status --short
git rev-parse HEAD
```

Nie buduj release z nieopisanymi lokalnymi zmianami. Jesli build testowy musi
powstac z dirty tree, wpisz to w notatkach release.

## 2. Zapis wersji narzedzi

```bash
node --version
npm --version
dart --version
flutter --version
```

Zapisz wynik razem z commitem i numerem release.

## 3. Kontrola przed buildem

W serwerze:

```bash
cd server
npm install
npm run check
npm test
```

W kliencie:

```bash
cd client
flutter pub get
dart analyze
flutter test
```

## 4. Backup produkcji przed publikacja

Na serwerze produkcyjnym:

```bash
cd /opt/secure-p2p/app/server
npm run backup-sqlite -- --out /backup/secure-chat-before-release.sqlite
```

Po restore testowym `PRAGMA integrity_check` powinien zwrocic `ok`.

## 5. Klucz podpisywania aktualizacji

Prywatny klucz Ed25519 generuj i trzymaj poza serwerem produkcyjnym:

```bash
cd server
npm run generate-update-key -- --out ./secrets/update-signing-key.pem
```

Publiczny klucz z wyniku komendy wbuduj w klienta przez:

```text
--dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=...
```

## 6. Build artefaktow

Najpierw zwieksz `version:` w `client/pubspec.yaml`, np. `1.0.1+2`.

Windows:

```powershell
cd client
flutter clean
flutter pub get
flutter build windows --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ
Compress-Archive -Path ".\build\windows\x64\runner\Release\*" -DestinationPath "$env:USERPROFILE\Desktop\secure-p2p-windows.zip" -Force
```

Android:

```powershell
cd client
flutter clean
flutter pub get
flutter build apk --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ
Copy-Item ".\build\app\outputs\flutter-apk\app-release.apk" "$env:USERPROFILE\Desktop\secure-p2p-android.apk" -Force
```

Linux buduj na Linuxie:

```bash
cd client
flutter clean
flutter pub get
flutter build linux --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ
cd build/linux/x64/release
zip -r ~/secure-p2p-linux.zip bundle
```

## 7. Hashe artefaktow

Windows:

```powershell
Get-FileHash "$env:USERPROFILE\Desktop\secure-p2p-windows.zip" -Algorithm SHA256
Get-FileHash "$env:USERPROFILE\Desktop\secure-p2p-android.apk" -Algorithm SHA256
```

Linux:

```bash
sha256sum ~/secure-p2p-linux.zip
```

Te hashe musza zgadzac sie z manifestem wygenerowanym przez
`publish-update`.

## 8. Publikacja manifestu

Na zaufanej maszynie release:

```bash
cd server
npm run publish-update -- --version 1.0.1 --build 2 --windows ~/secure-p2p-windows.zip --linux ~/secure-p2p-linux.zip --android ~/secure-p2p-android.apk --signing-key ./secrets/update-signing-key.pem --manifest ./updates/manifest.json --files-dir ./updates/files --notes "Nowa wersja aplikacji"
```

`publish-update` kopiuje artefakty, liczy SHA-256 i podpisuje manifest Ed25519.
Na serwer produkcyjny wyslij tylko `updates/manifest.json` oraz
`updates/files/`. Prywatnego klucza release nie kopiuj na produkcje.

## 9. Weryfikacja po publikacji

```bash
curl https://chat.example.com/healthz
curl https://chat.example.com/updates/manifest.json
```

Nastepnie uruchom klienta z poprzedniej wersji i sprawdz, czy:

- manifest ma poprawny podpis,
- aplikacja widzi nowszy `buildNumber`,
- pobrany artefakt ma zgodny SHA-256,
- instalacja nie wymaga omijania ostrzezenia o blednym podpisie manifestu.

## 10. Notatka release

Dla kazdego wydania zapisz:

- commit `git rev-parse HEAD`,
- wersje Node, npm, Dart i Flutter,
- numer `version` i `build`,
- publiczny klucz aktualizacji,
- SHA-256 artefaktow,
- wynik testow,
- informacje, czy release byl z clean tree,
- liste znanych ograniczen z `docs/SECURITY_ROADMAP_PL.md`.
