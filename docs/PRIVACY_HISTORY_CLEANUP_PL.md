# Czyszczenie historii po wycieku danych

Ten dokument opisuje, co zrobic, jezeli do repozytorium trafily prywatne dane, sekrety, lokalne sciezki, adresy serwera albo klucze.

## Najpierw obroc sekrety

Usuniecie sekretu z pliku nie wystarcza. Jezeli sekret byl w commicie, traktuj go jako ujawniony.

Obroc:

- `ADMIN_TOKEN`,
- hasla kont testowych,
- prywatny klucz podpisu aktualizacji,
- tokeny CI,
- klucze SSH albo deploy keys,
- prywatne adresy, jezeli nie powinny byc publiczne.

## Potem wyczysc repozytorium

1. Usun dane z aktualnych plikow.
2. Przepisz dokumentacje na placeholdery.
3. Sprawdz caly projekt wyszukiwaniem po znanych fragmentach sekretow.
4. Jezeli sekret jest w historii publicznego repo, wykonaj czyszczenie historii narzedziem do rewrite historii Git.
5. Wypchnij poprawiona historie tylko wtedy, gdy rozumiesz skutki dla innych klonow.

## Co wyszukiwac

Szukaj:

- lokalnych sciezek systemowych,
- nazw kont uzytkownika,
- prawdziwych domen,
- publicznych i prywatnych adresow IP,
- tokenow,
- maili,
- kluczy PEM,
- plikow `.env`,
- nazw prywatnej infrastruktury.

## Po czyszczeniu

Wykonaj ponowny audyt:

```bash
rg -n "PRIVATE KEY|ADMIN_TOKEN|C:\\\\Users|<stary-fragment-sekretu>"
```

Dostosuj wzorce do konkretnego incydentu. Nie zapisuj prawdziwego sekretu w dokumentacji ani w publicznym issue.

## Zasada na przyszlosc

Dokumentacja powinna uzywac placeholderow:

```text
<domain>
<server-ip>
<admin-token>
<repo-dir>
<public-key-base64url>
```

Pliki `.env`, klucze podpisu, backupy i lokalne konfiguracje powinny byc ignorowane przez Git.
