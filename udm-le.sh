#!/bin/sh

set -e

# Load environment variables
. /mnt/data/udm-le/udm-le.env

deploy_cert() {
	CERT_IMPORT_CMD='java -jar /usr/lib/unifi/lib/ace.jar import_key_cert'
	UBIOS_CERT_PATH='/mnt/data/unifi-os/unifi-core/config'
	UNIFIOS_CERT_PATH='/data/unifi-core/config'

	if [ "$(find -L "${UDM_LE_PATH}"/lego -type f -name "${CERT_NAME}".crt -mmin -5)" ]; then
		echo 'New certificate was generated, time to deploy it'
		# Controller certificate
		cp -f ${UDM_LE_PATH}/lego/certificates/${CERT_NAME}.crt ${UBIOS_CERT_PATH}/unifi-core.crt
		cp -f ${UDM_LE_PATH}/lego/certificates/${CERT_NAME}.key ${UBIOS_CERT_PATH}/unifi-core.key
		chmod 644 ${UBIOS_CERT_PATH}/unifi-core.*

		# Import the ertificate for the captive portal
		podman exec -it unifi-os ${CERT_IMPORT_CMD} ${UNIFIOS_CERT_PATH}/unifi-core.key ${UNIFIOS_CERT_PATH}/unifi-core.crt

		# This doesn't reboot your router, it just restarts the UnifiOS container
		unifi-os restart
	else
		echo 'No new certificate was found, exiting without restart'
	fi
}

# Support multiple certificate SANs
CERT_NAME=''
HOSTS_ARGS=''
for DOMAIN in $(echo $CERT_HOSTS | tr "," "\n"); do
	if [ -z "$CERT_NAME" ]; then
		CERT_NAME=$DOMAIN
	fi

	HOSTS_ARGS="${HOSTS_ARGS} -d ${DOMAIN}"
done

# Check for aws directory, add that mount point to the lego container
AWS_MOUNT=''
if [ -d ${UDM_LE_PATH}/.aws ]; then
        AWS_MOUNT="-v ${UDM_LE_PATH}/aws:/home/lego/.aws/"
fi

# Setup persistent on_boot.d trigger
ON_BOOT_DIR='/mnt/data/on_boot.d'
ON_BOOT_FILE='99-udm-le.sh'
if [ ! -f "${ON_BOOT_DIR}/${ON_BOOT_FILE}" ]; then
	cp on_boot.d/${ON_BOOT_FILE} ${ON_BOOT_DIR}/${ON_BOOT_FILE}
	chmod 755 ${ON_BOOT_DIR}/${ON_BOOT_FILE}
fi

# Setup nightly cron job
CRON_FILE='/etc/cron.d/udm-le'
if [ ! -f "${CRON_FILE}" ]; then
	echo "0 3 * * * sh ${UDM_LE_PATH}/udm-le.sh renew" >${CRON_FILE}
	chmod 644 ${CRON_FILE}
	/etc/init.d/crond reload ${CRON_FILE}
fi

PODMAN_CMD="podman run --env-file=${UDM_LE_PATH}/udm-le.env -it --name=lego --network=host --rm -v ${UDM_LE_PATH}/lego/:/var/lib/lego/ ${AWS_MOUNT} hectormolinero/lego"
LEGO_ARGS="--dns ${DNS_PROVIDER} --email ${CERT_EMAIL} ${HOSTS_ARGS} --key-type rsa2048"

case $1 in
initial)
	# Create lego directory so the container can write to it
	if [ "$(stat -c '%u:%g' "${UDM_LE_PATH}/lego")" != "1000:1000" ]; then
		mkdir "${UDM_LE_PATH}"/lego
		chown 1000:1000 "${UDM_LE_PATH}"/lego
	fi

	echo 'Attempting initial certificate generation'
	${PODMAN_CMD} ${LEGO_ARGS} --accept-tos run && deploy_cert
	;;
renew)
	echo 'Attempting certificate renewal'
	${PODMAN_CMD} ${LEGO_ARGS} renew --days 60 && deploy_cert
	;;
esac
