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
- `docs/SECURITY_ROADMAP_PL.md` - aktualny model zaufania, znane ryzyka i
  roadmapa dojscia do mocniejszego E2EE.

## Aktualny model dzialania

1. Uzytkownik tworzy konto albo loguje sie na istniejace konto.
2. Urzadzenie laczy sie z serwerem przez HTTPS/WSS.
3. Haslo konta sluzy do logowania, a osobny sekret vaultu sluzy lokalnie do
   odszyfrowania kluczy. Sekret vaultu nie jest wysylany do API.
4. Wiadomosci i pliki sa szyfrowane po stronie aplikacji przed wyslaniem.
5. Serwer przechowuje zaszyfrowane dane, ale nie powinien miec technicznej
   mozliwosci odczytania tresci rozmow.
6. Aktualizacje aplikacji sa akceptowane tylko wtedy, gdy manifest ma poprawny
   podpis Ed25519 weryfikowany kluczem publicznym wbudowanym w klienta.

Wazne: serwer nadal widzi metadane techniczne, np. konto nadawcy, konto
odbiorcy, czas, rozmiar pakietu i adres IP. To nie jest system anonimowy.

## Funkcje do testowania

- Rejestracja konta i logowanie.
- Rejestracja z osobnym haslem konta i sekretem vaultu.
- Logowanie tego samego konta na drugim urzadzeniu.
- Lista uzytkownikow z serwera.
- Dodawanie kontaktow z listy.
- Porownanie safety number z kontaktem poza serwerem.
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
- Pierwsze dodanie kontaktu nadal ufa tozsamosci z serwera, dopoki uzytkownicy
  nie porownaja safety number poza serwerem. Po dodaniu aplikacja blokuje
  cicha podmiane zapisanej tozsamosci.
- To nadal nie jest komunikator odporny na aktywnie zlosliwy lub przejety
  serwer. Szczegoly sa w `docs/SECURITY_ROADMAP_PL.md`.
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
flutter build windows --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ
```

Gotowy folder:

```text
client\build\windows\x64\runner\Release
```

Android:

```powershell
flutter build apk --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ
```

Gotowy plik:

```text
client\build\app\outputs\flutter-apk\app-release.apk
```

Linux x64:

```bash
cd client
flutter build linux --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ
```

Gotowy folder:

```text
client/build/linux/x64/release/bundle
```

## Test lokalny klienta

1. Uruchom aplikacje.
2. Wpisz adres serwera, np. `https://chat.szkpn.pl`.
3. Utworz konto albo zaloguj sie. Dla nowych kont uzyj innego hasla konta i
   innego sekretu vaultu.
4. Otworz liste uzytkownikow.
5. Dodaj drugie konto do kontaktow.
6. W menu kontaktu otworz `Kod bezpieczenstwa` i porownaj go z druga osoba.
7. Wyslij wiadomosc testowa i plik.
8. Zamknij aplikacje, uruchom ponownie i sprawdz, czy historia zostala.

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

Manifest musi miec podpis Ed25519. Prywatny klucz release trzymaj poza repo i
poza serwerem produkcyjnym. Publiczny klucz trzeba podac przy buildzie klienta
przez `--dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=...`.

## Bezpieczenstwo

- Tresc rozmow i plikow jest szyfrowana po stronie klienta.
- Haslo konta i sekret vaultu sa rozdzielone. Sekret vaultu nie jest wysylany
  na serwer.
- Aplikacja wymaga HTTPS/WSS poza localhostem.
- Kazde konto ma lokalna tozsamosc Ed25519, a klucz X25519 do szyfrowania
  kluczy rozmow jest nia podpisany.
- Podpisane tozsamosci kontaktow sa przypinane lokalnie po dodaniu kontaktu.
  Zmiana tozsamosci wymaga recznej weryfikacji.
- Manifest aktualizacji jest podpisywany Ed25519, a klient blokuje update bez
  poprawnego podpisu.
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
