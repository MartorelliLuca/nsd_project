#!/bin/sh
set -eu

CA_CN="${CA_CN:-NSD_project}"
EASYRSA_DIR="/usr/share/easy-rsa"
OPENVPN_BASE="/root/openvpn"
SERVER_NAME="CE3"
CLIENTS="CE1 CE2"

PKI_DIR="${EASYRSA_DIR}/pki"

cd "${EASYRSA_DIR}"

pki_complete() {
  [ -d "${PKI_DIR}" ] \
    && [ -f "${PKI_DIR}/ca.crt" ] \
    && [ -f "${PKI_DIR}/issued/${SERVER_NAME}.crt" ] \
    && [ -f "${PKI_DIR}/private/${SERVER_NAME}.key" ]
}

if pki_complete; then
  echo "PKI already present, skipping generation"
else
  export EASYRSA_BATCH=1
  export EASYRSA_REQ_CN="${CA_CN}"

  ./easyrsa init-pki
  ./easyrsa build-ca nopass
  ./easyrsa build-server-full "${SERVER_NAME}" nopass

  for c in ${CLIENTS}; do
    ./easyrsa build-client-full "${c}" nopass
  done

  ./easyrsa gen-dh
fi

# Directory di destinazione
mkdir -p \
  "${OPENVPN_BASE}/keys" \
  "${OPENVPN_BASE}/export/CE1" \
  "${OPENVPN_BASE}/export/CE2"

# Server (CE3)
cp -f "${PKI_DIR}/ca.crt"              "${OPENVPN_BASE}/keys/ca.crt"
cp -f "${PKI_DIR}/dh.pem"              "${OPENVPN_BASE}/keys/dh.pem"
cp -f "${PKI_DIR}/issued/${SERVER_NAME}.crt"  "${OPENVPN_BASE}/keys/${SERVER_NAME}.crt"
cp -f "${PKI_DIR}/private/${SERVER_NAME}.key" "${OPENVPN_BASE}/keys/${SERVER_NAME}.key"

# Export client
for c in ${CLIENTS}; do
  mkdir -p "${OPENVPN_BASE}/export/${c}"
  cp -f "${PKI_DIR}/ca.crt"             "${OPENVPN_BASE}/export/${c}/ca.crt"
  cp -f "${PKI_DIR}/issued/${c}.crt"    "${OPENVPN_BASE}/export/${c}/${c}.crt"
  cp -f "${PKI_DIR}/private/${c}.key"   "${OPENVPN_BASE}/export/${c}/${c}.key"
done

echo "PKI ready. Exports in ${OPENVPN_BASE}/export/"