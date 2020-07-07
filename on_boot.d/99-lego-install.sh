#!/bin/sh

UDM_LEGO_PATH=/mnt/data/ssl

if [ ! -f /etc/cron.d/lego ]; then
    $UDM_LEGO_PATH/lego.sh renew
fi
