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

deploy_cert() {
	CERT="${SSL_PATH}/lego/certificates/${CERT_HOST}.crt"
	KEY="${SSL_PATH}/lego/certificates/${CERT_HOST}.key"
	CERT_PATH='/mnt/data/unifi-os/unifi-core/config'

	if [ "$(find -L "${SSL_PATH}"/lego -type f -name "${CERT_HOST}".crt -mmin -5)" ]; then
		echo 'New certificate was generated, time to deploy it'
		cp -f "${CERT}" ${CERT_PATH}/unifi-core.crt
		cp -f "${KEY}" ${CERT_PATH}/unifi-core.key
		chmod 644 ${CERT_PATH}/unifi-core.*

		unifi-os restart
	else
		echo 'No new certificate was found, exiting without restart'
	fi
}

# You might have to change this next line depending on what DNS provider you use
# Using --env-file with podman doesn't seem to export the Cloudflare variables
# so that lego sees them.
PODMAN_ENV="-e CLOUDFLARE_API_KEY=${CLOUDFLARE_API_KEY} -e CLOUDFLARE_EMAIL=${CLOUDFLARE_EMAIL}"
PODMAN_CMD="podman run -it --rm --name=lego --network=host ${PODMAN_ENV} -v ${SSL_PATH}/lego/:/var/lib/lego/ hectormolinero/lego"
LEGO_ARGS="--dns ${DNS_PROVIDER} --domains ${CERT_HOST} --email ${CERT_EMAIL}"

CRON_FILE='/etc/cron.d/lego'
if [ ! -f "${CRON_FILE}" ]; then
	echo "0 3 * * * sh ${SSL_PATH}/lego.sh renew" > ${CRON_FILE}
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
	${PODMAN_CMD} ${LEGO_ARGS} --accept-tos --key-type rsa2048 run && deploy_cert
	;;
renew)
	echo 'Attempting certificate renewal'
	${PODMAN_CMD} ${LEGO_ARGS} renew --days 80 && deploy_cert
	;;
esac
