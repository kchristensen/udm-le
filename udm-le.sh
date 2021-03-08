#!/bin/sh

set -e

# Load environment variables
. /mnt/data/udm-le/udm-le.env

# Setup variables for later
DOCKER_VOLUMES="-v ${UDM_LE_PATH}/lego/:/.lego/"
LEGO_ARGS="--dns ${DNS_PROVIDER} --email ${CERT_EMAIL} --key-type rsa2048"
NEW_CERT=""

add_captive() {
	# Import the certificate for the captive portal
	if [ "$ENABLE_CAPTIVE" == "yes" ]; then
		podman exec -it unifi-os ${CERT_IMPORT_CMD} ${UNIFIOS_CERT_PATH}/unifi-core.key ${UNIFIOS_CERT_PATH}/unifi-core.crt
	fi
}

deploy_cert() {
	# Re-write CERT_NAME if it is a wildcard cert. Replace * with _
	LEGO_CERT_NAME=${CERT_NAME/\*/_}
	if [ "$(find -L "${UDM_LE_PATH}"/lego -type f -name "${LEGO_CERT_NAME}".crt -mmin -5)" ]; then
		echo 'New certificate was generated, time to deploy it'
		# Controller certificate
		cp -f ${UDM_LE_PATH}/lego/certificates/${LEGO_CERT_NAME}.crt ${UBIOS_CERT_PATH}/unifi-core.crt
		cp -f ${UDM_LE_PATH}/lego/certificates/${LEGO_CERT_NAME}.key ${UBIOS_CERT_PATH}/unifi-core.key
		chmod 644 ${UBIOS_CERT_PATH}/unifi-core.*
		NEW_CERT="yes"
	else
		echo 'No new certificate was found, exiting without restart'
	fi
}

restart_unifi_os() {
	# Attempt to restart unifi-os, and retry a few times in the event it fails
	unifi-os restart

	RETRIES=1
	until [ "$(podman inspect -f '{{.State.Running}}' "unifi-os" 2>&1)" = "true" ];
	do
		if [ "$RETRIES" -gt 5 ]; then
			echo 'Unable to restart unifi-os after 5 attempts, exiting'
			exit 1
		fi
		unifi-os restart
		sleep 5
		let "RETRIES=RETRIES+1"
	done
}

# Support alternative DNS resolvers
if [ "${DNS_RESOLVERS}" != "" ]; then
	LEGO_ARGS="${LEGO_ARGS} --dns.resolvers ${DNS_RESOLVERS}"
fi

# Support multiple certificate SANs
for DOMAIN in $(echo $CERT_HOSTS | tr "," "\n"); do
	if [ -z "$CERT_NAME" ]; then
		CERT_NAME=$DOMAIN
	fi
	LEGO_ARGS="${LEGO_ARGS} -d ${DOMAIN}"
done

# Check for optional .secrets directory, and add it to the mounts if it exists
# Lego does not support AWS_ACCESS_KEY_ID_FILE or AWS_PROFILE_FILE so we'll try
# mounting the secrets directory into a place that Route53 will see.
if [ -d "${UDM_LE_PATH}/.secrets" ]; then
	DOCKER_VOLUMES="${DOCKER_VOLUMES} -v ${UDM_LE_PATH}/.secrets:/root/.aws/ -v ${UDM_LE_PATH}/.secrets:/root/.secrets/"
fi

# Setup persistent on_boot.d trigger
ON_BOOT_DIR='/mnt/data/on_boot.d'
ON_BOOT_FILE='99-udm-le.sh'
if [ -d "${ON_BOOT_DIR}" ] && [ ! -f "${ON_BOOT_DIR}/${ON_BOOT_FILE}" ]; then
	cp "${UDM_LE_PATH}/on_boot.d/${ON_BOOT_FILE}" "${ON_BOOT_DIR}/${ON_BOOT_FILE}"
	chmod 755 ${ON_BOOT_DIR}/${ON_BOOT_FILE}
fi

# Setup nightly cron job
CRON_FILE='/etc/cron.d/udm-le'
if [ ! -f "${CRON_FILE}" ]; then
	echo "0 3 * * * sh ${UDM_LE_PATH}/udm-le.sh renew" >${CRON_FILE}
	chmod 644 ${CRON_FILE}
	/etc/init.d/crond reload ${CRON_FILE}
fi

PODMAN_CMD="podman run --env-file=${UDM_LE_PATH}/udm-le.env -it --name=lego --network=host --rm ${DOCKER_VOLUMES} goacme/lego:v4.2.0-arm.v8"

case $1 in
initial)
	# Create lego directory so the container can write to it
	if [ "$(stat -c '%u:%g' "${UDM_LE_PATH}/lego")" != "1000:1000" ]; then
		mkdir "${UDM_LE_PATH}"/lego
		chown 1000:1000 "${UDM_LE_PATH}"/lego
	fi

	echo 'Attempting initial certificate generation'
	${PODMAN_CMD} ${LEGO_ARGS} --accept-tos run && deploy_cert && add_captive && restart_unifi_os
	;;
renew)
	echo 'Attempting certificate renewal'
	${PODMAN_CMD} ${LEGO_ARGS} renew --days 60 && deploy_cert
	if [ "${NEW_CERT}" = "yes" ]; then
		add_captive && restart_unifi_os
	fi
	;;
bootrenew)
	echo 'Attempting certificate renewal'
	${PODMAN_CMD} ${LEGO_ARGS} renew --days 60 && deploy_cert && add_captive && restart_unifi_os
	;;
testdeploy)
	echo 'Attempting to deploy certificate'
	deploy_cert
	;;
esac
