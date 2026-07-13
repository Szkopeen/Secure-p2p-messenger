# Secure P2P Messenger

Eksperymentalny, wieloplatformowy komunikator z szyfrowaniem end-to-end, klientem Flutter oraz własnym serwerem Relay/Signaling opartym na Node.js.

Projekt obsługuje komunikację na systemach:

* Windows,
* Android,
* Linux.

Klient próbuje zestawić bezpośrednie połączenie WebRTC. Jeżeli połączenie P2P nie jest możliwe, zaszyfrowane pakiety są przesyłane przez serwer relay.

> [!WARNING]
> Projekt nie przeszedł niezależnego audytu bezpieczeństwa. Nie należy używać go do komunikacji wysokiego ryzyka ani traktować jako zamiennika audytowanych komunikatorów takich jak Signal.

## Najważniejsze funkcje

* szyfrowanie treści wiadomości i plików end-to-end,
* lokalna tożsamość użytkownika oparta na Ed25519,
* podpisany handshake z efemerycznymi kluczami X25519,
* wyprowadzanie klucza sesyjnego przez HKDF-SHA256,
* szyfrowanie danych przy użyciu AES-256-GCM,
* bezpośredni transport WebRTC, gdy jest dostępny,
* automatyczny fallback przez relay,
* ograniczona kolejka wiadomości offline,
* przesyłanie plików,
* profile i awatary,
* kontakty i zaproszenia,
* rozmowy grupowe,
* potwierdzenia dostarczenia,
* edycja i wycofywanie wiadomości,
* szyfrowane lokalne archiwum rozmów,
* eksport i import konta chroniony hasłem,
* obsługa wielu urządzeń,
* mechanizm dystrybucji aktualizacji przez relay,
* panel administracyjny relay.

## Struktura projektu

```text
secure-p2p/
├── client/                     # Klient Flutter
│   ├── lib/src/crypto/         # Kryptografia i handshake
│   ├── lib/src/network/        # Połączenie z relay
│   ├── lib/src/p2p/            # Transport WebRTC
│   ├── lib/src/storage/        # Lokalny zapis danych
│   └── lib/src/screens/        # Interfejs użytkownika
├── server/                     # Relay/Signaling w Node.js
│   ├── src/                    # Kod serwera
│   ├── scripts/                # Narzędzia administracyjne
│   ├── data/                   # Dane relay
│   └── updates/                # Pliki aktualizacji
├── docs/
│   ├── DEPLOYMENT_PL.md
│   ├── OD_ZERA_DO_DZIALANIA_PL.md
│   ├── AKTUALIZACJE_PL.md
│   └── FINALNE_BUILDY_PL.md
└── README.md
```

## Jak działa komunikacja

1. Klient generuje lokalną parę kluczy tożsamości Ed25519.
2. Przy rozpoczynaniu sesji klient generuje efemeryczny klucz X25519.
3. Dane handshake są podpisywane kluczem Ed25519.
4. Obie strony wyliczają wspólny sekret X25519.
5. Z sekretu wyprowadzany jest klucz sesyjny przy użyciu HKDF-SHA256.
6. Wiadomości i pliki są szyfrowane za pomocą AES-256-GCM.
7. Klient próbuje przesłać zaszyfrowany pakiet przez WebRTC.
8. Jeżeli P2P nie działa, pakiet jest przekazywany przez relay.
9. Odbiorca weryfikuje i odszyfrowuje pakiet lokalnie.

Serwer relay nie otrzymuje kluczy prywatnych użytkowników ani kluczy sesyjnych potrzebnych do odszyfrowania treści.

## Model bezpieczeństwa

### Co jest szyfrowane end-to-end

Szyfrowanie E2EE obejmuje między innymi:

* treść wiadomości,
* przesyłane pliki,
* dane rozmowy znajdujące się wewnątrz zaszyfrowanego payloadu.

Relay przekazuje zaszyfrowane pakiety, ale nie powinien posiadać informacji potrzebnych do ich odszyfrowania.

### Co widzi operator relay

Operator serwera może zobaczyć lub ustalić między innymi:

* adresy IP klientów,
* identyfikatory użytkowników,
* identyfikatory urządzeń,
* czas połączeń i aktywność użytkowników,
* nadawcę i odbiorcę pakietu,
* rozmiary i częstotliwość pakietów,
* publiczne klucze tożsamości,
* stan obecności,
* profile i awatary,
* wpisy publicznego katalogu użytkowników,
* informacje o zaproszeniach do kontaktów.

E2EE chroni treść komunikacji, ale nie zapewnia anonimowości ani pełnego ukrycia metadanych.

### Dane zapisywane przez relay

