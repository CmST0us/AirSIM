#!/usr/bin/env python3
import os,pathlib,sys
root=pathlib.Path(os.environ['AIRSIM_SECRET_DIR'])
config='''{
 admin off
 auto_https off
 persist_config off
 log {
  level ERROR
 }
 servers {
  protocols h1 h2
 }
}
https://api.airsim.test:8443 {
 tls /run/tls/server.pem /run/tls/server-key.pem {
  protocols tls1.2 tls1.3
 }
 reverse_proxy control:8080 {
  header_up -X-AirSIM-Client-Cert
  header_up -X-AirSIM-Edge-Token
 }
}
https://media.airsim.test:8443 {
 tls /run/tls/server.pem /run/tls/server-key.pem {
  protocols tls1.2 tls1.3
 }
 reverse_proxy /v2/media media:8080 {
  header_up -X-AirSIM-Client-Cert
  header_up -X-AirSIM-Edge-Token
 }
}
https://device.airsim.test:8443 {
 tls /run/tls/server.pem /run/tls/server-key.pem {
  protocols tls1.2 tls1.3
  client_auth {
   mode require_and_verify
   trust_pool file /run/secrets/device-ca.pem
  }
 }
 reverse_proxy /v2/device/control control:8080 {
  header_up X-AirSIM-Client-Cert {http.request.tls.client.certificate_der_base64}
  header_up X-AirSIM-Edge-Token {file./run/secrets/edge-token}
 }
}
'''
fd=os.open(root/'Caddyfile',os.O_WRONLY|os.O_CREAT|(os.O_TRUNC if '--replace' in sys.argv else os.O_EXCL),0o600)
with os.fdopen(fd,'w') as f:f.write(config)
