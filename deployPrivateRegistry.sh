#!/bin/bash

# Variables
REGISTRY_NAME=private-registry
REGISTRY_PORT=5000
CERTS_DIR=$(pwd)/dpr/certs
AUTH_DIR=$(pwd)/dpr/auth
DOCKER_CERTS_DIR=/etc/docker/certs.d
HOSTNAME=$(hostname)
DOMAIN=$(hostname -d)
IP_ADDRESSES=$(hostname -I | tr ' ' '\n' | sed '/^$/d')
PASSWORD_LENGTH=16
PASSWORD=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c $PASSWORD_LENGTH)

# Creating required directories
mkdir -p $CERTS_DIR $AUTH_DIR

# Building the subjectAltName line
SAN="DNS:localhost,DNS:$HOSTNAME"
if [[ -n "$DOMAIN" ]]; then
  SAN="$SAN,DNS:$HOSTNAME.$DOMAIN"
fi
SAN="$SAN,IP:127.0.0.1"

for ip in $IP_ADDRESSES; do
  SAN="$SAN,IP:$ip"
done

# Generating Self-Signed SSL Certificate
openssl req -newkey rsa:4096 -nodes -sha256 -keyout $CERTS_DIR/domain.key -subj "/C=US/ST=State/L=City/O=Organization/OU=IT Department/CN=$HOSTNAME" -addext "subjectAltName = $SAN" -x509 -days 365 -out $CERTS_DIR/domain.crt

# Creating username and password for authentication
if ! command -v htpasswd &> /dev/null; then
  echo "htpasswd not found, using container to generate password."
  docker run --rm httpd:2.4 htpasswd -Bbn admin $PASSWORD > $AUTH_DIR/htpasswd
else
  htpasswd -Bbn admin $PASSWORD > $AUTH_DIR/htpasswd
fi

# Adding certificate to system key store
if [[ -f /etc/redhat-release ]]; then
  sudo cp $CERTS_DIR/domain.crt /etc/pki/ca-trust/source/anchors/
  sudo update-ca-trust
elif [[ -f /etc/lsb-release || -f /etc/os-release ]]; then
  sudo cp $CERTS_DIR/domain.crt /usr/local/share/ca-certificates/domain.crt
  sudo update-ca-certificates
elif [[ "$(uname -s)" == "Darwin" ]]; then
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CERTS_DIR/domain.crt
fi

# Adding Certificate to Docker
DOCKER_CERT_PATH="$DOCKER_CERTS_DIR/$HOSTNAME:5000"
sudo mkdir -p "$DOCKER_CERT_PATH"
sudo cp "$CERTS_DIR/domain.crt" "$DOCKER_CERT_PATH/ca.crt"

# Restart Docker to load certificates
sudo systemctl restart docker

# Starting the Registry container with HTTPS support and authentication
docker run -d --restart=always --name $REGISTRY_NAME -p $REGISTRY_PORT:5000 -v $CERTS_DIR:/certs -v $AUTH_DIR:/auth -e REGISTRY_HTTP_ADDR=0.0.0.0:5000 -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key -e "REGISTRY_AUTH=htpasswd" -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" -e "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd" registry:2

# View registry Status
docker ps | grep $REGISTRY_NAME

# Login test
docker login https://localhost:$REGISTRY_PORT -u admin -p $PASSWORD

echo "#############################################################################"
echo "Registry is running on https://localhost:$REGISTRY_PORT with authentication."
echo "Save your password, it will not be generated again: $PASSWORD"
echo "#############################################################################"
