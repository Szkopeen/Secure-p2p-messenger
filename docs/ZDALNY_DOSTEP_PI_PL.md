# Zdalny dostep do Raspberry Pi poza domem

Najprostsze i najbezpieczniejsze rozwiazanie na wyjazd to Tailscale. Dziala jak
prywatna siec WireGuard miedzy Twoimi urzadzeniami. Nie trzeba wystawiac SSH na
publiczny internet, nie trzeba przekierowywac portu 22 i nie ma znaczenia, czy
router albo operator robi NAT.

Cel:

```text
Laptop poza domem -> Tailscale -> Raspberry Pi w domu -> serwer Secure Chat
```

## 1. Zainstaluj SSH na Pi

Na Raspberry Pi:

```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
sudo systemctl status ssh --no-pager
```

## 2. Zainstaluj Tailscale na Pi

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --hostname szkpn-pi
```

Po drugim poleceniu pojawi sie link logowania. Otworz go, zaloguj sie i dodaj Pi
do swojego tailnetu.

Sprawdz adres Pi w sieci Tailscale:

```bash
tailscale ip -4
tailscale status
```

Zapisz adres wygladajacy mniej wiecej tak:

```text
100.x.y.z
```

## 3. Ogranicz SSH do Tailscale

Jezeli uzywasz UFW:

```bash
sudo ufw allow in on tailscale0 to any port 22 proto tcp
sudo ufw status
```

Nie przekierowuj portu 22 na routerze. Publiczny internet ma widziec tylko to,
co juz wystawiasz dla aplikacji, czyli 80/443 przez Caddy.

## 4. Zainstaluj Tailscale na laptopie

Na Windows pobierz aplikacje z:

```text
https://tailscale.com/download/windows
```

Zaloguj sie na to samo konto Tailscale, ktore dodalo Pi.

Sprawdz, czy laptop widzi Pi:

```powershell
tailscale status
```

## 5. Polacz sie z Pi spoza domu

Z PowerShella:

```powershell
ssh szkpn@ADRES_TAILSCALE_PI
```

Przyklad:

```powershell
ssh szkpn@100.80.12.34
```

Potem mozesz normalnie sprawdzac serwer:

```bash
sudo systemctl status secure-p2p-relay --no-pager
sudo systemctl status caddy --no-pager
curl https://chat.szkpn.pl/healthz
```

## 6. Test przed wyjazdem

Zrob to jeszcze bedac w domu:

1. Uruchom Tailscale na Pi.
2. Uruchom Tailscale na laptopie.
3. Polacz sie po SSH przez adres `100.x.y.z`.
4. Odlacz laptop od domowego Wi-Fi albo wlacz hotspot z telefonu.
5. Sprobuj polaczyc sie drugi raz po tym samym adresie Tailscale.
6. Sprawdz status `secure-p2p-relay` i `caddy`.

Jezeli punkt 5 dziala przez hotspot, jutro poza domem tez powinno dzialac.

## Opcja alternatywna: Tailscale SSH

Mozesz wlaczyc Tailscale SSH:

```bash
sudo tailscale set --ssh
```

Wtedy Tailscale moze zarzadzac autoryzacja SSH przez tailnet. Na jutro
bezpieczniej i prosciej zostac przy zwyklym `ssh szkpn@100.x.y.z` tunelowanym
przez Tailscale, bo wymaga mniej konfiguracji polityk dostepu.

## Czego nie robic

- Nie wystawiaj portu 22 publicznie na routerze.
- Nie loguj sie po SSH jako root.
- Nie zostawiaj Pi bez zasilania albo na Wi-Fi, ktore potrafi sie rozlaczyc.
- Nie wylaczaj Caddy ani `secure-p2p-relay` przed wyjazdem.
- Nie kasuj lokalnego dostepu LAN, dopoki nie sprawdzisz Tailscale przez hotspot.

