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
ryzyka. Szczegoly sa w [docs/SECURITY_ROADMAP_PL.md](docs/SECURITY_ROADMAP_PL.md)
i [docs/THREAT_MODEL_PL.md](docs/THREAT_MODEL_PL.md).

## Status projektu

- Tryb aktywnego P2P/WebRTC zostal usuniety z klienta.
- Web build nie jest juz zakresem projektu.
- Obslugiwane platformy klienta: Windows, Android, Linux.
- Backend jest lekki, oparty o Node.js i SQLite w trybie WAL.
- Techniczna nazwa paczki Flutter nadal brzmi `secure_p2p_messenger`.

## Struktura repozytorium

- `client/` - aplikacja Flutter dla Windows, Android i Linux.
- `server/` - serwer Node.js: konta, WebSocket, zaszyfrowana historia,
  aktualizacje, wyszukiwanie po dokladnym loginie i API administracyjne.
- `docs/OD_ZERA_DO_DZIALANIA_PL.md` - instalacja serwera od zera na Ubuntu/RPi.
- `docs/DEPLOYMENT_PL.md` - wdrozenie i usluga systemd.
- `docs/AKTUALIZACJE_PL.md` - publikowanie aktualizacji aplikacji.
- `docs/FINALNE_BUILDY_PL.md` - komendy do tworzenia buildow.
- `docs/RELEASE_PROCESS_PL.md` - powtarzalny, podpisany proces wydawniczy.
- `docs/SECURITY_ROADMAP_PL.md` - aktualny model zaufania i roadmapa security.
- `docs/THREAT_MODEL_PL.md` - pelny model zagrozen aktualnej wersji.
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
SQLite WAL w V2_DATA_DIR: konta, sesje, vaulty, rozmowy, zaproszenia,
wiadomosci, kolejki i metadane aktualizacji
```

Serwer dostarcza synchronizacje i przechowywanie, ale tresc wiadomosci oraz
plikow jest szyfrowana po stronie klienta. Serwer widzi jednak metadane
techniczne: konta, relacje, rozmiary pakietow, czas komunikacji i adresy IP.
Projekt nie zapewnia anonimowosci.

## Funkcje aplikacji

- Rejestracja i logowanie kont.
- Osobny sekret vaultu, oddzielony od hasla logowania.
- Synchronizacja wielu urzadzen jednego konta.
- Wyszukiwanie kontaktu po dokladnym loginie, bez globalnej listy kont.
- Rozmowy 1:1; grupy sa wylaczone do czasu wdrozenia bezpiecznego protokolu
  grupowego.
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
- Klient odrzuca identyczne haslo konta i sekret vaultu po podstawowej
  normalizacji wejscia.
- Haslo konta jest wysylane do serwera jako haslo logowania, ale tylko przez
  HTTPS poza localhostem. Nie jest uzywane jako sekret vaultu.
- Sekret vaultu nie jest wysylany do API.
- Klient nie wysyla lokalnego hostname jako nazwy urzadzenia. Serwer akceptuje
  tylko neutralne nazwy typu `Windows device`, `Linux device`, `Android device`
  albo `Device` i anonimizuje starsze wpisy przy starcie.
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
- Nowe wiadomosci wyprowadzaja osobny klucz AEAD przez HKDF-SHA256 z klucza
  rozmowy, epoki, licznika, ID wiadomosci i poprzedniego hasha. To ogranicza
  reuse klucza wiadomosci, ale nie jest pelnym Double Ratchet.
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
- Manifest i artefakty aktualizacji sa podawane bez podazania za symlinkami i
  po sprawdzeniu, ze finalna sciezka zostaje w katalogu aktualizacji.

## Znane ograniczenia

- SQLite w trybie WAL wystarcza dla malej self-hosted instancji, ale duza
  publiczna usluga wymaga osobnego planu skalowania, testow restore i
  prawdopodobnie migracji do PostgreSQL albo wydzielonego workera storage.
- Pierwsze dodanie kontaktu nadal wymaga zaufania do danych z serwera do czasu
  porownania safety number poza serwerem.
- Nie ma jeszcze publicznego key transparency logu.
- Nie ma jeszcze OPAQUE ani innego protokolu logowania, ktory kryptograficznie
  ukrywa haslo logowania przed aktywnie zlosliwym serwerem.
- Nie ma jeszcze Double Ratchet ani MLS, wiec forward secrecy i
  post-compromise security sa ograniczone.
- Brak Double Ratchet/PQXDH, key transparency oraz OPAQUE/PAKE jest blokada dla
  scenariuszy wysokiego ryzyka. Nie wolno opisywac tej wersji jako odpornej na
  zlosliwy serwer albo porownywalnej z Signalem, dopoki te protokoly nie beda
  wdrozone i audytowane.
- Blokada PIN chroni interfejs po powrocie do aplikacji. Nie opakowuje jeszcze
  lokalnych kluczy dodatkowa warstwa kryptograficzna; integracja z Android
  Keystore, biometria, DPAPI i Secret Service/KWallet pozostaje roadmapa.
- Uniewaznienie urzadzenia blokuje nowe wiadomosci i sesje oraz rotuje klucze
  rozmow 1:1. Grupy pozostaja wylaczone do czasu wdrozenia bezpiecznego MLS
  albo audytowanego protokolu sender-key.
- Kopie danych serwera zawieraja zaszyfrowane, ale wrazliwe dane uzytkownikow.
- Projekt wymaga dalszych testow integracyjnych, migracji i audytu przed uzyciem
  w sytuacjach wysokiego ryzyka.

## Uruchomienie serwera

Minimalnie:

```bash
cd /srv/secure-chat/server
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
SESSION_TTL_HOURS=72
SESSION_IDLE_TTL_HOURS=24
METRICS_ALLOWED_IPS=127.0.0.1,::1,::ffff:127.0.0.1
METRICS_STORAGE_CACHE_SECONDS=15
MAX_CONNECTIONS_PER_USER=12
V2_DATA_DIR=/srv/secure-chat/server/data-v2
UPDATE_MANIFEST_FILE=/srv/secure-chat/server/updates/manifest.json
UPDATE_FILES_DIR=/srv/secure-chat/server/updates/files
```

W normalnym wdrozeniu Node.js slucha lokalnie na `127.0.0.1:8443`, a publiczny
TLS robi Caddy:

```text
https://chat.example.com -> Caddy -> 127.0.0.1:8443
```

Diagnostyka na serwerze:

```bash
sudo systemctl status secure-p2p --no-pager
sudo journalctl -u secure-p2p -n 100 --no-pager
sudo systemctl status caddy --no-pager
curl https://chat.example.com/healthz
curl -H "x-admin-token: $ADMIN_TOKEN" http://127.0.0.1:8443/metrics
```

`/healthz` jest publicznym, prostym liveness checkiem i zwraca tylko status
OK. Szczegolowe metryki KDF i storage sa pod `/metrics`, wymagaja
`x-admin-token`, adresu z `METRICS_ALLOWED_IPS` i cache'uja kosztowne dane
storage.

## Backup i restore SQLite

Aktywne dane cloud sa w `V2_DATA_DIR`, domyslnie:

```text
/srv/secure-chat/server/data-v2/secure-chat.sqlite
/srv/secure-chat/server/data-v2/secure-chat.sqlite-wal
/srv/secure-chat/server/data-v2/secure-chat.sqlite-shm
```

Do kopii online uzyj skryptu serwera:

```bash
cd /srv/secure-chat/server
npm run backup-sqlite -- --out /backup/secure-chat.sqlite
```

Do kopii offline zatrzymaj usluge, skopiuj plik `.sqlite` razem z `.sqlite-wal`
i `.sqlite-shm`, a potem uruchom usluge ponownie. Restore wykonuj na komplecie
plikow z tej samej chwili albo z pliku utworzonego przez `.backup`.

## Build klienta

Przygotowanie:

```powershell
cd client
flutter pub get
dart analyze
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
3. Wyszukaj drugi login dokladnie i dodaj go do kontaktow.
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

Szczegoly sa w [docs/AKTUALIZACJE_PL.md](docs/AKTUALIZACJE_PL.md) i
[docs/RELEASE_PROCESS_PL.md](docs/RELEASE_PROCESS_PL.md).

## Zdalny dostep do Raspberry Pi

Najprostsza opcja na wyjazd to Tailscale: Pi i laptop lacza sie do prywatnej
sieci WireGuard, bez wystawiania SSH na publiczny internet i bez dodatkowego
przekierowania portow na routerze.

Skrot:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --hostname secure-chat-server
tailscale ip -4
```

Potem na laptopie z Tailscale:

```powershell
ssh user@TAILSCALE_IP
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
  regulowanych
