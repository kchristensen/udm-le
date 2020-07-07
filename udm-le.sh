#!/bin/sh

set -e

# Load environment variables
. /mnt/data/udm-le/udm-le.env

if [ $(basedir) != "${UDM_LE_PATH}" ]; then
	echo "The directory in which this script resides (${BASEDIR}) does not match what UDM_LE_PATH is set to (${UDM_LE_PATH})"
	exit 1
fi

deploy_cert() {
	CERT="${UDM_LE_PATH}/lego/certificates/${CERT_NAME}.crt"
	KEY="${UDM_LE_PATH}/lego/certificates/${CERT_NAME}.key"
	CERT_PATH='/mnt/data/unifi-os/unifi-core/config'

	if [ "$(find -L "${UDM_LE_PATH}"/lego -type f -name "${CERT_NAME}".crt -mmin -5)" ]; then
		echo 'New certificate was generated, time to deploy it'
		cp -f "${CERT}" ${CERT_PATH}/unifi-core.crt
		cp -f "${KEY}" ${CERT_PATH}/unifi-core.key
		chmod 644 ${CERT_PATH}/unifi-core.*
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

PODMAN_CMD="podman run --env-file=${UDM_LE_PATH}/lego.env -it --name=lego --network=host --rm -v ${UDM_LE_PATH}/lego/:/var/lib/lego/ hectormolinero/lego"
LEGO_ARGS="--dns ${DNS_PROVIDER} --email ${CERT_EMAIL} ${HOSTS_ARGS} --key-type rsa2048"

case $1 in
initial)
	if [ "$(stat -c '%u:%g' "${UDM_LE_PATH}/udm-le")" != "1000:1000" ]; then
		mkdir "${UDM_LE_PATH}"/udm-le
		chown 1000:1000 "${UDM_LE_PATH}"/udm-le
	fi

	echo 'Attempting initial certificate generation'
	${PODMAN_CMD} ${LEGO_ARGS} --accept-tos run && deploy_cert
	;;
renew)
	echo 'Attempting certificate renewal'
	${PODMAN_CMD} ${LEGO_ARGS} renew --days 60 && deploy_cert
	;;
esac
