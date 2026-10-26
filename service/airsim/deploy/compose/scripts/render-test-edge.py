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
 route {
  @pairing path /v2/pairing/*
  handle @pairing {
   reverse_proxy control:8080 {
    header_up -X-AirSIM-Client-Cert
    header_up X-AirSIM-Edge-Token {file./run/secrets/edge-token}
    header_up X-AirSIM-Remote-IP {http.request.remote.host}
   }
  }
  @control path /.well-known/airsim /v2/device/control /v2/modules /v2/modules/* /v2/push/registration /v2/client-sessions/refresh /healthz /readyz
  handle @control {
   reverse_proxy control:8080 {
    header_up -X-AirSIM-Client-Cert
    header_up -X-AirSIM-Edge-Token
   }
  }
  handle /v2/* {
   respond 404
  }
  handle {
   root * /srv/airsim-web
   header {
    Cache-Control "no-store"
    X-Content-Type-Options "nosniff"
    Content-Security-Policy "default-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    Permissions-Policy "usb=(self), camera=(), microphone=()"
   }
   try_files {path} /index.html
   file_server
  }
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
