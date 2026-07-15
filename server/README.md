# Secure Chat Server

Lekki serwer Node.js dla aktualnej wersji cloud-only komunikatora Secure Chat.

Historycznie katalog nazywal sie `relay`, ale obecnie serwer robi wiecej niz
przekazywanie pakietow:

- obsluguje konta i sesje,
- przechowuje zaszyfrowane vaulty,
- przechowuje zaszyfrowana historie rozmow i plikow,
- kolejkuje wiadomosci offline,
- obsluguje publiczna liste uzytkownikow opt-in,
- przechowuje podpisane bundle kluczy, certyfikaty i listy urzadzen,
- udostepnia podpisane aktualizacje aplikacji,
- wystawia API administracyjne.

Serwer nie powinien znac tresci rozmow, plikow ani prywatnych kluczy
uzytkownikow. Nadal widzi jednak metadane techniczne: konta, relacje, czas,
rozmiary pakietow i adresy IP.

## Start lokalny

```bash
cp .env.example .env
npm install
npm start
```

Wygenerowanie losowego sekretu administratora:

```bash
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
```

Ustaw co najmniej:

```bash
REGISTRATION_MODE=disabled
ADMIN_TOKEN=drugi-losowy-ciag-minimum-32-znaki
```

WebSocket `/v2/ws` nie przyjmuje dlugotrwalego tokenu w URL ani w naglowku.
Klient najpierw pobiera krotko zyjacy, jednorazowy ticket przez `/v2/ws-ticket`,
a potem wysyla go jako pierwsza ramke WebSocket.

## Wdrozenie na Pi

W aktualnym wdrozeniu usluga systemd uruchamia:

```bash
npm start
```

w katalogu:

```text
/opt/secure-p2p/app/server
```

Serwer powinien sluchac lokalnie na `127.0.0.1:8443`, a publiczny ruch HTTPS/WSS
powinien przechodzic przez Caddy.

Diagnostyka:

```bash
sudo systemctl status secure-p2p-relay --no-pager
sudo journalctl -u secure-p2p-relay -n 100 --no-pager
curl https://chat.szkpn.pl/healthz
```

## Najwazniejsze katalogi danych

Domyslnie z `.env.example`:

```text
./data
./data-v2
./updates
```

Na produkcyjnym Pi zwykle:

```text
/opt/secure-p2p/app/server/data
/opt/secure-p2p/app/server/data-v2
/opt/secure-p2p/app/server/updates
```

Te katalogi zawieraja zaszyfrowane, ale wrazliwe dane. Rob kopie zapasowe przed
aktualizacjami backendu.

## Administracja uzytkownikami

Lista zapisanych userId:

```bash
npm run admin:users -- list
```

Podglad konkretnego userId:

```bash
npm run admin:users -- show USER_ID
```

Usuniecie konta z danych administracyjnych i dodanie userId do banlisty:

```bash
npm run admin:users -- delete USER_ID --yes
```

Samo zablokowanie lub odblokowanie userId:

```bash
npm run admin:users -- ban USER_ID --yes
npm run admin:users -- unban USER_ID --yes
```

Narzedzie robi backup zmienianych plikow w `data/admin-backups/`. Relay odswieza
banliste okresowo; po pilnym usunieciu najlepiej zrestartowac usluge.

Na produkcyjnym Pi uruchamiaj narzedzie jako uzytkownik uslugi:

```bash
sudo -u securep2p -H npm --prefix /opt/secure-p2p/app/server run admin:users -- list
```

## Aktualizacje aplikacji

Manifest:

```text
/updates/manifest.json
```

Pliki:

```text
/updates/files/
```

Manifest release musi byc podpisany kluczem Ed25519. Prywatny klucz release nie
powinien lezec w repo ani na serwerze produkcyjnym.
