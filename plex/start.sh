#!/bin/bash -eux
GROUP=plextmp

mkdir -p /config/logs/supervisor
chown -R plex: /config

touch /supervisord.log
touch /supervisord.pid
chown plex: /supervisord.log /supervisord.pid

TARGET_GID=$(stat -c "%g" /data)
EXISTS=$(cat /etc/group | grep ${TARGET_GID} | wc -l)

# Create new group using target GID and add plex user
if [ $EXISTS = "0" ]; then
  groupadd --gid ${TARGET_GID} ${GROUP}
else
  # GID exists, find group name and add
  GROUP=$(getent group $TARGET_GID | cut -d: -f1)
  usermod -a -G ${GROUP} plex
fi
usermod -a -G ${GROUP} plex

# Will change all files in directory to be readable by group
if [ "${CHANGE_DIR_RIGHTS}" = true ]; then
  chgrp -R ${GROUP} /data
  chmod -R g+rX /data
fi

# Current defaults to run as root while testing.
if [ "${RUN_AS_ROOT}" = true ]; then
  /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
else
  su plex -c "/usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf"
fi
