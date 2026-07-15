# Secure P2P Messenger - instrukcja od zera do dzialania

Ten dokument prowadzi przez caly proces: instalacja systemu na serwerze, uruchomienie relay, konfiguracja sieci, zbudowanie aplikacji oraz pierwszy test rozmowy E2EE.

Zakladany wariant produkcyjny:

- Serwer domowy: Ubuntu Server 24.04 LTS lub nowszy, staly dostep do internetu.
- Relay: Node.js uruchomiony jako usluga systemd.
- Publiczny dostep: domena, HTTPS/WSS przez Caddy.
- Klient: Flutter budowany dla Windows, Android i Linux.

Do testow lokalnych mozesz uruchomic serwer bez domeny i TLS tylko na
`ws://localhost:8443`, `ws://127.0.0.1:8443` albo `http://localhost:8443`.
Nie uzywaj `ws://ADRES_IP:8443` przez LAN, bo legacy relay przesyla
`RELAY_TOKEN` po zestawieniu WebSocket. Dla Raspberry Pi, LAN i internetu uzywaj
TLS przez Caddy, czyli `https://twoja-domena` w cloud albo `wss://twoja-domena`
w starym relay.

## 1. Co przygotowac

Lista kontrolna:

- Komputer domowy albo mini-PC na serwer.
- Publiczny adres IP albo domena z rekordem DNS kierujacym na dom.
- Dostep do panelu routera.
- Pendrive z instalatorem Ubuntu Server.
- Komputer developerski z Windows do budowy aplikacji Flutter.
- Kopia tego projektu.

Porty:

- `443/TCP` - publicznie, gdy uzywasz Caddy i `wss://`.
- `8443/TCP` - tylko lokalnie na serwerze, za reverse proxy.
- Nie wystawiaj paneli administracyjnych routera ani SSH do internetu bez dodatkowego hardeningu.

## 2. Instalacja systemu serwera

1. Pobierz obraz Ubuntu Server LTS.
2. Nagraj obraz na pendrive, np. przez Rufus albo balenaEtcher.
3. Uruchom serwer z pendrive.
4. W instalatorze wybierz:
   - minimalna instalacja serwera,
   - OpenSSH Server wlaczony tylko wtedy, gdy chcesz zarzadzac zdalnie,
   - konto uzytkownika bez nazwy `root`, np. `relayadmin`,
   - automatyczne aktualizacje bezpieczenstwa, jesli instalator to proponuje.
5. Po instalacji zaloguj sie lokalnie albo przez SSH w sieci LAN.

Zaktualizuj system:

```bash
sudo apt update
sudo apt upgrade -y
sudo reboot
```

Po restarcie zainstaluj podstawowe narzedzia:

```bash
sudo apt install -y curl ca-certificates git ufw unzip
```

## 3. Konto systemowe dla relay

Utworz osobnego uzytkownika bez logowania interaktywnego:

```bash
sudo useradd --system --create-home --home-dir /opt/secure-p2p --shell /usr/sbin/nologin securep2p
```

Utworz katalog aplikacji:

```bash
sudo mkdir -p /opt/secure-p2p/app
sudo chown -R securep2p:securep2p /opt/secure-p2p
```

## 4. Instalacja Node.js

Wymagany jest Node.js 20 lub nowszy.

Na Ubuntu najprosciej uzyc pakietu `nodejs`, jesli wersja w repozytorium spelnia wymaganie:

```bash
sudo apt install -y nodejs npm
node --version
npm --version
```

Jesli `node --version` pokazuje wersje starsza niz 20, zainstaluj aktualna wersje Node.js z oficjalnego zrodla Node.js albo przez menedzer wersji. Po instalacji ponownie sprawdz:

```bash
node --version
npm --version
```

## 5. Przeniesienie projektu na serwer

Wariant A - masz repozytorium Git:

```bash
sudo -u securep2p git clone ADRES_TWOJEGO_REPO /opt/secure-p2p/app
```

Wariant B - kopiujesz katalog projektu z komputera Windows:

```powershell
scp -r "C:\Users\ulkhh\Documents\New project" relayadmin@ADRES_SERWERA:/tmp/secure-p2p
```

Potem na serwerze:

