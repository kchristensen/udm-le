#!/bin/sh

UDM_LE_PATH='/mnt/data/udm-le'

if [ ! -f /etc/cron.d/udm-le ]; then
    # Sleep for 5 minutes to avoid restarting
    # services during system startup.
    sleep 300
    ${UDM_LE_PATH}/udm-le.sh renew
fi
