# Model zagrozen

Ten dokument opisuje zalozenia bezpieczenstwa aktualnej wersji Secure P2P Messenger.

## Chronione zasoby

- tresc wiadomosci,
- klucze rozmow,
- vault klienta,
- konta i sesje,
- lista urzadzen,
- manifest i artefakty aktualizacji,
- dane serwera i backupy,
- prywatne sekrety administratora.

## Zaufane elementy

- urzadzenie klienta po odblokowaniu,
- systemowy magazyn kluczy,
- operator self-hosted serwera,
- serwer Ubuntu i jego system aktualizacji,
- reverse proxy skonfigurowane jako zaufane proxy,
- prywatny klucz podpisu aktualizacji.

## Przeciwnicy

Projekt zaklada obrone przed:

- pasywnym podsluchiwaniem sieci,
- aktywnymi probami wyslania niepoprawnych payloadow do API,
- czescia atakow na rate limiting,
- podstawieniem plikow aktualizacji bez prawidlowego podpisu,
- przypadkowym ujawnieniem metryk,
- prostymi probami manipulacji historia wiadomosci.

Projekt nie zapewnia pelnej ochrony przed:

- przejetym urzadzeniem klienta,
- zlosliwym systemem operacyjnym,
- operatorem serwera ukrywajacym alternatywne widoki lokalnego logu key transparency,
- pelna analiza metadanych przez operatora serwera,
- kompromitacja po ujawnieniu aktualnego materialu sesyjnego bez pelnego Double Ratchet,
- atakiem po wycieku prywatnego klucza aktualizacji.

## Poufnosc wiadomosci

Tresc wiadomosci jest szyfrowana po stronie klienta. Serwer przechowuje zaszyfrowane payloady i metadane wymagane do synchronizacji.

Serwer nadal widzi czesc metadanych, np. konta, rozmowy, czasy zadania, rozmiary danych i adresy sieciowe.

## Integralnosc historii

Klient uzywa licznikow i hash-chain dla wiadomosci. Serwer wymusza aktualna epoke klucza rozmowy. To ogranicza mozliwosc cichego mieszania historii, ale nie jest pelnym publicznym audytem historii.

## Tozsamosc kluczy

Lokalny key transparency log pozwala klientom wykrywac zmiany statementow kluczy w ramach widoku podawanego przez serwer. Bez zewnetrznych swiadkow operator serwera nadal moze probowac rozdzielac widoki.

## Aktualizacje

Klient ufa tylko manifestowi podpisanemu znanym kluczem Ed25519 i zgodnym `keyId`. Wyciekniety prywatny klucz aktualizacji wymaga natychmiastowej rotacji i wydania klienta z nowym kluczem publicznym.

## PIN

PIN blokuje interfejs aplikacji i utrudnia przypadkowy dostep po restarcie. Nie jest granica kryptograficzna rowna silnemu haslu konta, szyfrowaniu dysku ani bezpiecznemu systemowemu magazynowi kluczy.

## Metryki

`/metrics` jest przeznaczone dla administratora. Powinno byc dostepne tylko z zaufanych adresow po prawidlowej konfiguracji reverse proxy.
