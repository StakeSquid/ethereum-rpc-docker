pokt_mainnet.sh 
#!/bin/sh
if [ ! -f /home/app/.pocket/setupdone ]
then
  mkdir -p /home/app/.pocket/data
  echo "wget -q -O - '$POCKET_SNAPSHOT' | tar -xv -C /home/app/.pocket/data/"
  wget -q -O - $POCKET_SNAPSHOT | tar -xv -C /home/app/.pocket/data/
  touch /home/app/.pocket/setupdone
fi