W zależności od używanych funkcji relay może przechowywać:

* zaszyfrowane pakiety w ograniczonej kolejce offline,
* publiczne klucze użytkowników,
* znane identyfikatory użytkowników i urządzeń,
* profile oraz awatary,
* publiczny katalog użytkowników,
* listę zablokowanych użytkowników,
* pliki i manifest aktualizacji.

Relay nie powinien przechowywać plaintextu wiadomości ani kluczy prywatnych klientów.

## Weryfikacja kontaktów

Publiczny katalog ułatwia znalezienie użytkownika, ale nie powinien być traktowany jako kryptograficzne potwierdzenie jego tożsamości.

Przed rozpoczęciem poufnej rozmowy należy porównać fingerprint klucza kontaktu za pomocą niezależnego, zaufanego kanału, na przykład:

* osobiście,
* podczas rozmowy telefonicznej,
* przez kod QR,
* za pomocą innego, wcześniej zweryfikowanego kanału komunikacji.

Nieprawidłowo przypięty klucz może umożliwić atak typu man-in-the-middle podczas pierwszego kontaktu.

## Aktualne ograniczenia bezpieczeństwa

### Uwierzytelnianie użytkownika na relay

`RELAY_TOKEN` jest wspólnym tokenem dostępu do serwera. Nie jest kluczem szyfrującym wiadomości i nie potwierdza kryptograficznie tożsamości konkretnego użytkownika.

Aktualna wersja nie wiąże jeszcze `userId` z kluczem publicznym za pomocą serwerowego mechanizmu challenge-response. Osoba posiadająca token relay może próbować zarejestrować połączenie z cudzym identyfikatorem.

Z tego powodu niezależna weryfikacja fingerprintów kontaktów jest obowiązkowa dla rozmów wymagających poufności.

### Brak Double Ratchet

Projekt nie implementuje obecnie protokołu Double Ratchet ani ratchetingu klucza po każdej wiadomości.

Klucze sesyjne mogą być zapisane lokalnie i ponownie użyte po restarcie aplikacji. Oznacza to, że projekt nie zapewnia forward secrecy na poziomie każdej wiadomości ani post-compromise security porównywalnego z protokołem Signal.

### Ochrona przed replay

Aktualna implementacja nie powinna być traktowana jako posiadająca kompletną ochronę przed powtórnym dostarczeniem wcześniej poprawnego, zaszyfrowanego pakietu.

Przed użyciem produkcyjnym należy wprowadzić trwałe liczniki wiadomości lub okno zaakceptowanych numerów sekwencyjnych.

### Aktualizacje aplikacji

Relay może udostępniać pliki aktualizacji oraz manifest zawierający sumy SHA-256.

Suma SHA-256 chroni przed przypadkowym uszkodzeniem lub podmianą samego pliku, ale nie zabezpiecza przed przejęciem serwera, jeżeli atakujący może zmienić jednocześnie plik i manifest.

Aktualny manifest nie posiada niezależnego podpisu kryptograficznego. Mechanizmu aktualizacji nie należy uznawać za bezpieczny łańcuch dostaw do czasu wdrożenia podpisanych manifestów i osadzonego w aplikacji klucza wydawniczego.

### Bezpieczeństwo urządzenia końcowego

Projekt nie chroni wiadomości przed:

* złośliwym oprogramowaniem na urządzeniu,
* przejęciem odblokowanego telefonu lub komputera,
* rejestratorami klawiatury,
* przechwytywaniem obrazu ekranu,
* błędami systemu operacyjnego,
* wyciekiem danych przed zaszyfrowaniem lub po odszyfrowaniu.

## Transport P2P

Klient wykorzystuje WebRTC do próby zestawienia bezpośredniego połączenia między urządzeniami.

Bez odpowiedniej konfiguracji STUN/TURN połączenie P2P może nie działać w części sieci NAT, sieciach komórkowych lub sieciach firmowych. W takim przypadku komunikacja automatycznie przechodzi przez relay jako zaszyfrowane pakiety.

Projekt należy więc rozumieć jako:

> komunikator E2EE z oportunistycznym transportem P2P i fallbackiem przez relay.

Nie jest to system gwarantujący bezpośrednie połączenie w każdej konfiguracji sieciowej.

## Wymagania

### Relay

* Node.js 20 lub nowszy,
* npm,
* publiczny adres IP lub domena dla dostępu przez internet,
* reverse proxy z TLS, na przykład Caddy lub nginx.

### Klient

* Flutter SDK,
* Dart SDK zgodny z konfiguracją projektu,
* Visual Studio z modułem Desktop development with C++ dla Windows,
* Android Studio i Android SDK dla Androida,
* GTK, CMake, Ninja oraz wymagane biblioteki systemowe dla Linuxa.

