#!/usr/bin/env bash
# Provision WordPress Stable

DB_NAME=`get_config_value 'db_name' "${VVV_SITE_NAME}"`
DB_NAME=${DB_NAME//[\\\/\.\<\>\:\"\'\|\?\!\*]/}
VVV_CONFIG=/vagrant/vvv-config.yml

if [[ -f /vagrant/vvv-custom.yml ]]; then
  VVV_CONFIG=/vagrant/vvv-custom.yml
fi

get_host() {
  local value=`cat ${VVV_CONFIG} | shyaml get-value sites.${1}.hosts.0 2> /dev/null`
  echo ${value:-$@}
}

get_hosts() {
  local value=`cat ${VVV_CONFIG} | shyaml get-values sites.${1}.hosts 2> /dev/null`
  echo ${value:-$@}
}

# Make a database, if we don't already have one
echo -e "\nCreating database '${DB_NAME}' (if it's not already there)"
mysql -u root --password=root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`"
echo -e "\nGranting the wp user priviledges to the '${DB_NAME}' database"
mysql -u root --password=root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO wp@localhost IDENTIFIED BY 'wp';"
echo -e "\n DB operations done.\n\n"

echo "Setting up the log subfolder for Nginx logs"
noroot mkdir -p ${VVV_PATH_TO_SITE}/log
noroot touch ${VVV_PATH_TO_SITE}/log/nginx-error.log
noroot touch ${VVV_PATH_TO_SITE}/log/nginx-access.log

echo "Creating SSL certification"
VVV_CERT_DIR="${VVV_PATH_TO_SITE}/certificates"
SSL_CRT="${VVV_CERT_DIR}/${VVV_SITE_NAME}.crt"
SSL_KEY="${VVV_CERT_DIR}/${VVV_SITE_NAME}.key"

if [ -f "${SSL_CRT}" ] && [ -f "${SSL_KEY}" ]; then
  echo "SSL certification already exists"
else
  echo "Generating certificates for the ${VVV_SITE_NAME} hosts"
  SITE_ESCAPED=`echo ${VVV_SITE_NAME} | sed 's/\./\\\\./g'`
  COMMON_NAME=`get_host ${SITE_ESCAPED}`
  HOSTS=`get_hosts ${SITE_ESCAPED}`
  CERT_DIR="${VVV_CERT_DIR}"
  CA_DIR="/srv/certificates/ca"

  if [[ $codename == "trusty" ]]; then # VVV 2 uses Ubuntu 14 LTS trusty
    CA_DIR="/vagrant/certificates/ca"
  fi

  cat << EOF > ${CERT_DIR}/openssl.conf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
[alt_names]
EOF

  I=0
  for DOMAIN in ${HOSTS}; do
    ((I++))
    echo DNS.${I} = ${DOMAIN} >> ${CERT_DIR}/openssl.conf
    ((I++))
    echo DNS.${I} = *.${DOMAIN} >> ${CERT_DIR}/openssl.conf
  done

  openssl genrsa \
    -out ${CERT_DIR}/${VVV_SITE_NAME}.key \
    2048 &>/dev/null

  openssl req \
    -new \
    -key ${CERT_DIR}/${VVV_SITE_NAME}.key \
    -out ${CERT_DIR}/${VVV_SITE_NAME}.csr \
    -subj "/CN=${COMMON_NAME}" &>/dev/null

  openssl x509 \
    -req \
    -in ${CERT_DIR}/${VVV_SITE_NAME}.csr \
    -CA ${CA_DIR}/ca.crt \
    -CAkey ${CA_DIR}/ca.key \
    -CAcreateserial \
    -out ${CERT_DIR}/${VVV_SITE_NAME}.crt \
    -days 3650 \
    -sha256 \
    -extfile ${CERT_DIR}/openssl.conf &>/dev/null

  echo "Finished generating TLS certificates"
fi

echo "Inserting the SSL key locations into the sites Nginx config"

sed -i "s#{{TLS_CERT}}#ssl_certificate ${VVV_CERT_DIR}/${VVV_SITE_NAME}.crt;#" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
sed -i "s#{{TLS_KEY}}#ssl_certificate_key ${VVV_CERT_DIR}/${VVV_SITE_NAME}.key;#" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"

LIVE_URL=`get_config_value 'live_url' ''`
if [ ! -z "$LIVE_URL" ]; then
  # repalce potential protocols, and remove trailing slashes
  LIVE_URL=$(echo ${LIVE_URL} | sed 's|https://||' | sed 's|http://||'  | sed 's:/*$::')

  redirect_config=$((cat <<END_HEREDOC
if (!-e \$request_filename) {
  rewrite ^/[_0-9a-zA-Z-]+(/wp-content/uploads/.*) \$1;
}
if (!-e \$request_filename) {
  rewrite ^/wp-content/uploads/(.*)\$ \$scheme://${LIVE_URL}/wp-content/uploads/\$1 redirect;
}
END_HEREDOC

  ) |
  # pipe and escape new lines of the HEREDOC for usage in sed
  sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n\\1/g'
  )

  sed -i -e "s|\(.*\){{LIVE_URL}}|\1${redirect_config}|" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
else
  sed -i "s#{{LIVE_URL}}##" "${VVV_PATH_TO_SITE}/provision/vvv-nginx.conf"
fi

echo "Site Template provisioner script completed"
