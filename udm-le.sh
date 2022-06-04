#!/bin/sh

set -e

# Load environment variables
. /mnt/data/udm-le/udm-le.env

# Setup variables for later
DOCKER_VOLUMES="-v ${UDM_LE_PATH}/lego/:/.lego/"
LEGO_ARGS="--dns ${DNS_PROVIDER} --email ${CERT_EMAIL} --key-type rsa2048"
RESTART_SERVICES=false

# Show usage
usage()
{
  echo "Usage: udm-le.sh action [ --restart-services ]"
  echo "Actions:"
  echo "	- udm-le.sh initial: Generate new certificate and set up cron job to renew at 03:00 each morning."
  echo "	- udm-le.sh renew: Renew certificate if due for renewal."
  echo "	- udm-le.sh update_keystore --restart-services: Update keystore used by Captive Portal/WiFiman"
  echo "	  with either full certificate chain (if NO_BUNDLE='no') or server certificate only (if NO_BUNDLE='yes')."
  echo "	  Requires --restart-services flag. "
  echo ""
  echo "Options:"
  echo "	--restart-services: [optional] force restart of services even if certificate not renewed."
  echo ""
  echo "WARNING: NO_BUNDLE option is only supported experimentally. Setting it to 'yes' is required to make WiFiman work,"
  echo "but may result in some clients not being able to connect to Captive Portal if they do not already have a cached"
  echo "copy of the CA intermediate certificate(s) and are unable to download them."
}

# Get command line options
OPTIONS=$(getopt -o h --long help,restart-services -- "$@")
if [[ $? -ne 0 ]]; then
    echo "Incorrect option provided"
    exit 1;
fi

eval set -- "$OPTIONS"
while [ : ]; do
  case "$1" in
    -h | --help)
		usage;
		exit 0;
		shift
		;;
    --restart-services)
        RESTART_SERVICES=true;
        shift
        ;;
    --) shift; 
        break 
        ;;
  esac
done

deploy_certs() {
	# Deploy certificates for the controller and optionally for the captive portal and radius server

	# Re-write CERT_NAME if it is a wildcard cert. Replace * with _
	LEGO_CERT_NAME=${CERT_NAME/\*/_}
	if [ "$(find -L "${UDM_LE_PATH}"/lego -type f -name "${LEGO_CERT_NAME}".crt -mmin -5)" ]; then
		echo 'New certificate was generated, time to deploy it'

		cp -f ${UDM_LE_PATH}/lego/certificates/${LEGO_CERT_NAME}.crt ${UBIOS_CONTROLLER_CERT_PATH}/unifi-core.crt
		cp -f ${UDM_LE_PATH}/lego/certificates/${LEGO_CERT_NAME}.key ${UBIOS_CONTROLLER_CERT_PATH}/unifi-core.key
		chmod 644 ${UBIOS_CONTROLLER_CERT_PATH}/unifi-core.crt ${UBIOS_CONTROLLER_CERT_PATH}/unifi-core.key

		if [ "$ENABLE_CAPTIVE" == "yes" ]; then
			update_keystore
		fi

		if [ "$ENABLE_RADIUS" == "yes" ]; then
			cp -f ${UDM_LE_PATH}/lego/certificates/${LEGO_CERT_NAME}.crt ${UBIOS_RADIUS_CERT_PATH}/server.pem
			cp -f ${UDM_LE_PATH}/lego/certificates/${LEGO_CERT_NAME}.key ${UBIOS_RADIUS_CERT_PATH}/server-key.pem
			chmod 600 ${UBIOS_RADIUS_CERT_PATH}/server.pem ${UBIOS_RADIUS_CERT_PATH}/server-key.pem
		fi

		RESTART_SERVICES=true
	fi
}

restart_services() {
	# Restart services if certificates have been deployed, or we're forcing it on the command line
	if [ "${RESTART_SERVICES}" == true ]; then
		echo 'Restarting UniFi OS'
		unifi-os restart &>/dev/null

		if [ "$ENABLE_RADIUS" == "yes" ]; then
			echo 'Restarting Radius server'
			if [ -x "$(command -v rc.radius)" ]; then 
				rc.radius restart &>/dev/null
			elif [ -x "$(command -v rc.radiusd)" ];then 
				rc.radiusd restart &>/dev/null
			else
				echo 'Radius command not found'
			fi
		fi
	else
		echo 'RESTART_SERVICES is false, skipping service restarts'
	fi
}

