#!/bin/sh

if [ ! -f /home/app/.pocket/data/setupdone ]
then
  mkdir -o 1005 -g 1001 -p /home/app/.pocket/data
  echo "wget -q -O - '$POCKET_SNAPSHOT' | tar -xzv -C /home/app/.pocket/data/"
  wget -q -O - $POCKET_SNAPSHOT | tar -xzv -C /home/app/.pocket/data/
  touch /home/app/.pocket/data/setupdone
fi

