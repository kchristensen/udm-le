# Let's Encrypt for Ubiquiti UniFi OS

## Overview

This should work on UniFi Dream Machines running UniFi OS 2.x+, including:

* UniFi Dream Machine
* UniFi Dream Machine Pro
* UniFi Dream Machine SE
* UniFi Dream Wall

This script supports issuing Let's Encrypt SSL certificates via DNS using [Lego](https://go-acme.github.io/lego/).

Out of the box, it has tested support for select [DNS providers](#dns-providers) but with little work you could get it working with any of the supported [Lego DNS Providers](https://go-acme.github.io/lego/dns/).

## Installation

1. Copy the contents of this repo to your device at `/data/udm-le`.
2. Edit `/data/udm-le/udm-le.env` and tweak variables to meet your needs.
3. If necessary, create and populate the `/data/udm-le/.secrets` directory with the files required by your DNS provider.
4. Run `/data/udm-le/udm-le.sh initial`. This will handle your initial certificate generation and setup a systemd service to start the service on boot, as well as a systemd timer to attempt certificate renewal each morning between 0300 and 0305.

## DNS Providers

### AWS Route53

AWS Route53 DNS challenge can use configuration and authentication values easily through shared credentials and configuration files [as described here](https://go-acme.github.io/lego/dns/route53/). This script will check for and include these files during the initial certificate generation and subsequent renewals. Ensure that `route53` is set for `DNS_PROVIDER` in `udm-le.env`, create a new directory called `.secrets` in `/data/udm-le` and add `credentials` and `config` files as required for your authentication. See the [AWS CLI Documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html) for more information. Currently only the `default` profile is supported.

### Azure DNS

If not done already, [delegate a domain to an Azure DNS zone](https://docs.microsoft.com/en-us/azure/dns/dns-delegate-domain-azure-dns).

Assuming the DNS zone lives in subscription `00000000-0000-0000-0000-000000000000` and resource group `udm-le`, with help of the [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/) provision an identity to manage the DNS zone by running:

```bash
# Login
az login

# Create a service principal with contributor (default) permissions over the godns resource group
az ad sp create-for-rbac --name godns --scope /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/udm-le --role contributor
```

### Cloudflare

In your Cloudflare account settings, create an API token with the following permissions:

* Zone > Zone > Read
* Zone > DNS > Edit

Once you have your token generated, add the value to `udm-le.env`.

### Digital Ocean

If you use DigitalOcean as your DNS provider, set your `DNS_PROVIDER` to `digitalocean` and configure your `DO_AUTH_TOKEN`. Note: Quoting your `DO_AUTH_TOKEN` seems to cause issues with Lego.

### DuckDNS

If you use DuckDNS as your DNS provider, set your `DNS_PROVIDER` to `duckdns` and configure your `DUCKDNS_TOKEN`.

### Gandi Live DNS (v5)

If you use Gandi Live DNS (v5) as your DNS provider, set your `DNS_PROVIDER` to `gandiv5` and configure your `GANDIV5_API_KEY`. You can obtain your API key at your [account settings](https://account.gandi.net/).

### Google Cloud DNS

GCP Cloud DNS can be configured by establishing a service account with the role [`roles/dns.admin`](https://cloud.google.com/iam/docs/understanding-roles#dns-roles) and exporting a [service account key](https://cloud.google.com/iam/docs/creating-managing-service-account-keys) for that service account. Ensure that `gcloud` is set for `DNS_PROVIDER` in `udm-le.env`, and `GCE_SERVICE_ACCOUNT_FILE` references the path to the service account key (e.g. `./root/.secrets/my_service_account.json`) . Create a new directory called `.secrets` in `/data/udm-le` and add the service account file.

The CLI will output a JSON object. Use the printed properties to initialize your configuration in [udm-le.env](./udm-le.env).

Note:

* The `password` value is a secret and as such you may want to omit it from [udm-le.env](./udm-le.env) and instead set it in a `.secrets/client-secret.txt` file
* The `appId` value is what [Lego](https://go-acme.github.io/lego/) calls a client id

### Google Domains

If you use Google Domains as your DNS provider, set the `DNS_PROVIDER` to `googledomains` and configure `GOOGLE_DOMAINS_ACCESS_TOKEN` with your access token. You can create an access token in your Google Domains dashboard under YOUR_DOMAIN > Security > ACME DNS API.

### Linode DNS

If you use Linode as your DNS provider, set your `DNS_PROVIDER` to `linode` and configure `LINODE_TOKEN` with the value of an API token. The API token must have a scope which allows Read/Write access to "Domains". API tokens can be created in the Linode Control panel.

### Name.com

Follow [these instructions](https://www.name.com/support/articles/360007597874-signing-up-for-api-access) from name.com support to enable api access.

At the time of writing, the first few steps our out of date and I had to click `API for resellers` under the more menu which should get you to step 3.

If using Multifactor to login then you will need to read [this article](https://www.name.com/support/articles/360007989433-using-api-with-two-step-authentication) about how to disable multifactor for api only.

There are two values needed for the `udm-le.env` file: your name.com username; your generated api token for production.

### Oracle Cloud Infrastructure (OCI) DNS

To configure the Oracle Cloud Infrastructure (OCI) DNS provider, you will need a [private API signing key](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm) and your [tenancy and user account OCIDs](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm#five). The quickest way to get all that is to install the [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm) locally and use its [interactive setup process](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm#configfile).

The setup process will create a `~/.oci/config` directory in which you can find your tenancy and user account OCIDs and key fingerprint and the API signing key will be stored in `~/.oci/oci_api_key.pem`. The following CLI command will return the compartment OCID for the specified OCI DNS zone:

```bash
$ oci dns zone get --zone-name-or-id example.com | jq -r '.data."compartment-id"'
ocid1.compartment.oc1..secret
```

#### To configure the provider

> **Important: do not wrap the values of the `OCI_*` variables in `udm-le.env` with quotes. The lack of quotes around the example values provided in [`udm-le.env`](./udm-le.env) is intentional and must be maintained.

1. Set the `DNS_PROVIDER` value to `"oraclecloud"`
1. Uncomment and copy the values from each `~/.oci/config` variable to the similarly named `OCI_*` variable in `udm-le.env`.
1. Create a new directory at `/data/udm-le/.secrets` and copy the `oci_api_key.pem` file that directory.

### Zonomi

If you use Zonomi as your DNS provider, set your `DNS_PROVIDER` to `zonomi` and configure your `ZONOMI_API_KEY`.

The API key can be obtained [in your control panel](https://zonomi.com/app/cp/apikeys.jsp) under the DNS key type.