```bash
sudo rsync -a /tmp/secure-p2p/ /opt/secure-p2p/app/
sudo chown -R securep2p:securep2p /opt/secure-p2p/app
```

## 6. Konfiguracja relay

Wejdz do katalogu serwera:

```bash
cd /opt/secure-p2p/app/server
```

Zainstaluj zaleznosci:

```bash
sudo -u securep2p npm install --omit=dev
```

Utworz plik konfiguracyjny:

```bash
sudo -u securep2p cp .env.example .env
```

Wygeneruj silny token:

```bash
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
```

Edytuj `.env`:

```bash
sudo -u securep2p nano .env
```

Ustaw minimum:

```env
HOST=127.0.0.1
PORT=8443
RELAY_TOKEN=TU_WKLEJ_WYGENEROWANY_TOKEN
MAX_PAYLOAD_BYTES=16777216
RATE_LIMIT_MESSAGES=80
RATE_LIMIT_WINDOW_MS=10000
MAX_CONNECTIONS_PER_USER=12
SECURITY_LOGS=false
V2_DATA_DIR=/opt/secure-p2p/app/server/data-v2
```

Wazne:

- `HOST=127.0.0.1` oznacza, ze relay slucha tylko lokalnie, a publiczny ruch przyjmie Caddy.
- `RELAY_TOKEN` nie szyfruje wiadomosci. To tylko przepustka do relay.
- Nie wysylaj pliku `.env` nikomu i nie dodawaj go do repozytorium.

Test uruchomienia recznego:

```bash
sudo -u securep2p npm start
```

W drugim terminalu:

```bash
curl http://127.0.0.1:8443/healthz
```

Oczekiwany wynik:

```json
{"ok":true,"time":"..."}
```

Zatrzymaj test reczny klawiszami `Ctrl+C`.

## 7. Usluga systemd

Utworz plik uslugi:

```bash
sudo nano /etc/systemd/system/secure-p2p-relay.service
```

Wklej:

```ini
[Unit]
Description=Secure P2P WebSocket Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=securep2p
Group=securep2p
WorkingDirectory=/opt/secure-p2p/app/server
Environment=NODE_ENV=production
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/secure-p2p/app/server

[Install]
WantedBy=multi-user.target
```

Wlacz usluge:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now secure-p2p-relay
sudo systemctl status secure-p2p-relay
```

Logi techniczne:

```bash
journalctl -u secure-p2p-relay -f
```

## 8. Caddy i WSS

Caddy daje automatyczny TLS i zamienia publiczne `https://twoja-domena` /
`wss://twoja-domena` na lokalne polaczenie do `127.0.0.1:8443`.

Instalacja:

```bash
sudo apt install -y caddy
```

Skonfiguruj domene DNS:

- Rekord `A`: `chat.twojadomena.pl` -> publiczny adres IPv4 domu.
- Opcjonalnie rekord `AAAA`, jesli masz IPv6.

Edytuj Caddyfile:

```bash
sudo nano /etc/caddy/Caddyfile
```

Wklej:

```caddyfile
chat.twojadomena.pl {
  reverse_proxy 127.0.0.1:8443

  header {
    -Server
  }
}
```

Sprawdz i przeladuj:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo systemctl status caddy
```

Test:

```bash
curl https://chat.twojadomena.pl/healthz
```

Adres relay dla aplikacji:

```text
wss://chat.twojadomena.pl
```

## 9. Router i firewall

Na serwerze wlacz firewall:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 443/tcp
sudo ufw allow from 192.168.0.0/16 to any port 22 proto tcp
sudo ufw enable
sudo ufw status verbose
```

Jesli Twoja siec LAN uzywa innego zakresu niz `192.168.0.0/16`, dopasuj regule SSH.

Na routerze:

1. Ustaw staly adres LAN dla serwera, np. `192.168.1.10`.
2. Przekieruj `443/TCP` z internetu na `192.168.1.10:443`.
3. Nie przekierowuj `8443`, jesli uzywasz Caddy.
4. Wylacz publiczny panel administracyjny routera.

## 10. Instalacja narzedzi do budowy aplikacji na Windows

Na komputerze developerskim z Windows zainstaluj:

