# Security

Do not publish device dumps or runtime configuration. A full station dump can contain Wi-Fi credentials, private keys, account/device identifiers, Yandex authentication material, and personal telemetry.

For bug reports, share only the relevant redacted logs. Never include:
- `/data/local-assistant.conf`
- Wi-Fi supplicant configuration or DHCP leases
- Quasar account/device databases or logs
- private keys, tokens, passwords, or certificates tied to a device
- audio recordings or recognized speech without consent

If a credential was accidentally made public, revoke or rotate it.
