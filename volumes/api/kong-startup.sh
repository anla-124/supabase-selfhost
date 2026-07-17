#!/bin/sh
# Substitute env vars into kong template before starting Kong.
# \${VAR} in the pattern = literal ${VAR} to match in the template.
# ${VAR}  in the replacement = shell expands to the actual value.
sed \
  -e "s|\${ANON_KEY}|${ANON_KEY}|g" \
  -e "s|\${SERVICE_ROLE_KEY}|${SERVICE_ROLE_KEY}|g" \
  -e "s|\${DASHBOARD_USERNAME}|${DASHBOARD_USERNAME:-supabase}|g" \
  -e "s|\${DASHBOARD_PASSWORD}|${DASHBOARD_PASSWORD}|g" \
  -e "s|\${STUDIO_HOSTNAME}|${STUDIO_HOSTNAME}|g" \
  /home/kong/temp.yml > /tmp/kong.yml

# Kong 3.x (kong/kong image) runs as uid 1001 and no longer creates a writable
# /home/kong, and its entrypoint moved from /docker-entrypoint.sh to /entrypoint.sh.
# Render into world-writable /tmp and point KONG_DECLARATIVE_CONFIG at /tmp/kong.yml.
exec /entrypoint.sh kong docker-start
