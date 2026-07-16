# Secure Chat

Self-hosted komunikator z szyfrowaniem po stronie klienta, zaszyfrowana
historia na serwerze i klientami dla Windows, Android oraz Linux.

Projekt zaczynal jako prywatny komunikator P2P z relayem, ale aktualny kierunek
to prostsza i stabilniejsza wersja cloud-only: serwer przechowuje konta,
zaszyfrowane wiadomosci, pliki i vault, a aplikacja dba o szyfrowanie,
weryfikacje tozsamosci oraz synchronizacje wielu urzadzen.

Najuczciwszy opis obecnej wersji:

> Self-hosted komunikator chmurowy z szyfrowaniem tresci po stronie klienta,
> zaszyfrowana historia na serwerze i synchronizacja wielu urzadzen,
> przeznaczony dla malej, zaufanej grupy.

To nie jest jeszcze odpowiednik Signala ani system dla scenariuszy wysokiego
ryzyka. Szczegoly sa w [docs/SECURITY_ROADMAP_PL.md](docs/SECURITY_ROADMAP_PL.md).

## Status projektu

- Tryb aktywnego P2P/WebRTC zostal usuniety z klienta.
- Web build nie jest juz zakresem projektu.
- Obslugiwane platformy klienta: Windows, Android, Linux.
- Backend jest nadal lekki i plikowy, oparty o Node.js oraz JSON.
- Produkcyjny adres testowy instancji: `https://chat.szkpn.pl`.
- Techniczna nazwa paczki Flutter nadal brzmi `secure_p2p_messenger`.

## Struktura repozytorium

- `client/` - aplikacja Flutter dla Windows, Android i Linux.
- `server/` - serwer Node.js: konta, WebSocket, zaszyfrowana historia,
  aktualizacje, publiczna lista uzytkownikow i API administracyjne.
- `docs/OD_ZERA_DO_DZIALANIA_PL.md` - instalacja serwera od zera na Ubuntu/RPi.
- `docs/DEPLOYMENT_PL.md` - wdrozenie i usluga systemd.
- `docs/AKTUALIZACJE_PL.md` - publikowanie aktualizacji aplikacji.
- `docs/FINALNE_BUILDY_PL.md` - komendy do tworzenia buildow.
- `docs/SECURITY_ROADMAP_PL.md` - aktualny model zaufania i roadmapa security.
- `docs/ZDALNY_DOSTEP_PI_PL.md` - zdalny dostep do Raspberry Pi poza domem.

## Aktualna architektura

```text
Klient Windows / Android / Linux
        |
        | HTTPS/WSS
        v
Caddy TLS reverse proxy
        |
        | localhost:8443
        v
Node.js Secure Chat server
        |
        v
Pliki JSON: konta, vaulty, wiadomosci, kolejki, aktualizacje
```

Serwer dostarcza synchronizacje i przechowywanie, ale tresc wiadomosci oraz
plikow jest szyfrowana po stronie klienta. Serwer widzi jednak metadane
techniczne: konta, relacje, rozmiary pakietow, czas komunikacji i adresy IP.
Projekt nie zapewnia anonimowosci.

## Funkcje aplikacji

- Rejestracja i logowanie kont.
- Osobny sekret vaultu, oddzielony od hasla logowania.
- Synchronizacja wielu urzadzen jednego konta.
- Lista uzytkownikow opt-in i dodawanie kontaktow.
- Rozmowy 1:1 oraz grupy w trakcie stabilizacji po zmianie architektury.
- Wiadomosci tekstowe, wieloliniowe, odpowiedzi, edycja, reakcje i usuwanie.
- Pliki, obrazy, audio i wideo.
- Profilowe uzytkownika z limitem rozmiaru.
- Lokalne powiadomienia systemowe, ograniczane gdy aplikacja jest aktywna.
- Lokalna zaszyfrowana historia.
- Offline delivery przez serwer.
- Wyszukiwanie, przypiete wiadomosci i autoscroll do najnowszych wiadomosci.
- Sprawdzanie i pobieranie aktualizacji z poziomu aplikacji.

## Security progress

Wykonane elementy zabezpieczen:

