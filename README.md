### LetsEncrypt for the Ubiquiti Dream Machine Pro

### Overview
This currently only works on the UDMP, as the UDM currently does not officially support firmware version 1.6+.

Your mileage may vary, this has not been thoroughly tested yet.

### Installation
1. Copy the contents of this repo to your device at `/mnt/data_ext/ssl`
2. Edit `lego.env` and set up the required variables. If you're not using Cloudflare for your DNS, you'll have to set whatever provider variables you need. See the [Lego DNS Provider](https://go-acme.github.io/lego/dns/) documentation for more information.
3. Run `lego.sh initial`. This will handle your initial certificate generation and setup a cron task at `/etc/cron.d/lego` to attempt certificate renewal each morning at 0300.