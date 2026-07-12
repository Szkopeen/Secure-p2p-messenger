# Secure P2P Messenger

Prywatny komunikator E2EE z lekkim serwerem Relay/Signaling oraz jednym klientem Flutter dla Windows, Android i Linux.

## Co jest w projekcie

- `server/` - Node.js WebSocket relay. Nie zapisuje wiadomosci, nie przechowuje kluczy prywatnych i nie odszyfrowuje payloadow.
- `client/` - Flutter. Generuje lokalna tozsamosc Ed25519, zestawia efemeryczne sesje X25519 i szyfruje tresci AES-256-GCM.
- `docs/DEPLOYMENT_PL.md` - skrocona instrukcja uruchomienia serwera i budowania klientow.
- `docs/OD_ZERA_DO_DZIALANIA_PL.md` - pelny przewodnik od instalacji systemu do pierwszej rozmowy.
- `docs/AKTUALIZACJE_PL.md` - publikowanie nowych wersji aplikacji na relay.

## Model bezpieczenstwa

- Serwer zna metadane transportowe: IP, `from`, `to`, czas i rozmiar pakietu.
- Serwer nie zna tresci wiadomosci, plikow ani kluczy sesyjnych.
- Klucze kontaktow musza byc wymienione poza komunikatorem. Blednie przypiety klucz publiczny oznacza ryzyko MITM.
- PFS dziala per sesja rozmowy: po restarcie aplikacja tworzy nowy handshake i nowy klucz sesyjny.
- Relay ma ograniczona kolejke offline zaszyfrowanych pakietow. Nadal nie zna ich tresci ani kluczy.

Przed uzyciem w srodowisku wysokiego ryzyka zrob niezalezny audyt kryptografii i konfiguracji systemu.
