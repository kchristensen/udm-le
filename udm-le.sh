#!/bin/bash

# Set error mode
set -e

# Load environment variables
set -a
source /data/udm-le/udm-le.env
set +a

# Setup additional variables for later
LEGO_ARGS="--dns ${DNS_PROVIDER} --dns.resolvers ${DNS_RESOLVER} --email ${CERT_EMAIL} --key-type ${KEY_TYPE:-RSA2048}"
LEGO_FORCE_INSTALL=false
JAVA_FORCE_INSTALL=false
RESTART_SERVICES=false

# Show usage
usage() {
	echo "Usage: udm-le.sh action [ --restart-services ]"
	echo "Actions:"
	echo "  - udm-le.sh create_services: Force (re-)creates systemd service and timer for automated renewal."
	echo "  - udm-le.sh initial: Generate new certificate and set up cron job to renew at 03:00 each morning."
	echo "  - udm-le.sh install_lego: Force (re-)installs lego, using LEGO_VERSION from udm-le.env."
	echo "  - udm-le.sh renew: Renew certificate if due for renewal."
	echo "  - udm-le.sh update_keystore: Update keystore used by Captive Portal/WiFiman"
	echo "              with either full certificate chain (if NO_BUNDLE='no') or server certificate only (if NO_BUNDLE='yes')."
	echo ""
	echo "Options:"
	echo "  --restart-services: Force restart of services even if certificate was not renewed."
	echo ""
	echo "WARNING: NO_BUNDLE option is only supported experimentally. Setting it to 'yes' is required to make WiFiman work,"
	echo "but may result in some clients not being able to connect to Captive Portal if they do not already have a cached"
	echo "copy of the CA intermediate certificate(s) and are unable to download them."
}

# Get command line options
OPTIONS=$(getopt -o h --long help,restart-services -- "$@")
if [ $? -ne 0 ]; then
	echo "Incorrect option provided"
	exit 1
fi

eval set -- "$OPTIONS"
while [ : ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		shift
		;;
	--restart-services)
		RESTART_SERVICES=true
		shift
		;;
	--)
		shift
		break
		;;
	esac
done

create_services() {
	# Create systemd service and timers (for renewal)
	echo "create_services(): Creating udm-le systemd service and timer"
	cp -f "${UDM_LE_PATH}/resources/systemd/udm-le.service" /etc/systemd/system/udm-le.service
	cp -f "${UDM_LE_PATH}/resources/systemd/udm-le.timer" /etc/systemd/system/udm-le.timer
	systemctl daemon-reload
	systemctl enable udm-le.timer
}

deploy_certs() {
	# Deploy certificates for the controller and optionally for the captive portal and radius server

	# Re-write CERT_NAME if it is a wildcard cert. Replace * with _
	LEGO_CERT_NAME=${CERT_NAME/\*/_}
	if [ "$(find -L "${UDM_LE_PATH}"/.lego -type f -name "${LEGO_CERT_NAME}".crt -mmin -5)" ]; then
		echo "deploy_certs(): New certificate was generated, time to deploy it"

		cp -f "${UDM_LE_PATH}"/.lego/certificates/"${LEGO_CERT_NAME}".crt "${UBIOS_CONTROLLER_CERT_PATH}"/unifi-core.crt
		cp -f "${UDM_LE_PATH}"/.lego/certificates/"${LEGO_CERT_NAME}".key "${UBIOS_CONTROLLER_CERT_PATH}"/unifi-core.key
		chmod 644 "${UBIOS_CONTROLLER_CERT_PATH}"/unifi-core.crt "${UBIOS_CONTROLLER_CERT_PATH}"/unifi-core.key

		if [ "$ENABLE_CAPTIVE" == "yes" ]; then
			update_keystore
		fi

		if [ "$ENABLE_RADIUS" == "yes" ]; then
			cp -f "${UDM_LE_PATH}"/.lego/certificates/"${LEGO_CERT_NAME}".crt "${UBIOS_RADIUS_CERT_PATH}"/server.pem
			cp -f "${UDM_LE_PATH}"/.lego/certificates/"${LEGO_CERT_NAME}".key "${UBIOS_RADIUS_CERT_PATH}"/server-key.pem
			chmod 600 "${UBIOS_RADIUS_CERT_PATH}"/server.pem "${UBIOS_RADIUS_CERT_PATH}"/server-key.pem
		fi

		RESTART_SERVICES=true
	fi
}