- Git for Windows.
- Flutter SDK.
- Visual Studio z obciazeniem "Desktop development with C++".
- Android Studio z Android SDK, jesli budujesz APK.
- Narzedzia Linux desktop, jesli budujesz wersje Linux na maszynie z Linuxem.

Po instalacji otworz PowerShell i sprawdz:

```powershell
flutter doctor
```

Zaakceptuj licencje Androida:

```powershell
flutter doctor --android-licenses
```

## 11. Przygotowanie klienta Flutter

Wejdz do katalogu klienta:

```powershell
cd "C:\Users\ulkhh\Documents\New project\client"
```

Wygeneruj katalogi platform Flutter:

```powershell
flutter create . --platforms=windows,android,linux
```

Pobierz zaleznosci:

```powershell
flutter pub get
```

Sprawdz projekt:

```powershell
flutter analyze
```

Uruchom na Windows:

```powershell
flutter run -d windows
```

## 12. Budowanie aplikacji

### Windows

```powershell
cd "C:\Users\ulkhh\Documents\New project\client"
flutter build windows --release
```

Gotowa aplikacja:

```text
client\build\windows\x64\runner\Release\
```

Skopiuj caly katalog `Release` na komputer docelowy.

### Android

```powershell
cd "C:\Users\ulkhh\Documents\New project\client"
flutter build apk --release
```

Gotowy plik:

```text
client\build\app\outputs\flutter-apk\app-release.apk
```

Zainstaluj APK na telefonie:

```powershell
adb install -r .\build\app\outputs\flutter-apk\app-release.apk
```

Jesli nie uzywasz `adb`, przenies APK na telefon i zainstaluj recznie. Android moze poprosic o zgode na instalacje z nieznanego zrodla.

### Linux

Wersje Linux najlepiej budowac na komputerze z Linuxem.

```bash
cd ~/secure-p2p/client
flutter build linux --release
```

Gotowy katalog:

```text
client/build/linux/x64/release/bundle/
```

## 13. Pierwsze spiecie dwoch uzytkownikow

Przyklad:

- Uzytkownik A: `alice`
- Uzytkownik B: `bob`
- Relay: `wss://chat.twojadomena.pl`

Na pierwszym urzadzeniu:

1. Otworz aplikacje.
2. Wpisz `alice`.
3. Wpisz adres relay: `wss://chat.twojadomena.pl`.
4. Wpisz ten sam `RELAY_TOKEN`, ktory jest w `/opt/secure-p2p/app/server/.env`.
5. Kliknij utworzenie tozsamosci.
6. Skopiuj klucz publiczny Alice.

Na drugim urzadzeniu:

1. Otworz aplikacje.
2. Wpisz `bob`.
3. Wpisz ten sam adres relay.
4. Wpisz ten sam `RELAY_TOKEN`.
5. Skopiuj klucz publiczny Boba.

Wymiencie klucze publiczne kanalem poza aplikacja, np. osobiscie, przez QR, przez zaufany komunikator albo telefonicznie z odczytem fragmentow.

W aplikacji Alice:

1. Dodaj kontakt.
2. `Identyfikator`: `bob`.
3. `Klucz publiczny`: klucz Boba.

W aplikacji Boba:

1. Dodaj kontakt.
2. `Identyfikator`: `alice`.
3. `Klucz publiczny`: klucz Alice.

Test:

1. Alice wysyla wiadomosc do Boba.
2. Aplikacja zestawia handshake E2EE.
3. Klient probuje WebRTC P2P.
4. Jesli P2P sie uda, status rozmowy pokaze `P2P`.
5. Jesli NAT blokuje P2P, wiadomosci ida przez relay jako zaszyfrowane pakiety.

Relay nadal nie moze odczytac tresci wiadomosci ani plikow.

## 14. Jak to dziala technicznie

1. Kazdy klient generuje lokalna tozsamosc Ed25519.
2. Klucz publiczny Ed25519 trzeba recznie przypiac do kontaktu.
3. Gdy zaczyna sie rozmowa, klient tworzy efemeryczny klucz X25519.
4. Handshake jest podpisany kluczem Ed25519, aby utrudnic podmiane.
5. Obie strony wyliczaja wspolny sekret X25519.
6. HKDF-SHA256 tworzy klucz sesyjny AES-256.
7. Tekst lub plik jest kompresowany i szyfrowany AES-256-GCM.
8. Serwer widzi tylko koperte transportowa i zaszyfrowany payload.
9. Po nowej sesji powstaje nowy klucz, co daje Perfect Forward Secrecy dla kolejnych rozmow.

