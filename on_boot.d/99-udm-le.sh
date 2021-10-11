#!/bin/sh

# Load Environmnt Variables
. /mnt/data/udm-le/udm-le.env

if [ ! -f /etc/cron.d/udm-le ]; then
	# Sleep for 5 minutes to avoid restarting
	# services during system startup.
	sleep 300
	RESTART_SERVICES=true sh ${UDM_LE_PATH}/udm-le.sh renew
fi
