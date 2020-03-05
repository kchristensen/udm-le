#!/bin/sh

set -e

BASEDIR=$(dirname "$0")

if [ "${BASEDIR}" = '.' ]; then
	echo 'This script should be run via an absolute path.'
	exit 1
fi

. "${BASEDIR}"/lego.env

CRON_FILE='/etc/cron.daily/lego'
# You might have to change this next line depending on what DNS provider you use
PODMAN_ENV="-e CLOUDFLARE_API_KEY=${CLOUDFLARE_API_KEY} -e CLOUDFLARE_EMAIL=${CLOUDFLARE_EMAIL}"
PODMAN_CMD="podman run -it --rm --name=lego --network=host ${PODMAN_ENV} -v ${SSL_PATH}/lego/:/var/lib/lego/ hectormolinero/lego"
LEGO_ARGS="--dns ${DNS_PROVIDER} --domains ${CERT_HOST} --email ${CERT_EMAIL}"

if [ ! -f "${CRON_FILE}" ]; then
	echo "sh ${SSL_PATH}/lego.sh renew" >${CRON_FILE}
	chmod 700 ${CRON_FILE}
fi

deploy_cert() {
	CERT="${SSL_PATH}/lego/certificates/${CERT_HOST}.crt"
	KEY="${SSL_PATH}/lego/certificates/${CERT_HOST}.key"
	CERT_PATH='/mnt/data/unifi-os/unifi-core/config'

	cp -f "${CERT}" ${CERT_PATH}/unifi-core.crt
	cp -f "${KEY}" ${CERT_PATH}/unifi-core.key
	chmod 644 ${CERT_PATH}/unifi-core.*

	unifi-os restart
}

case $1 in
initial)
	if [ "$(stat -c '%u:%g' "${SSL_PATH}/lego")" != "1000:1000" ]; then
		mkdir "${SSL_PATH}"/lego
		chown 1000:1000 "${SSL_PATH}"/lego
	fi

	echo 'Attempting initial certificate generation'
	${PODMAN_CMD} ${LEGO_ARGS} --accept-tos --key-type rsa2048 run

	if [ $? -ne 1 ]; then
		echo 'Certificate generation was successful, deploying certificate'
		deploy_cert
	fi
	;;
renew)
	${PODMAN_CMD} ${LEGO_ARGS} renew --days 80
	# We can't use the `--renewal-hook` easily with podman
	if [ "$(find -L "${SSL_PATH}"/lego -type f -name "${CERT_HOST}".crt -mtime -1)" ]; then
		echo 'Certificate renewal was successful, deploying certificate'
		deploy_cert
	fi
	;;
esac
