# Secure Chat

Prywatny komunikator E2EE z kontami uzytkownikow, szyfrowana historia na
serwerze i klientem Flutter dla Windows, Android oraz Linux.

Ten build testowy jest wersja cloud-only. Stary aktywny tryb P2P/WebRTC zostal
usuniety z klienta, zeby aplikacja byla lzejsza i prostsza do testowania.

## Co jest w projekcie

- `server/` - serwer Node.js. Obsluguje konta, logowanie, publiczna liste
  uzytkownikow, szyfrowany vault, rozmowy, zaszyfrowane wiadomosci, aktualizacje
  aplikacji i panel administracyjny.
- `client/` - aplikacja Flutter dla Windows, Android i Linux.
- `docs/OD_ZERA_DO_DZIALANIA_PL.md` - pelny przewodnik instalacji serwera na
  Raspberry Pi / Ubuntu.
- `docs/AKTUALIZACJE_PL.md` - publikowanie nowych wersji aplikacji na serwerze.
- `docs/FINALNE_BUILDY_PL.md` - komendy do tworzenia paczek aplikacji.

## Aktualny model dzialania

1. Uzytkownik tworzy konto albo loguje sie na istniejace konto.
2. Urzadzenie laczy sie z serwerem przez HTTPS/WSS.
3. Klucze rozmow i dane prywatne sa trzymane lokalnie oraz w szyfrowanym
   vaulcie.
4. Wiadomosci i pliki sa szyfrowane po stronie aplikacji przed wyslaniem.
5. Serwer przechowuje zaszyfrowane dane, ale nie powinien miec technicznej
   mozliwosci odczytania tresci rozmow.

Wazne: serwer nadal widzi metadane techniczne, np. konto nadawcy, konto
odbiorcy, czas, rozmiar pakietu i adres IP. To nie jest system anonimowy.

## Funkcje do testowania

- Rejestracja konta i logowanie.
- Logowanie tego samego konta na drugim urzadzeniu.
- Lista uzytkownikow z serwera.
- Dodawanie kontaktow z listy.
- Rozmowy 1:1.
- Wiadomosci tekstowe, wieloliniowe i odpowiedzi.
- Pliki, obrazy, audio i wideo.
- Lokalne powiadomienia systemowe.
- Szyfrowana lokalna historia rozmow.
- Usuwanie danych lokalnych z aplikacji.
- Sprawdzanie aktualizacji z poziomu aplikacji.

## Ograniczenia obecnego buildu testowego

- Aktywny P2P/WebRTC jest usuniety.
- Web build nie jest zakresem projektu.
- Grupy sa po migracji architektury do ponownego testu i moga wymagac dalszej
  stabilizacji przed testami z wieksza liczba osob.
- Nazwa techniczna paczki Flutter nadal brzmi `secure_p2p_messenger`, ale
  aplikacja w UI uzywa nazwy `Secure Chat`.

## Uruchomienie serwera

Na serwerze:

```bash
cd /opt/secure-p2p/app/server
npm install
cp .env.example .env
nano .env
npm start
```

Minimalne zmienne w `.env`:

```bash
HOST=127.0.0.1
PORT=8443
RELAY_TOKEN=losowy-token-minimum-32-znaki
ADMIN_TOKEN=losowy-token-admin-minimum-32-znaki
V2_DATA_DIR=/opt/secure-p2p/app/server/data-v2
UPDATE_MANIFEST_FILE=/opt/secure-p2p/app/server/updates/manifest.json
UPDATE_FILES_DIR=/opt/secure-p2p/app/server/updates/files
```

W produkcji serwer powinien stac za Caddy/Nginx z TLS, np. pod adresem:

```text
https://chat.szkpn.pl
```

## Build klienta

Przed buildem:

```powershell
cd "C:\Users\ulkhh\Documents\New project\client"
flutter pub get
```

Windows:

```powershell
flutter build windows --release
```

Gotowy folder:

```text
client\build\windows\x64\runner\Release
```

Android:

```powershell
flutter build apk --release
```

Gotowy plik:

```text
client\build\app\outputs\flutter-apk\app-release.apk
```

Linux x64:

```bash
cd client
flutter build linux --release
```

Gotowy folder:

```text
client/build/linux/x64/release/bundle
```

## Test lokalny klienta

1. Uruchom aplikacje.
2. Wpisz adres serwera, np. `https://chat.szkpn.pl`.
3. Utworz konto albo zaloguj sie.
4. Otworz liste uzytkownikow.
5. Dodaj drugie konto do kontaktow.
6. Wyslij wiadomosc testowa i plik.
7. Zamknij aplikacje, uruchom ponownie i sprawdz, czy historia zostala.

## Aktualizacje aplikacji

Serwer udostepnia manifest:

```text
/updates/manifest.json
```

Pliki aktualizacji:

```text
/updates/files/
```

Aplikacja sprawdza manifest przy starcie i w ekranie ustawien. Publikowanie
nowej wersji opisuje `docs/AKTUALIZACJE_PL.md`.

## Bezpieczenstwo

- Tresc rozmow i plikow jest szyfrowana po stronie klienta.
- Haslo nie powinno byc wysylane ani zapisywane jako tekst jawny.
- Serwer przechowuje dane potrzebne do synchronizacji i dostarczenia wiadomosci.
- Kopie zapasowe `data-v2` sa wrazliwe, bo zawieraja zaszyfrowane dane kont.
- Przed uzyciem w srodowisku wysokiego ryzyka potrzebny jest niezalezny audyt.

## Szybka diagnostyka

Serwer:

```bash
sudo systemctl status secure-p2p-relay --no-pager
sudo journalctl -u secure-p2p-relay -n 100 --no-pager
curl https://chat.szkpn.pl/healthz
```

Klient:

```powershell
flutter doctor
flutter analyze
flutter build windows --release
flutter build apk --release
```
