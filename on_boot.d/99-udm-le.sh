#!/bin/sh

#Load Environmnt Variables
. /mnt/data/udm-le/udm-le.env


#If flag is set, the following section will re-apply the existing certificate during boot

if [ "$ENABLE_CAPTIVE" == "yes" ]; then
	podman exec -it unifi-os ${CERT_IMPORT_CMD} ${UNIFIOS_CERT_PATH}/unifi-core.key ${UNIFIOS_CERT_PATH}/unifi-core.crt
	# This doesn't reboot your router, it just restarts the UnifiOS container
	unifi-os restart
fi

if [ ! -f /etc/cron.d/udm-le ]; then
	# Sleep for 5 minutes to avoid restarting
	# services during system startup.
	sleep 300
	sh ${UDM_LE_PATH}/udm-le.sh renew
fi
