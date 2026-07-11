# Instrukcja wdrozenia

## 1. Serwer Relay/Signaling

Wymagania:

- Node.js 20 lub nowszy
- Publiczny adres IP albo domena wskazujaca na komputer domowy
- Przekierowany port na routerze, np. `8443`
- Docelowo TLS przez reverse proxy, np. Caddy albo nginx

Uruchomienie:

```powershell
cd server
Copy-Item .env.example .env
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
```

Wklej wygenerowany sekret do `RELAY_TOKEN` w pliku `.env`.

```powershell
npm install
npm start
```

Test zdrowia:

```powershell
curl http://127.0.0.1:8443/healthz
```

### TLS i publiczny adres

Do testow w LAN mozesz uzyc `ws://ADRES_IP:8443`. Dla internetu uzywaj `wss://`, bo token relay i WebRTC/Web wymagaja bezpiecznego kontekstu.

Przyklad Caddy:

```caddyfile
chat.example.com {
  reverse_proxy 127.0.0.1:8443
  header {
    -Server
  }
}
```

W aplikacji klienta wpisz wtedy:

```text
wss://chat.example.com
```

### Zasady firewall/router

- Na komputerze z relay otworz tylko port reverse proxy, zwykle `443`.
- Jesli nie uzywasz reverse proxy, przekieruj `8443/TCP` na komputer z serwerem.
- Nie publikuj pliku `.env`.
- `SECURITY_LOGS=false` zostaw wylaczone, jesli nie debugujesz polaczen.

## 2. Klient Flutter

Wymagania:

- Flutter SDK
- Dla Windows: Visual Studio z obciazeniem "Desktop development with C++"
- Dla Androida: Android Studio, SDK i zaakceptowane licencje

Przygotowanie katalogow platform:

```powershell
cd client
flutter create . --platforms=windows,android,web
flutter pub get
```

Uruchomienie developerskie:

```powershell
flutter run -d windows
```

Android:

```powershell
flutter doctor --android-licenses
flutter build apk --release
```

Artefakt bedzie w `build/app/outputs/flutter-apk/app-release.apk`.

Windows:

```powershell
flutter build windows --release
```

Artefakt bedzie w `build/windows/x64/runner/Release/`.

Web:

```powershell
flutter build web --release
```

Katalog `build/web` wystaw przez HTTPS. WebRTC i bezpieczne magazynowanie w przegladarce wymagaja HTTPS poza `localhost`.

## 3. Pierwsze uruchomienie

1. Uruchom relay.
2. Otworz klienta jako pierwszy uzytkownik, wpisz `userId`, adres relay i `RELAY_TOKEN`.
3. Skopiuj swoj klucz publiczny z ekranu glownego.
4. Powtorz na drugim urzadzeniu z innym `userId`.
5. Dodajcie siebie nawzajem jako kontakty, wpisujac `userId` i klucz publiczny wymieniony poza aplikacja.
6. Wyslij wiadomosc. Aplikacja zestawi handshake E2EE, sprobuje WebRTC P2P i w razie potrzeby uzyje relay jako zaszyfrowanego tunelu.

## 4. Najwazniejsze ograniczenia

- Relay nie ma kolejki offline.
- Pliki sa trzymane w pamieci i maja domyslny limit 8 MB przed szyfrowaniem.
- WebRTC bez wlasnego STUN/TURN moze nie przebic czesci NAT. Wtedy dziala relay fallback.
- Klient Web ma slabsze gwarancje lokalnego magazynu niz Android/Windows. Dla najwyzszego poziomu prywatnosci preferuj aplikacje natywne.
- Ten kod jest solidnym punktem startowym, ale przed zastosowaniem operacyjnym wymaga testow penetracyjnych, hardeningu hosta i audytu.

## 5. Hardening produkcyjny

- Uzywaj `wss://` i aktualnego TLS.
- Trzymaj relay za Caddy/nginx z automatycznym odnawianiem certyfikatu.
- Uruchamiaj Node jako osobny, nieuprzywilejowany uzytkownik.
- Monitoruj tylko metryki techniczne procesu, bez logowania payloadow.
- Regularnie aktualizuj Node, Flutter i zaleznosci.
- Wymieniaj `RELAY_TOKEN`, gdy jakiekolwiek urzadzenie moglo zostac przejete.