## Szybkie uruchomienie relay

Sklonuj repozytorium:

```bash
git clone https://github.com/Szkopeen/secure-p2p.git
cd secure-p2p/server
```

Zainstaluj zależności:

```bash
npm install
```

Utwórz konfigurację:

```bash
cp .env.example .env
```

W PowerShell:

```powershell
Copy-Item .env.example .env
```

Wygeneruj bezpieczne tokeny:

```bash
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
```

Wygeneruj osobny token dla:

* `RELAY_TOKEN`,
* `ADMIN_TOKEN`.

Nie używaj tego samego sekretu w obu polach.

Minimalna konfiguracja:

```env
HOST=127.0.0.1
PORT=8443

RELAY_TOKEN=WKLEJ_LOSOWY_TOKEN_MINIMUM_32_ZNAKI
ADMIN_TOKEN=WKLEJ_INNY_LOSOWY_TOKEN_MINIMUM_32_ZNAKI

MAX_PAYLOAD_BYTES=16777216
RATE_LIMIT_MESSAGES=80
RATE_LIMIT_WINDOW_MS=10000
MAX_CONNECTIONS_PER_USER=12

SECURITY_LOGS=false
```

Uruchom relay:

```bash
npm start
```

Sprawdź endpoint zdrowia:

```bash
curl http://127.0.0.1:8443/healthz
```

Oczekiwana odpowiedź:

```json
{
  "ok": true,
  "time": "..."
}
```

## TLS i publiczne wdrożenie

Do komunikacji przez internet używaj wyłącznie:

```text
wss://
https://
```

Nie przesyłaj `RELAY_TOKEN` przez publiczne połączenie `ws://`.

Przykładowa konfiguracja Caddy:

```caddyfile
chat.example.com {
    reverse_proxy 127.0.0.1:8443

    header {
        -Server
    }
}
```

Adres wpisywany w kliencie:

```text
wss://chat.example.com
```

Połączenia `ws://` powinny być używane wyłącznie podczas testów w kontrolowanej sieci lokalnej.

Szczegółowa instrukcja wdrożenia znajduje się w:

```text
docs/OD_ZERA_DO_DZIALANIA_PL.md
```

## Uruchomienie klienta

Przejdź do katalogu klienta:

```bash
cd client
```

Jeżeli katalogi platform Flutter nie zostały jeszcze wygenerowane:

```bash
flutter create . --platforms=windows,android,linux
```

Pobierz zależności:

```bash
flutter pub get
```

Sprawdź projekt:

```bash
flutter analyze
flutter test
```

Uruchom klienta na Windows:

```bash
flutter run -d windows
```

Uruchom klienta na podłączonym urządzeniu Android:

```bash
flutter run -d android
```

Uruchom klienta na Linuxie:

```bash
flutter run -d linux
```

## Pierwsza rozmowa

1. Uruchom relay.
2. Uruchom aplikację na pierwszym urządzeniu.
3. Ustaw unikalny `userId`.
4. Wprowadź adres relay.
5. Wprowadź `RELAY_TOKEN`.
6. Utwórz lokalną tożsamość.
7. Powtórz kroki na drugim urządzeniu z innym `userId`.
8. Wymieńcie fingerprinty kluczy publicznych niezależnym kanałem.
9. Dodajcie siebie nawzajem jako kontakty.
10. Porównajcie fingerprinty.
11. Wyślijcie pierwszą wiadomość.

Klient zestawi sesję E2EE i spróbuje wykorzystać WebRTC. Jeżeli bezpośredni transport nie będzie dostępny, wiadomość zostanie przesłana przez relay.

## Budowanie wersji release

### Windows

```powershell
cd client
flutter clean
flutter pub get
flutter build windows --release
```

Wynik:

```text
client\build\windows\x64\runner\Release\
```

Należy dystrybuować cały katalog `Release`, a nie tylko plik `.exe`.

### Android

```powershell
cd client
flutter clean
flutter pub get
flutter build apk --release
```

Wynik:

```text
client\build\app\outputs\flutter-apk\app-release.apk
```

Przed publiczną dystrybucją aplikacja Android powinna zostać podpisana własnym kluczem wydawniczym.

### Linux

```bash
cd client
flutter clean
flutter pub get
flutter build linux --release
```

Wynik:

```text
client/build/linux/x64/release/bundle/
```

Flutter nie obsługuje standardowego cross-compilingu desktopowej wersji Linux z Windows. Wersję Linux należy budować na Linuxie.

## Testy i kontrola jakości

Serwer:

