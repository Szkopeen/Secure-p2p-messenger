# Protokol v2

Ten dokument opisuje aktualny stan protokolu aplikacji. Opis jest techniczny, ale nie zawiera prywatnych danych ani realnych adresow.

## Cel

Protokol v2 sluzy do synchronizacji self-hosted komunikatora:

- kont,
- sesji,
- urzadzen,
- rozmow,
- zaszyfrowanych wiadomosci,
- aktualizacji klienta,
- lokalnego logu key transparency.

Serwer przechowuje zaszyfrowane payloady i metadane wymagane do synchronizacji. Tresc rozmow jest szyfrowana po stronie klienta.

## Transport

- HTTP API przez HTTPS.
- WebSocket przez WSS.
- Serwer Node.js zwykle dziala za reverse proxy.
- WebSocket ma limit pre-auth: globalny, per IP, per okno czasowe i per liczba unikalnych IP.

## Konta i sesje

Logowanie uzywa challenge-response i sesji serwerowej. Serwer przechowuje material potrzebny do weryfikacji hasla, ale aktualnie nie jest to OPAQUE/PAKE.

Sesje maja czas zycia oraz idle timeout. WebSocket wymaga krotko zyjacego biletu wydanego po uwierzytelnieniu HTTP.

## Urzadzenia

Konto ma liste urzadzen z epokami. Aktualizacja listy wymaga:

- certyfikatu aktualnego urzadzenia,
- oczekiwanej epoki listy,
- oczekiwanego hasha listy,
- braku prob uniewaznienia aktualnie uzywanego urzadzenia.

Zmiany kluczy konta dopisuja wpis do lokalnego logu key transparency.

## Rozmowy i klucze

Rozmowa ma:

- `conversationId`,
- liste czlonkow,
- `keyEpoch`,
- mape `memberKeys`.

Nowe i rotowane `memberKeys` musza uzywac AAD v2. Koperta jest zwiazana z:

- rozmowa,
- nadawca,
- urzadzeniem nadawcy,
- odbiorca,
- publicznym kluczem odbiorcy,
- epoka klucza.

Serwer odrzuca koperty spoza rozmowy, z niepoprawnym odbiorca, bez wymaganego kontekstu albo bez poprawnego podpisu.

## Wiadomosci

Wiadomosc zawiera zaszyfrowany payload klienta. AAD payloadu obejmuje kontekst rozmowy, nadawcy i epoki klucza. Serwer wymusza aktualna epoke klucza oraz limity rozmiaru.

Klient utrzymuje licznik i hash-chain dla wiadomosci w rozmowie. To utrudnia ciche przestawianie lub podstawianie historii bez wykrycia po stronie klienta.

## Key transparency

Endpoint:

```text
GET /v2/key-transparency?userId=<user-id>&after=<index>
```

Zwraca lokalny append-only log zmian kluczy uzytkownika:

- indeks wpisu,
- typ zdarzenia,
- statement kluczy,
- hash statementu,
- poprzedni root,
- nowy root.

To jest lokalna przejrzystosc kluczy na self-hosted serwerze. Nie zapewnia niezaleznego, publicznego audytu bez zewnetrznych swiadkow.

## Aktualizacje

Manifest aktualizacji ma wersje v2 i jest podpisany Ed25519. Klient sprawdza:

- `keyId`,
- podpis,
- hash artefaktu,
- numer builda.

Serwer serwuje manifest i pliki aktualizacji bez podazania za symlinkami.

## Metryki

`/metrics` jest przeznaczone do administracyjnego monitoringu. Dostep zalezy od:

- `TRUSTED_PROXIES`,
- `METRICS_ALLOWED_IPS`,
- rzeczywistego adresu klienta po uwzglednieniu zaufanego proxy.

Nie nalezy wystawiac metryk publicznie.

## Poza zakresem obecnej wersji

- pelny Double Ratchet,
- post-compromise security na poziomie Signal,
- OPAQUE/PAKE,
- zewnetrznie swiadkowane key transparency,
- MLS dla duzych grup,
- anonimowosc metadanych wobec operatora serwera.
