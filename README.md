### LetsEncrypt for the UniFi Dream Machine

### Overview
This should work on UniFi Dream Machine Firmware 1.7.0+.

### Installation
1. Copy the contents of this repo to your device at `/mnt/data_ext/ssl`
2. Edit `lego.env` and set up the required variables. If you're not using Cloudflare for your DNS, you'll have to set whatever provider variables you need. See the [Lego DNS Provider](https://go-acme.github.io/lego/dns/) documentation for more information.
3. Run `/mnt/data_ext/ssl/lego.sh initial`. This will handle your initial certificate generation and setup a cron task at `/etc/cron.d/lego` to attempt certificate renewal each morning at 0300.

### Known Issues
On firmware updates (and maybe reboots), the cron file (`/etc/cron.d/lego`) gets removed, so you'll need to ssh in and run `/mnt/data_ext/ssl/lego.sh renew` to recreate the cron file or it won't attempt to renew the certificate each night.

If anyone figures out how to make this more persistent, please file a bug and let me know.