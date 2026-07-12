# Secure P2P Relay

Lekki WebSocket relay/signaling server. Przekazuje:

- `signal` - handshake kryptograficzny i WebRTC signaling
- `relay` - zaszyfrowane pakiety `secure-p2p-e2ee/v1`

Serwer nie zapisuje wiadomosci i nie przechowuje kluczy.

## Start

```powershell
Copy-Item .env.example .env
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
npm install
npm start
```

Wygenerowany token wpisz do `.env` jako `RELAY_TOKEN`.

## Panel administratora

Zdalny panel Windows korzysta z API `/admin/...` na tym samym relay. W `.env`
ustaw osobny token administratora:

```bash
ADMIN_TOKEN=losowy-ciag-minimum-32-znaki
```

Token wygenerujesz tak:

```bash
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
```

Po zmianie `.env` zrestartuj usluge:

```bash
sudo systemctl restart secure-p2p-relay
```

Adres do aplikacji Windows to zwykle `https://chat.szkpn.pl`, a token to wartosc
`ADMIN_TOKEN`. API nie zwraca tresci rozmow ani kluczy prywatnych.

## Administracja uzytkownikami

Serwer nie przechowuje hasel ani tresci rozmow, ale przechowuje dane pomocnicze:
znane `userId`, publiczna lista opt-in, publiczne profile oraz kolejki offline.

Wazne: lista `known-users.json` jest uzupelniana przy polaczeniu klienta z relay.
Uzytkownicy, ktorzy byli online przed ta wersja, pojawia sie na liscie po ponownym
uruchomieniu aplikacji albo ponownym polaczeniu z serwerem.

Lista zapisanych userId:

```bash
npm run admin:users -- list
```

Podglad konkretnego userId:

```bash
npm run admin:users -- show USER_ID
```

Usuniecie konta z danych relay i dodanie userId do banlisty:

```bash
npm run admin:users -- delete USER_ID --yes
```

Samo zablokowanie lub odblokowanie userId:

```bash
npm run admin:users -- ban USER_ID --yes
npm run admin:users -- unban USER_ID --yes
```

Narzędzie robi backup zmienianych plikow w `data/admin-backups/`.
Relay odswieza banliste co minute; po pilnym usunieciu najlepiej zrestartowac usluge.
