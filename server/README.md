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