## 15. Codzienna obsluga

Status relay:

```bash
sudo systemctl status secure-p2p-relay
```

Restart relay:

```bash
sudo systemctl restart secure-p2p-relay
```

Aktualizacja kodu z repozytorium:

```bash
cd /opt/secure-p2p/app
sudo -u securep2p git pull
cd server
sudo -u securep2p npm install --omit=dev
sudo systemctl restart secure-p2p-relay
```

Aktualizacja systemu:

```bash
sudo apt update
sudo apt upgrade -y
sudo reboot
```

Rotacja tokenu relay:

1. Wygeneruj nowy token:

```bash
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
```

2. Wpisz go do `/opt/secure-p2p/app/server/.env`.
3. Zrestartuj usluge:

```bash
sudo systemctl restart secure-p2p-relay
```

4. W aplikacjach klientow wyczysc dane lokalne albo ustaw nowy token przy ponownej konfiguracji.

## 16. Diagnostyka

Relay nie startuje:

```bash
journalctl -u secure-p2p-relay -n 100 --no-pager
```

Sprawdz `.env`:

- `RELAY_TOKEN` ma minimum 32 znaki.
- `PORT` nie jest zajety.
- `HOST=127.0.0.1`, jesli uzywasz Caddy.

Domena nie dziala:

```bash
dig chat.twojadomena.pl
curl -v https://chat.twojadomena.pl/healthz
sudo systemctl status caddy
```

Aplikacja nie laczy sie z relay:

- W aktualnym trybie cloud wpisuj `https://chat.twojadomena.pl`.
- W starym trybie relay wpisuj `wss://chat.twojadomena.pl`, nie `ws://`.
- Sprawdz, czy token w aplikacji jest identyczny jak `RELAY_TOKEN`.
- Sprawdz czas systemowy na telefonie/komputerze.
- Sprawdz firewall i przekierowanie portu `443/TCP`.

P2P nie laczy sie:

- To normalne przy czesci NAT.
- Wiadomosci nadal powinny dzialac przez relay fallback.
- Jesli chcesz poprawic skutecznosc P2P, dodaj wlasny STUN/TURN w kodzie `WebRtcTransport`.

Pliki nie przechodza:

- Domyslny limit pliku po stronie klienta to 8 MB przed szyfrowaniem.
- Relay ma limit `MAX_PAYLOAD_BYTES`.
- Pamietaj, ze base64 i metadane powiekszaja pakiet.

## 17. Demontaz albo przeniesienie

Zatrzymanie relay:

```bash
sudo systemctl stop secure-p2p-relay
```

Wylaczenie autostartu:

```bash
sudo systemctl disable secure-p2p-relay
```

Usuniecie uslugi:

```bash
sudo rm /etc/systemd/system/secure-p2p-relay.service
sudo systemctl daemon-reload
```

Przeniesienie na nowy serwer:

1. Skopiuj kod projektu.
2. Skopiuj albo odtworz `/opt/secure-p2p/app/server/.env`.
3. Zainstaluj zaleznosci.
4. Odtworz usluge systemd.
5. Przekieruj DNS/router na nowy serwer.

Jesli podejrzewasz kompromitacje starego serwera, nie przenos starego tokenu. Wygeneruj nowy `RELAY_TOKEN` i skonfiguruj klientow od nowa.

## 18. Minimalny test koncowy

Po wdrozeniu powinny przejsc te testy:

```bash
curl http://127.0.0.1:8443/healthz
curl https://chat.twojadomena.pl/healthz
sudo systemctl status secure-p2p-relay
sudo systemctl status caddy
```

W aplikacji:

1. Dwoch roznych uzytkownikow laczy sie z tym samym relay.
2. Obie strony maja wzajemnie dodane poprawne klucze publiczne.
3. Wiadomosc tekstowa przechodzi.
4. Maly plik przechodzi.
5. Po restarcie aplikacji nowa rozmowa tworzy nowa sesje E2EE.

Gdy wszystkie punkty dzialaja, system jest spiety od poczatku do konca.
