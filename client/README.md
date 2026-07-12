# Secure P2P Client

Klient Flutter dla Windows, Android i Linux.

## Start

```powershell
flutter create . --platforms=windows,android,linux
flutter pub get
flutter run -d windows
```

Klient generuje lokalnie tozsamosc Ed25519 i zapisuje ja przez `flutter_secure_storage`.
