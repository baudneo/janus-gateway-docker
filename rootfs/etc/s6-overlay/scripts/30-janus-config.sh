#!/command/with-contenv bash
# shellcheck shell=bash

. "/usr/local/bin/logger"
program_name="janus-config"

JANUS_REST_HTTP=${JANUS_REST_HTTP:-8088}
JANUS_REST_HTTPS=${JANUS_REST_HTTPS:-8089}
JANUS_ADMIN_HTTP=${JANUS_ADMIN_HTTP:-7088}
JANUS_ADMIN_HTTPS=${JANUS_ADMIN_HTTPS:-7889}
own=1

if [ ! -f "/janus/config/janus.jcfg" ]; then
    echo "Copying default Janus config files to /janus/config" | init "[${program_name}] "
    cp -r /opt/janus/etc/janus/*.jcfg /janus/config
    rm -f /janus/config/*.jcfg.sample
    cp /opt/janus/janus.jcfg /janus/config
    own=0
fi

if [ $own -eq 0 ]; then
    echo "Setting '/janus' permissions for user janus" | init "[${program_name}] "
    chown -R janus:janus /janus
    chmod -R 775 /janus
fi

# sed -i port numbers out of demo for CF Argo support / to change default hardcoded demo ports
sed -i s"|:8088/janus|:${JANUS_REST_HTTP}/janus|" /opt/janus/share/janus/demos/*.js
sed -i s"|:8089/janus|:${JANUS_REST_HTTPS}/janus|" /opt/janus/share/janus/demos/*.js
sed -i s"|:.*/admin|:${JANUS_ADMIN_HTTP}/admin|" /opt/janus/share/janus/demos/admin.js
sed -i s"|:.*/admin|:${JANUS_ADMIN_HTTPS}/admin|" /opt/janus/share/janus/demos/admin.js
# Do configs
sed -i s"|port =.*/s|port = ${JANUS_REST_HTTP}|" /janus/config/janus.transport.http.jcfg
sed -i s"|secureport =.*/s|secureport = ${JANUS_REST_HTTPS}|" /janus/config/janus.transport.http.jcfg
sed -i s"|admin_port =.*/s|admin_port = ${JANUS_ADMIN_HTTP}|" /janus/config/janus.transport.http.jcfg
sed -i s"|admin_secure_port =.*/s|secureport = ${JANUS_ADMIN_HTTPS}|" /janus/config/janus.transport.http.jcfg

#sed -i s"|configs_folder =.*/s|configs_folder = /janus/config|" /janus/config/janus.jcfg
#sed -i s"|plugins_folder =.*/s|plugins_folder = /opt/janus/lib/janus/plugins|" /janus/config/janus.jcfg
#sed -i s"|transports_folder =.*/s|transports_folder = /opt/janus/lib/janus/transports|" /janus/config/janus.jcfg
#sed -i s"|events_folder =.*/s|events_folder = /opt/janus/lib/janus/events|" /janus/config/janus.jcfg
#sed -i s"|loggers_folder =.*/s|loggers_folder = /opt/janus/lib/janus/loggers|" /janus/config/janus.jcfg