update_keystore() {
	if [ "$NO_BUNDLE" == "yes" ]; then
		# Only import server certifcate to keystore. WiFiman requires a single certificate in the .crt file 
		# and does not work if the full chain is imported as this includes the CA intermediate certificates.
		echo "	- Importing server certificate only"
		# 1. Export only the server certificate from the full chain bundle
		podman exec -it unifi-os openssl x509 -in ${UNIFIOS_CERT_PATH}/unifi-core.crt > ${UNIFIOS_CERT_PATH}/unifi-core-server-only.crt
		# 2. Bundle the private key and server-only certificate into a PKCS12 format file
		podman exec -it unifi-os openssl pkcs12 -export -inkey ${UNIFIOS_CERT_PATH}/unifi-core.key -in ${UNIFIOS_CERT_PATH}/unifi-core-server-only.crt \
			-out ${UNIFIOS_KEYSTORE_PATH}/unifi-core-key-plus-server-only-cert.p12 -name ${UNIFIOS_KEYSTORE_CERT_ALIAS} -password pass:${UNIFIOS_KEYSTORE_PASSWORD}
		# 3. Backup the keystore before editing it.
		podman exec -it unifi-os cp ${UNIFIOS_KEYSTORE_PATH}/keystore ${UNIFIOS_KEYSTORE_PATH}/keystore_$(date +"%Y-%m-%d_%Hh%Mm%Ss").backup
		# 4. Delete the existing full chain from the keystore
		podman exec -it unifi-os keytool -delete -alias unifi -keystore ${UNIFIOS_KEYSTORE_PATH}/keystore -deststorepass ${UNIFIOS_KEYSTORE_PASSWORD}
		# 5. Import the server-only certificate and private key from the PKCS12 file
		podman exec -it unifi-os keytool -importkeystore -deststorepass ${UNIFIOS_KEYSTORE_PASSWORD} -destkeypass ${UNIFIOS_KEYSTORE_PASSWORD} \
			-destkeystore ${UNIFIOS_KEYSTORE_PATH}/keystore -srckeystore ${UNIFIOS_KEYSTORE_PATH}/unifi-core-key-plus-server-only-cert.p12 \
			-srcstoretype PKCS12 -srcstorepass ${UNIFIOS_KEYSTORE_PASSWORD} -alias ${UNIFIOS_KEYSTORE_CERT_ALIAS} -noprompt
	else
		# Import full certificate chain bundle to keystore
		echo "	- Importing full certificate chain bundle"
		podman exec -it unifi-os ${CERT_IMPORT_CMD} ${UNIFIOS_CERT_PATH}/unifi-core.key ${UNIFIOS_CERT_PATH}/unifi-core.crt
	fi
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

PODMAN_CMD="podman run --env-file=${UDM_LE_PATH}/udm-le.env -it --name=lego --network=host --rm ${DOCKER_VOLUMES} ${CONTAINER_IMAGE}:${CONTAINER_IMAGE_TAG}"

case $1 in
initial)
	# Create lego directory so the container can write to it
	if [ "$(stat -c '%u:%g' "${UDM_LE_PATH}/lego")" != "1000:1000" ]; then
		mkdir "${UDM_LE_PATH}"/lego
		chown 1000:1000 "${UDM_LE_PATH}"/lego
	fi

	echo 'Attempting initial certificate generation'
	${PODMAN_CMD} ${LEGO_ARGS} --accept-tos run && deploy_certs && restart_services
	;;
renew)
	echo 'Attempting certificate renewal'
	echo ${PODMAN_CMD} ${LEGO_ARGS}
	${PODMAN_CMD} ${LEGO_ARGS} renew --days 60 && deploy_certs && restart_services
	;;
test_deploy)
	echo 'Attempting to deploy certificate'
	deploy_certs
	;;
update_keystore)
	echo 'Attempting to update keystore used by hotspot Captive Portal and WiFiman'
	update_keystore && restart_services
	;;
*)
	echo "ERROR: No valid action provided."
	usage;
	exit 1;
esac
