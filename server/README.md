# Secure Chat Server

Lekki serwer Node.js dla aktualnej wersji cloud-only komunikatora Secure Chat.

- obsluguje konta i sesje,
- przechowuje zaszyfrowane vaulty,
- przechowuje zaszyfrowana historie rozmow i plikow,
- udostepnia profile tylko uczestnikom wspolnych rozmow lub po dokladnym loginie,
- przechowuje podpisane bundle kluczy, certyfikaty i listy urzadzen,
- udostepnia podpisane aktualizacje aplikacji,
- wystawia API administracyjne.

Serwer nie powinien znac tresci rozmow, plikow ani prywatnych kluczy
uzytkownikow. Nadal widzi jednak metadane techniczne: konta, relacje, czas,
rozmiary pakietow i adresy IP.

Dane cloud sa przechowywane w SQLite w `V2_DATA_DIR`. Baza pracuje w trybie
WAL, wiec przy backupie offline kopiuj plik `.sqlite` razem z `.sqlite-wal` i
`.sqlite-shm`.

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
SESSION_TTL_HOURS=72
SESSION_IDLE_TTL_HOURS=24
METRICS_STORAGE_CACHE_SECONDS=15
```

WebSocket `/v2/ws` nie przyjmuje dlugotrwalego tokenu w URL ani w naglowku.
Klient najpierw pobiera krotko zyjacy, jednorazowy ticket przez `/v2/ws-ticket`,
a potem wysyla go jako pierwsza ramke WebSocket.

## Wdrozenie

W typowym wdrozeniu usluga systemd uruchamia:

```bash
npm start
```

w katalogu:

```text
/srv/secure-chat/server
```

Serwer powinien sluchac lokalnie na `127.0.0.1:8443`, a publiczny ruch HTTPS/WSS
powinien przechodzic przez Caddy.

Diagnostyka:

```bash
sudo systemctl status secure-p2p --no-pager
sudo journalctl -u secure-p2p -n 100 --no-pager
curl https://chat.example.com/healthz
curl -H "x-admin-token: $ADMIN_TOKEN" https://chat.example.com/metrics
```

`/healthz` zwraca tylko prosty status liveness. Szczegolowe metryki KDF i
storage sa dostepne przez `/metrics` z naglowkiem `x-admin-token`.

## Najwazniejsze katalogi danych

Domyslnie z `.env.example`:

```text
./data
./data-v2
./updates
```

Na produkcyjnym serwerze zwykle:

```text
/srv/secure-chat/server/data
/srv/secure-chat/server/data-v2
/srv/secure-chat/server/updates
```

Aktywna baza cloud zwykle lezy tutaj:

```text
/srv/secure-chat/server/data-v2/secure-chat.sqlite
/srv/secure-chat/server/data-v2/secure-chat.sqlite-wal
/srv/secure-chat/server/data-v2/secure-chat.sqlite-shm
```

Te katalogi zawieraja zaszyfrowane, ale wrazliwe dane. Do kopii online uzyj:

```bash
cd /srv/secure-chat/server
npm run backup-sqlite -- --out /backup/secure-chat.sqlite
```

Do kopii offline zatrzymaj usluge, skopiuj komplet plikow `.sqlite`,
`.sqlite-wal` i `.sqlite-shm`, a po restore przywroc komplet z tej samej chwili.

## Zaproszenia

Przy `REGISTRATION_MODE=invite` administrator tworzy krotko zyjace zaproszenie
przez uwierzytelniony endpoint. Token jest zwracany tylko raz, a w SQLite
przechowywany jest wylacznie jego hash:

```bash
curl -X POST https://chat.example.com/v2/admin/invites \
  -H "x-admin-token: $ADMIN_TOKEN" \
  -H "content-type: application/json" \
  -d '{"maxUses":1,"expiresInSeconds":86400,"restrictedUsername":"example-user"}'
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