restart_services() {
	# Restart services if certificates have been deployed, or we're forcing it on the command line
	if [ "${RESTART_SERVICES}" == true ]; then
		echo "restart_services(): Restarting unifi-core"
		systemctl restart unifi-core &>/dev/null

		if [ "$ENABLE_CAPTIVE" == "yes" ]; then
	  		echo "restart_services(): Restarting unifi"
			systemctl restart unifi &>/dev/null
   		fi

		if [ "$ENABLE_RADIUS" == "yes" ]; then
			echo "restart_services(): Restarting freeradius server"
			systemctl restart freeradius &>/dev/null
		fi
	else
		echo "restart_services(): RESTART_SERVICES is set to false, skipping service restarts"
	fi
}

update_keystore() {
	# Update the java keystore with the new certificate
	if [ "$NO_BUNDLE" == "yes" ]; then
		# Only import server certifcate to keystore. WiFiman requires a single certificate in the .crt file
		# and does not work if the full chain is imported as this includes the CA intermediate certificates.
		echo "update_keystore(): Importing server certificate only"

		# Export only the server certificate from the full chain bundle
		openssl x509 -in "${UNIFIOS_CERT_PATH}"/unifi-core.crt >"${UNIFIOS_CERT_PATH}"/unifi-core-server-only.crt

		# Bundle the private key and server-only certificate into a PKCS12 format file
		openssl pkcs12 \
			-export \
			-in "${UNIFIOS_CERT_PATH}"/unifi-core-server-only.crt \
			-inkey "${UNIFIOS_CERT_PATH}"/unifi-core.key \
			-name "${UNIFIOS_KEYSTORE_CERT_ALIAS}" \
			-out "${UNIFIOS_KEYSTORE_PATH}"/unifi-core-key-plus-server-only-cert.p12 \
			-password pass:"${UNIFIOS_KEYSTORE_PASSWORD}"

		# Backup the keystore before editing it.
		cp "${UNIFIOS_KEYSTORE_PATH}/keystore" "${UNIFIOS_KEYSTORE_PATH}/keystore_$(date +"%Y-%m-%d_%Hh%Mm%Ss").backup"

		# Delete the existing full chain from the keystore
		keytool -delete -alias unifi -keystore "${UNIFIOS_KEYSTORE_PATH}/keystore" -deststorepass "${UNIFIOS_KEYSTORE_PASSWORD}"

		# Import the server-only certificate and private key from the PKCS12 file
		keytool -importkeystore \
			-alias "${UNIFIOS_KEYSTORE_CERT_ALIAS}" \
			-destkeypass "${UNIFIOS_KEYSTORE_PASSWORD}" \
			-destkeystore "${UNIFIOS_KEYSTORE_PATH}/keystore" \
			-deststorepass "${UNIFIOS_KEYSTORE_PASSWORD}" \
			-noprompt \
			-srckeystore "${UNIFIOS_KEYSTORE_PATH}/unifi-core-key-plus-server-only-cert.p12" \
			-srcstorepass "${UNIFIOS_KEYSTORE_PASSWORD}" \
			-srcstoretype PKCS12
	else
		# Import full certificate chain bundle to keystore
		echo "update_keystore(): Importing full certificate chain bundle"
		${CERT_IMPORT_CMD} "${UNIFIOS_CERT_PATH}/unifi-core.key" "${UNIFIOS_CERT_PATH}/unifi-core.crt"
	fi
}

