Place val.key and val.pass into ./harmony/keyfiles

```
docker-compose up -d
```
Check if Bootstrap is working.
```
docker logs -f pokt_dokt_harmony-mainnet_1
```
Logs are at:
```
harmony/log
```

HARMONY QUERY
```
curl --location --request POST 'https://$DOMAIN/' --header 'Content-Type: application/json' --data-raw '{"jsonrpc": "2.0", "method": "hmy_latestHeader", "params": [], "id": 1}'
```

[HMY CLI Flags](https://docs.harmony.one/home/network/validators/node-setup/installing-updating/installing-node/using-binary#option-2-setup-using-flag-parsing)