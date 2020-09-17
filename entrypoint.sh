#!/usr/bin/env bash
set -e

DAEMON=sshd
TURBOADDR=${TURBOADDR:="api:8080"}
TURBOUSER=${TURBOUSER:="administrator"}
TURBOPASS=${TURBOPASS:="administrator"}
ADDR=${ADDR:="actionscripts"}
PORT=${PORT:=22}
USER=${USER:="turbo"}
MANPATH=${MANPATH:="/actionscripts/manifest.json"}
cookies=/tmp/.cookies

stop() {
    echo "Received SIGINT or SIGTERM. Shutting down $DAEMON"
    # Get PID
    local pid=$(cat /var/run/$DAEMON/$DAEMON.pid)
    # Set TERM
    kill -SIGTERM "${pid}"
    # Wait for exit
    wait "${pid}"
    # All done.
    echo "Done."
}

function vmtLogin() {
  vmtLogout
  local login="http://${TURBOADDR}/vmturbo/rest/login"
  echo Login response:
  curl -s -k -K POST -d "username=${TURBOUSER}&password=${TURBOPASS}" -c $cookies $login \
     | python -m json.tool
}

function vmtLogout() {
  rm -rf $cookies
}

function vmtCreateTarget() {
    local pkey=$(awk 'ORS="\\n"' "/sshkeys/turboauthorizedkey")
    local url="http://$TURBOADDR/vmturbo/rest/targets"
    local payload="$(getRequest "$pkey")"
    echo $payload
    echo Target creation response:
    curl -s -k -K POST -d "$payload" -H 'Content-Type: application/json' -b $cookies "$url" \
	| python -m json.tool
}

function getRequest() {
    local inputFields=$(mkarray \
			    "$(mkobject name '"nameOrAddress"' value '"'"$ADDR"'"')" \
			    "$(mkobject name '"port"' value $PORT)" \
			    "$(mkobject name '"manifestPath"' value '"'"$MANPATH"'"')" \
			    "$(mkobject name '"userid"' value '"'"$USER"'"')" \
			    "$(mkobject name '"privateKeyString"' value '"'"$1"'"')" \
			)
    echo "$(mkobject category '"Orchestrator"' type '"Action Script"' inputFields "$inputFields")"
}

function mkobject() {
    local obj=()
    for i in $(seq 1 2 $(( $# - 1 ))) ; do
	local iplus1=$((i + 1))
	objs+=('"'"${!i}"'": '"${!iplus1}")
    done
    local IFS=","
    echo "{${objs[*]}}"
}

function mkarray() {
    local IFS=","
    echo "[$*]"
}

function vmtTargetExists() {
  local displayName="$ADDR-$MANPATH"
  echo "Looking for a preexisting target with the name '$displayName'"
  local url="http://$TURBOADDR/vmturbo/rest/targets"
  local res=$(curl -s -k -H 'Accept: application/json' -b $cookies "$url" | jq -r ".[] | select(.displayName==\"$displayName\").displayName")
  if [ "$res" = "$displayName" ]; then
    echo "Found"
    return 1
  else
    echo "Not Found"
    return 0
  fi
}

# Check for host and authorized keys
if [ ! -e "/sshkeys/hostkey" ] || [ ! -e "/sshkeys/turboauthorizedkey" ]; then
    echo "ERROR: Could not find 'hostkey' or 'turboauthorizedkey' in /sshkeys. Please make sure to generate these and mount the secret into the pod."
    exit 1
fi

# Move host and authorized keys to location & set perms
cp /sshkeys/hostkey* /etc/ssh/keys/
chown root:root /etc/ssh/keys/hostkey
chmod 0600 /etc/ssh/keys/hostkey

cp /sshkeys/turboauthorizedkey.pub /etc/authorized_keys/turbo
chown root:root /etc/authorized_keys
chmod 755 /etc/authorized_keys
chown turbo:turbo /etc/authorized_keys/turbo
# test for writability before attempting chmod
for f in $(find /etc/authorized_keys/ -type f -maxdepth 1); do
    [ -w "${f}" ] && chmod 644 "${f}"
done

# Check if a manifest file exists, or not
if [ ! -e "/actionscripts/manifest.json" ]; then
  cat <<EOF > /actionscripts/manifest.json
{
 "scripts": [
 	{
 		"name": "replace_resize_vm",
 		"description": "REPLACES Turbonomic resize orchestration. Echos the environment to stdout and takes no action.",
 		"scriptPath": "./replace_resize_vm.sh",
 		"entityType": "VIRTUAL_MACHINE",
 		"actionType": "RIGHT_SIZE",
		"actionPhase": "REPLACE"
 	}
  ]
}
EOF

  cat <<EOF > /actionscripts/replace_resize_vm.sh
echo "Replace actionscript executed with the following environment.\n" >> /proc/1/fd/1
env | grep VMT >> /proc/1/fd/1
EOF
else
  # Future state, launch a daemon to watch for creation/change of Kubernetes
  # custom resources which define action scripts.
  echo "Future Custom Resource Mode.."
fi

echo "Running $@"
if [ "$(basename $1)" == "$DAEMON" ]; then
    trap stop SIGINT SIGTERM
    $@ &
    pid="$!"
    mkdir -p /var/run/$DAEMON && echo "${pid}" > /var/run/$DAEMON/$DAEMON.pid
    sleep 1m
    vmtLogin
    vmtTargetExists
    if [ $? -eq 0 ]; then
      echo "Creating orchestration target."
      vmtCreateTarget
    else
      echo "This orchestration pod has already been added as a target."
    fi
    vmtLogout
    wait "${pid}"
    exit $?
else
    exec "$@"
fi