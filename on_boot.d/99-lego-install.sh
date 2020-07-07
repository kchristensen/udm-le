#!/bin/sh

if [ ! -f /etc/cron.d/lego ]; then
    /mnt/data/ssl/lego.sh renew
fi