- Tresc rozmow i plikow szyfrowana po stronie klienta.
- Haslo konta i sekret vaultu sa rozdzielone.
- Haslo konta jest wysylane do serwera jako haslo logowania, ale tylko przez
  HTTPS poza localhostem. Nie jest uzywane jako sekret vaultu.
- Sekret vaultu nie jest wysylany do API.
- Klient wymaga HTTPS/WSS poza localhostem.
- WebSocket cloud uzywa krotko zyjacego, jednorazowego ticketu z `/v2/ws-ticket`.
- Dlugotrwaly token sesji nie trafia do URL WebSocket ani do naglowkow handshake.
- Kazde konto ma trwala tozsamosc Ed25519.
- Klucz X25519 do opakowywania kluczy rozmow jest podpisany tozsamoscia
  Ed25519.
- Podpis bundle kluczy obejmuje UUID konta i kanoniczny origin serwera.
- Origin serwera jest normalizowany, m.in. bez sciezki, query, fragmentu i
  domyslnego portu.
- Kontakty maja lokalny TOFU/pinning tozsamosci.
- Safety number bazuje na UUID kont i kluczach Ed25519 obu stron.
- Rotacja Ed25519 jest podpisana starym i nowym kluczem, zawiera epoch oraz hash
  poprzedniego dowodu.
- Nowe wiadomosci maja anty-replay: licznik, hash poprzedniej wiadomosci,
  genesis hash i kanoniczny hash calej koperty.
- Wiadomosci poza kolejnoscia sa buforowane jako luka zamiast od razu blokowac
  rozmowe.
- Kazde urzadzenie ma lokalny klucz podpisujacy Ed25519.
- Certyfikat urzadzenia jest podpisany tozsamoscia konta.
- Koperty wiadomosci sa podpisywane kluczem urzadzenia.
- Podpis urzadzenia wchodzi do hash-chain anty-replay.
- Podpisana lista urzadzen zawiera epoch, previous hash, aktywne urzadzenia i
  uniewaznienia.
- Backend zapisuje liste urzadzen przez compare-and-swap na epoch/hash.
- Uniewaznione urzadzenie traci sesje, polaczenia WebSocket i mozliwosc
  wysylania nowych podpisanych wiadomosci.
- Manifest aktualizacji aplikacji jest podpisywany Ed25519 i weryfikowany
  kluczem publicznym wbudowanym w klienta.

## Znane ograniczenia

- Backend oparty o pliki JSON jest dobry do prototypu i malej instancji, ale nie
  do duzej publicznej uslugi.
- Pierwsze dodanie kontaktu nadal wymaga zaufania do danych z serwera do czasu
  porownania safety number poza serwerem.
- Nie ma jeszcze publicznego key transparency logu.
- Nie ma jeszcze OPAQUE ani innego protokolu logowania, ktory kryptograficznie
  ukrywa haslo logowania przed aktywnie zlosliwym serwerem.
- Nie ma jeszcze Double Ratchet ani MLS, wiec forward secrecy i
  post-compromise security sa ograniczone.
- Uniewaznienie urzadzenia blokuje nowe wiadomosci i sesje, ale pelne odciecie
  dostepu wymaga jeszcze rotacji kluczy rozmow i rewrapu dla aktywnych urzadzen.
- Kopie danych serwera zawieraja zaszyfrowane, ale wrazliwe dane uzytkownikow.
- Projekt wymaga dalszych testow integracyjnych, migracji i audytu przed uzyciem
  w sytuacjach wysokiego ryzyka.

## Uruchomienie serwera

Minimalnie:

```bash
cd /opt/secure-p2p/app/server
npm install
cp .env.example .env
nano .env
npm start
```

Najwazniejsze zmienne:

```bash
HOST=127.0.0.1
PORT=8443
REGISTRATION_MODE=disabled
ADMIN_TOKEN=losowy-token-admin-minimum-32-znaki
MAX_CONNECTIONS_PER_USER=12
V2_DATA_DIR=/opt/secure-p2p/app/server/data-v2
UPDATE_MANIFEST_FILE=/opt/secure-p2p/app/server/updates/manifest.json
UPDATE_FILES_DIR=/opt/secure-p2p/app/server/updates/files
```

