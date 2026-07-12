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

## Administracja uzytkownikami

Serwer nie przechowuje hasel ani tresci rozmow, ale przechowuje dane pomocnicze:
publiczna lista opt-in, publiczne profile oraz kolejki offline.

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
