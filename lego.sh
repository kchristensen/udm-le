#!/bin/sh

set -e

BASEDIR=$(dirname "$0")
. "${BASEDIR}"/lego.env

if [ "${BASEDIR}" = '.' ]; then
	echo 'This script should be run via an absolute path'
	exit 1
fi

if [ "${BASEDIR}" != "${SSL_PATH}" ]; then
	echo "The directory in which this script resides (${BASEDIR}) does not match what SSL_PATH is set to (${SSL_PATH})"
	exit 1
fi

# Added support for SAN
CERT_NAME=""
HOSTS_ARGS=""
for DOM in $(echo $CERT_HOST | tr "," "\n")
do
	if [ -z "$CERT_NAME" ]
	then
		CERT_NAME=$DOM
	fi
    
	HOSTS_ARGS="${HOSTS_ARGS} -d $DOM"
done

deploy_cert() {
	CERT="${SSL_PATH}/lego/certificates/${CERT_NAME}.crt"
	KEY="${SSL_PATH}/lego/certificates/${CERT_NAME}.key"
	CERT_PATH='/mnt/data/unifi-os/unifi-core/config'

	if [ "$(find -L "${SSL_PATH}"/lego -type f -name "${CERT_NAME}".crt -mmin -5)" ]; then
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

PODMAN_CMD="podman run --env-file=${SSL_PATH}/lego.env -it --name=lego --network=host --rm -v ${SSL_PATH}/lego/:/var/lib/lego/ hectormolinero/lego"
LEGO_ARGS="--dns ${DNS_PROVIDER} ${HOSTS_ARGS} --email ${CERT_EMAIL} --key-type rsa2048"

CRON_FILE='/etc/cron.d/lego'
if [ ! -f "${CRON_FILE}" ]; then
	echo "0 3 * * * sh ${SSL_PATH}/lego.sh renew" >${CRON_FILE}
	chmod 644 ${CRON_FILE}
	/etc/init.d/crond reload ${CRON_FILE}
fi

case $1 in
initial)
	if [ "$(stat -c '%u:%g' "${SSL_PATH}/lego")" != "1000:1000" ]; then
		mkdir "${SSL_PATH}"/lego
		chown 1000:1000 "${SSL_PATH}"/lego
	fi

	echo 'Attempting initial certificate generation'
	${PODMAN_CMD} ${LEGO_ARGS} --accept-tos run && deploy_cert
	;;
renew)
	echo 'Attempting certificate renewal'
	${PODMAN_CMD} ${LEGO_ARGS} renew --days 80 && deploy_cert
	;;
esac