```bash
cd server
npm run check
```

Klient:

```bash
cd client
flutter analyze
flutter test
```

Przed publikacją wersji należy ręcznie przetestować co najmniej:

* zestawienie dwóch klientów,
* odrzucenie niepoprawnego klucza kontaktu,
* wiadomości online,
* kolejkę offline,
* wysyłanie plików,
* ponowne uruchomienie klienta,
* działanie WebRTC,
* fallback przez relay,
* pracę na wielu urządzeniach,
* uszkodzony lub zmodyfikowany szyfrogram,
* przekroczenie limitu pakietu,
* wygaśnięcie wiadomości offline.

## Zalecenia dla administratora relay

* używaj wyłącznie `wss://` w internecie,
* trzymaj relay za reverse proxy,
* uruchamiaj Node.js jako osobny, nieuprzywilejowany użytkownik,
* nie publikuj pliku `.env`,
* używaj różnych tokenów dla relay i panelu administratora,
* ogranicz dostęp do endpointów administracyjnych,
* regularnie aktualizuj Node.js i zależności,
* wykonuj kopie danych relay,
* nie loguj zawartości payloadów,
* monitoruj zużycie dysku przez kolejki offline i aktualizacje,
* zmień tokeny po podejrzeniu kompromitacji,
* ogranicz publicznie dostępne porty do niezbędnego minimum.

## Domyślne ograniczenia

* pojedynczy plik ma domyślny limit około 8 MB przed szyfrowaniem,
* Base64 i dane protokołu zwiększają końcowy rozmiar pakietu,
* relay posiada limit rozmiaru pojedynczego payloadu,
* kolejka offline ma limit liczby elementów i czasu przechowywania,
* WebRTC może wymagać własnego STUN/TURN,
* trwałe dane serwera są obecnie przechowywane w plikach JSON,
* obecna architektura relay jest przeznaczona głównie dla małych, samodzielnie hostowanych instalacji,
* projekt nie został zaprojektowany jako anonimowa sieć komunikacyjna.

## Planowane usprawnienia bezpieczeństwa

Najważniejsze planowane lub zalecane zmiany:

* challenge-response podczas logowania do relay,
* kryptograficzne powiązanie `userId` z kluczem publicznym,
* bezpieczna procedura zmiany klucza tożsamości,
* ochrona przed replay za pomocą numerów sekwencyjnych,
* rotacja kluczy sesyjnych,
* Double Ratchet lub inny audytowany protokół wiadomości,
* podpisane manifesty aktualizacji,
* trwała baza danych zamiast plików JSON,
* atomowe operacje zapisu,
* rate limiting per IP i per tożsamość,
* rozszerzone testy protokołu,
* automatyczne testy CI,
* niezależny audyt bezpieczeństwa.

## Dokumentacja

* [`docs/DEPLOYMENT_PL.md`](docs/DEPLOYMENT_PL.md) — skrócona instrukcja wdrożenia.
* [`docs/OD_ZERA_DO_DZIALANIA_PL.md`](docs/OD_ZERA_DO_DZIALANIA_PL.md) — pełna instrukcja uruchomienia.
* [`docs/AKTUALIZACJE_PL.md`](docs/AKTUALIZACJE_PL.md) — publikowanie aktualizacji.
* [`docs/FINALNE_BUILDY_PL.md`](docs/FINALNE_BUILDY_PL.md) — przygotowywanie paczek release.

## Zgłaszanie problemów

Błędy funkcjonalne można zgłaszać przez GitHub Issues.

Nie publikuj w zgłoszeniach:

* tokenów relay,
* tokenów administratora,
* prywatnych kluczy,
* plików `.env`,
* danych prawdziwych użytkowników,
* niezanonimizowanych logów produkcyjnych.

W przypadku znalezienia podatności bezpieczeństwa nie publikuj od razu pełnego exploita ani danych umożliwiających atak na działającą instancję.

## Status projektu

Projekt znajduje się na etapie rozwoju i testów.

Jest przeznaczony przede wszystkim do:

* nauki kryptografii aplikacyjnej,
* eksperymentowania z WebRTC,
* testowania architektury self-hosted,
* rozwoju klienta Flutter,
* prototypowania komunikatora E2EE.

Nie jest obecnie rekomendowany do ochrony informacji, których ujawnienie mogłoby powodować poważne konsekwencje prawne, finansowe lub osobiste.

## Licencja

Projekt jest udostępniany na licencji [GNU Affero General Public License v3.0](LICENSE).

W przypadku uruchamiania zmodyfikowanej wersji projektu jako usługi sieciowej należy zapoznać się z obowiązkami wynikającymi z licencji AGPL-3.0.