install_lego() {
	# Check if lego exists already, do nothing
	if [ ! -f "${LEGO_BINARY}" ] || [ "${LEGO_FORCE_INSTALL}" = true ]; then
		echo "install_lego(): Attempting lego installation"

		# Download and extract lego release
		echo "install_lego(): Downloading lego v${LEGO_VERSION} from ${LEGO_DOWNLOAD_URL}"
		wget -qO "/tmp/lego_release-${LEGO_VERSION}.tar.gz" "${LEGO_DOWNLOAD_URL}"

		echo "install_lego(): Extracting lego binary from release and placing at ${LEGO_BINARY}"
		tar -xozvf "/tmp/lego_release-${LEGO_VERSION}.tar.gz" --directory="${UDM_LE_PATH}" lego

		# Verify lego binary integrity
		echo "install_lego(): Verifying integrity of lego binary"
		LEGO_HASH=$(sha1sum "${LEGO_BINARY}" | awk '{print $1}')
		if [ "${LEGO_HASH}" = "${LEGO_SHA1}" ]; then
			echo "install_lego(): Verified lego v${LEGO_VERSION}:${LEGO_SHA1}"
			chmod +x "${LEGO_BINARY}"
		else
			echo "install_lego(): Verification failure, lego binary sha1 was ${LEGO_HASH}, expected ${LEGO_SHA1}. Cleaning up and aborting"
			rm -f "${UDM_LE_PATH}/lego" "/tmp/lego_release-${LEGO_VERSION}.tar.gz"
			exit 1
		fi
	else
		echo "install_lego(): Lego binary is already installed at ${LEGO_BINARY}, no operation necessary"
	fi
}

install_java() {
	# Check if lego exists already, do nothing
	if [ ! -f "${JAVA_BINARY}" ] || [ "${JAVA_FORCE_INSTALL}" = true ]; then
		echo "install_java(): Attempting java installation"

		# install jre via apt
		apt install default-jre-headless
	else
		echo "install_java(): Java binary is already installed at ${JAVA_BINARY}, no operation necessary"
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

case $1 in
create_services)
	echo "create_services(): Creating services"
	create_services
	;;
initial)
	install_lego
	install_java
	create_services
	echo "initial(): Attempting certificate generation"
	echo "initial(): ${LEGO_BINARY} --path \"${LEGO_PATH}\" ${LEGO_ARGS} --accept-tos run"
	${LEGO_BINARY} --path "${LEGO_PATH}" ${LEGO_ARGS} --accept-tos run && deploy_certs && restart_services
	echo "initial(): Starting udm-le systemd timer"
	systemctl start udm-le.timer
	;;
install_lego)
	echo "install_lego(): Forcing installation of lego"
	LEGO_FORCE_INSTALL=true
	install_lego
	;;
install_java)
	echo "install_java(): Forcing installation of java"
	JAVA_FORCE_INSTALL=true
	install_java
	;;
renew)
	echo "renew(): Attempting certificate renewal"
	echo "renew(): ${LEGO_BINARY} --path \"${LEGO_PATH}\" ${LEGO_ARGS} renew --days ${CERT_DAYS_BEFORE_RENEWAL:-30}"
	${LEGO_BINARY} --path "${LEGO_PATH}" ${LEGO_ARGS} renew --days ${CERT_DAYS_BEFORE_RENEWAL:-30} && deploy_certs && restart_services
	;;
test_deploy)
	echo "test_deploy(): Attempting to deploy certificate"
	deploy_certs
	;;
update_keystore)
	echo "update_keystore(): Attempting to update keystore used by hotspot Captive Portal and WiFiman"
	RESTART_SERVICES=true
	update_keystore && restart_services
	;;
*)
	echo "ERROR: No valid action provided."
	usage
	exit 1
	;;
esac
