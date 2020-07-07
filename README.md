### LetsEncrypt for the UniFi Dream Machine

### Overview

This should work on UniFi Dream Machine Firmware 1.7.0+.

### Installation

1. Copy the contents of this repo to your device at `/mnt/data/udm-le`
2. Edit `udm-le.env` and set up the required variables. If you're not using Cloudflare for your DNS, you'll have to set whatever provider variables you need. See the [Lego DNS Provider](https://go-acme.github.io/lego/dns/) documentation for more information.
3. Run `/mnt/data/udm-le/udm-le.sh initial`. This will handle your initial certificate generation and setup a cron task at `/etc/cron.d/udm-le` to attempt certificate renewal each morning at 0300.

### Persistent installation

On firmware updates, the cron file (`/etc/cron.d/udm-le`) gets removed, so if you'd like for this to persist between upgrades, I suggest so you install boostchicken's [on-boot-script](https://github.com/boostchicken/udm-utilities/tree/master/on-boot-script) package.

This script is setup such that if it determines that on-boot-script is enabled, it will set up an additional script at `/mnt/data/on_boot.d/99-udm-le.sh` which will attempt certificate renewal shortly after a reboot (and subsequently set the cron back up again).
