#!/usr/bin/env python3
"""Render public-TLS Caddy config; creates a new 0600 file and does not deploy."""
import os,pathlib,re,urllib.parse
root=pathlib.Path(os.environ['AIRSIM_SECRET_DIR'])
hosts=[]
for name in ('API','DEVICE','MEDIA'):
    origin=os.environ['AIRSIM_'+name+'_ORIGIN']
    u=urllib.parse.urlsplit(origin)
    if u.scheme!='https' or not u.hostname or u.port not in (None,443) or u.path or u.query or u.fragment or u.username or u.password:
        raise SystemExit('production_origin_invalid')
    if not re.fullmatch(r'[a-z0-9]+(?:[a-z0-9.-]*[a-z0-9])?',u.hostname):
        raise SystemExit('production_hostname_invalid')
    hosts.append(u.hostname)
api,device,media=hosts
if device in (api,media): raise SystemExit('device_hostname_must_be_separate')
config='''{
 admin off
 http_port 8080
 https_port 8443
 persist_config off
 log {
  level ERROR
 }
 servers {
  protocols h1 h2
 }
}
'''
def proxy(host, target, path=''):
    return f"""https://{host} {{
 reverse_proxy {path} {target}:8080 {{
  header_up -X-AirSIM-Client-Cert
  header_up -X-AirSIM-Edge-Token
 }}
}}
"""
config+=f"""https://{api} {{
"""
if media==api:
    config+=""" handle /v2/media {
  reverse_proxy media:8080 {
   header_up -X-AirSIM-Client-Cert
   header_up -X-AirSIM-Edge-Token
  }
 }
"""
config+=""" @control path /.well-known/airsim /v2/modules /v2/modules/* /healthz /readyz
 handle @control {
  reverse_proxy control:8080 {
   header_up -X-AirSIM-Client-Cert
   header_up -X-AirSIM-Edge-Token
  }
 }
 respond 404
}
"""
if media!=api:
    config+=proxy(media,'media','/v2/media')
config+=f"""https://{device} {{
 tls {{
  protocols tls1.2 tls1.3
  client_auth {{
   mode require_and_verify
   trust_pool file /run/secrets/device-ca.pem
  }}
 }}
 reverse_proxy /v2/device/control control:8080 {{
  header_up X-AirSIM-Client-Cert {{http.request.tls.client.certificate_der_base64}}
  header_up X-AirSIM-Edge-Token {{file./run/secrets/edge-token}}
 }}
}}
"""
fd=os.open(root/'Caddyfile',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f:
    f.write(config)
    f.flush()
    os.fsync(f.fileno())
