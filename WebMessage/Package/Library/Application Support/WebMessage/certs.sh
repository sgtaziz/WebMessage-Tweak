#!/bin/bash

cd /Library/Application\ Support/WebMessage

PASSPHRASE=$(openssl rand -base64 16)
echo "$PASSPHRASE" > ./passphrase

openssl req -new -newkey rsa:4096 -nodes -x509 -subj "/C=US/ST=CA/L=/O=/CN=WebMessage" -keyout webmessage.key -out webmessage.pem -outform pem 2>&1 > /dev/null
openssl x509 -in webmessage.pem -inform pem -out webmessage.der -outform der 2>&1 > /dev/null
openssl pkcs12 -export -out webmessage.p12 -inkey webmessage.key -in webmessage.pem -passout pass:$PASSPHRASE 2>&1 > /dev/null