W normalnym wdrozeniu Node.js slucha lokalnie na `127.0.0.1:8443`, a publiczny
TLS robi Caddy:

```text
https://chat.szkpn.pl -> Caddy -> 127.0.0.1:8443
```

Diagnostyka na Pi:

```bash
sudo systemctl status secure-p2p-relay --no-pager
sudo journalctl -u secure-p2p-relay -n 100 --no-pager
sudo systemctl status caddy --no-pager
curl https://chat.szkpn.pl/healthz
```

## Build klienta

Przygotowanie:

```powershell
cd "C:\Users\ulkhh\Documents\New project\client"
flutter pub get
flutter analyze
```

Windows:

```powershell
flutter build windows --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ
```

Android:

```powershell
flutter build apk --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ
```

Linux x64:

```bash
cd client
flutter build linux --release --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=TU_WKLEJ_PUBLICZNY_KLUCZ
```

W projekcie nie budujemy juz wersji webowej.

## Test smoke przed wyslaniem testerom

1. Uruchom serwer i sprawdz `/healthz`.
2. Uruchom dwie aplikacje na dwoch kontach.
3. Dodaj uzytkownika z listy globalnej do kontaktow.
4. Porownaj safety number poza aplikacja.
5. Wyslij tekst, odpowiedz, edycje, reakcje i plik.
6. Zamknij aplikacje i sprawdz, czy historia zostala lokalnie.
7. Zaloguj to samo konto na drugim urzadzeniu.
8. Sprawdz, czy wiadomosci dochodza na oba urzadzenia.
9. Wejdz w ustawienia i sprawdz liste urzadzen.
10. Uniewaznij stare urzadzenie testowe i upewnij sie, ze nie moze wysylac
    nowych wiadomosci.
11. Sprawdz aktualizacje z poziomu aplikacji.

## Aktualizacje aplikacji

Serwer wystawia:

```text
/updates/manifest.json
/updates/files/
```

Manifest musi byc podpisany Ed25519. Prywatny klucz release trzymaj poza repo i
poza serwerem produkcyjnym. Publiczny klucz jest wbudowywany w klienta przez:

```text
--dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=...
```

Szczegoly sa w [docs/AKTUALIZACJE_PL.md](docs/AKTUALIZACJE_PL.md).

## Zdalny dostep do Raspberry Pi

Najprostsza opcja na wyjazd to Tailscale: Pi i laptop lacza sie do prywatnej
sieci WireGuard, bez wystawiania SSH na publiczny internet i bez dodatkowego
przekierowania portow na routerze.

Skrot:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --hostname szkpn-pi
tailscale ip -4
```

Potem na laptopie z Tailscale:

```powershell
ssh szkpn@ADRES_TAILSCALE_PI
```

Pelna instrukcja jest w [docs/ZDALNY_DOSTEP_PI_PL.md](docs/ZDALNY_DOSTEP_PI_PL.md).

## Administracja zaproszeniami

Przy `REGISTRATION_MODE=invite` jednorazowe zaproszenia tworzy endpoint
`POST /v2/admin/invites` chroniony osobnym `ADMIN_TOKEN`. Serwer zapisuje tylko
hash tokenu, ograniczenie uzyc, termin waznosci i opcjonalny dokladny login.

## Co mowic testerom

Egzekwowany format podpisow, certyfikatow, licznikow i kopert kluczy opisuje
[docs/PROTOCOL_V2.md](docs/PROTOCOL_V2.md).

Mozna mowic:

- To self-hosted szyfrowany komunikator dla malej grupy.
- Wiadomosci i pliki sa szyfrowane przed wyslaniem na serwer.
- Historia jest zaszyfrowana na serwerze i synchronizowana miedzy urzadzeniami.
- Projekt ma juz podpisane tozsamosci, safety number, podpisy urzadzen,
  anty-replay i podpisane aktualizacje.

Nie mowic jeszcze:

- Ze to odpowiednik Signal/WhatsApp pod wzgledem bezpieczenstwa.
- Ze jest odporny na aktywnie zlosliwy lub przejety serwer.
- Ze jest anonimowy.
- Ze nadaje sie dla sygnalistow, prawnikow, lekarzy, finansow lub danych
  regulowanych.
