# Zdalny dostep do serwera Ubuntu

Ten dokument opisuje bezpieczny dostep administracyjny do serwera Ubuntu uzywanego dla Secure P2P Messenger.

## Cel

Administrator powinien miec mozliwosc:

- aktualizacji kodu serwera,
- przegladu logow,
- wykonania backupu,
- publikacji podpisanych aktualizacji,
- restartu uslugi.

Dostep administracyjny nie powinien byc publicznie otwarty szerzej niz potrzeba.

## Zalecany model

- SSH tylko na klucze.
- Wylaczone logowanie haslem SSH.
- Osobne konto administracyjne.
- Konto uslugi bez interaktywnego logowania.
- Firewall ograniczajacy porty.
- Panel metryk dostepny tylko przez localhost, VPN albo zaufana siec administracyjna.

## SSH

Przykladowy sposob laczenia:

```bash
ssh <admin-user>@<server-ip>
```

Nie zapisuj prawdziwego adresu, nazwy konta ani sciezki klucza w repozytorium.

## VPN lub prywatna siec

Jezeli serwer nie ma byc dostepny publicznie, wystaw API tylko w prywatnej sieci. Klienci musza wtedy laczyc sie z adresem dostepnym przez VPN.

## Reverse proxy

Dla publicznego wdrozenia wystaw tylko:

- HTTPS dla API,
- WSS dla WebSocket.

Nie wystawiaj publicznie:

- portu Node.js,
- `/metrics`,
- katalogow backupu,
- prywatnych kluczy aktualizacji.

## Operacje administracyjne

Typowy cykl:

```bash
cd /opt/secure-chat/app/server
npm run check
npm test
sudo systemctl restart secure-chat
sudo systemctl status secure-chat
```

Dostosuj nazwe uslugi do lokalnej konfiguracji.

## Logi

```bash
sudo journalctl -u secure-chat -n 200
```

Przed udostepnieniem logow usun tokeny, adresy, identyfikatory kont i inne dane prywatne.

## Backup

Backup wykonuj z serwera Ubuntu albo z zaufanej maszyny administracyjnej. Backup powinien byc szyfrowany przed przeniesieniem poza serwer.
