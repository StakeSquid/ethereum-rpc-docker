#!/bin/sh

if [ ! -f /home/app/.pocket/data/setupdone ]
then
  mkdir -p /home/app/.pocket/data
  echo "wget -q -O - '$POCKET_SNAPSHOT' | tar xfvz -C /home/app/.pocket/data/"
  wget -q -O - $POCKET_SNAPSHOT | tar xfvz -C /home/app/.pocket/data/
  touch /home/app/.pocket/data/setupdone
fi

