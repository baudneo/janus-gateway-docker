#!/command/with-contenv bash
# shellcheck shell=bash
. "/usr/local/bin/logger"
program_name="reconfigure-user"

PUID=${PUID:-911}
PGID=${PGID:-911}

if [ "${PUID}" -ne 911 ] || [ "${PGID}" -ne 911 ]; then
  echo "Reconfiguring GID and UID" | info "[${program_name}] "
  groupmod -o -g "$PGID" janus
  usermod -o -u "$PUID" janus

  echo "User uid:    $(id -u janus)" | info "[${program_name}] "
  echo "User gid:    $(id -g janus)" | info "[${program_name}] "

  echo "Setting '/janus' permissions for user janus" | info "[${program_name}] "
  chown -R janus:janus \
    /janus
  chmod -R 775 \
    /janus
else
  echo "Setting '/janus/config' permissions for user janus" | info "[${program_name}] "
  chown -R janus:janus \
    /janus/config
  chmod -R 775 \
    /janus/config
fi

echo "Setting '/log' permissions for user nobody" | info "[${program_name}] "
chown -R nobody:nogroup \
  /log
chmod -R 775 \
  /log
