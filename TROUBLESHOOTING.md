# OfflineMesh Troubleshooting

Use this after the main instructions if setup, discovery, watchtower registration, funding, or the channel demo stalls.

## First Rules

Do not delete wallet data to fix setup.

Preserve these unless you are intentionally wiping a Pi after funds are safe:

```text
/home/meshlink/.lightning
/home/meshlink/.bitcoin
/var/lib/offlinemesh/watchtower
```

Before reset, return funds:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py return-funds
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py reset-nodes
```

`reset_preserve_wallet.sh` blocks when it sees channels or sweepable funds.

## Fast Status

On any Pi:

```bash
hostname -s
ip -4 addr show bat0
ip route
systemctl --no-pager -l status batman-adv lightningd
sudo bash /opt/offlinemesh/scripts/verify_cycle.sh
```

On the gateway:

```bash
systemctl --no-pager -l status dnsmasq bitcoind lnmesh-source-cache lnmesh-watchtower lnmesh-watchtower-info
journalctl -u batman-adv -u dnsmasq -u bitcoind -u lightningd -u lnmesh-watchtower --no-pager -n 160
python3 /opt/offlinemesh/scripts/gateway_orchestrator.py discover
```

On a node:

```bash
systemctl --no-pager -l status mesh-dhcp lnmesh-watchtower-register
journalctl -u batman-adv -u mesh-dhcp -u lightningd -u lnmesh-watchtower-register --no-pager -n 160
```

## Mesh Does Not Start

Symptoms:

```text
batman-adv.service fails
wlan0 remains Not-Associated
bat0 does not exist
node never receives a bat0 address
```

Checks:

```bash
systemctl --no-pager -l status batman-adv.service
journalctl -u batman-adv.service --no-pager -n 160
ip link show wlan0
iwconfig wlan0
batctl n || true
batctl o || true
```

Repair:

```bash
sudo bash /opt/offlinemesh/setup_pi.sh node --profile mesh-a
sudo systemctl restart batman-adv.service
```

Use `sudo bash /opt/offlinemesh/setup_pi.sh gateway --profile mesh-a` on whichever Pi should be the gateway.

The mesh script follows the original BATMAN setup: `wlan0` in IBSS/ad-hoc mode, `batman-adv`, `bat0` MTU `1450`, gateway mode on the gateway, client mode on nodes, DHCP on node `bat0`.

## Gateway Cannot Discover Nodes

Run on the gateway Pi:

```bash
cat /var/lib/misc/dnsmasq.leases 2>/dev/null || true
ip neigh show dev bat0
batctl o || true
python3 /opt/offlinemesh/scripts/gateway_orchestrator.py discover
```

Discovery uses each Pi's real Linux hostname as its cluster name. If a Pi does not appear, confirm it ran the node mesh script, has a unique `hostname -s`, has a `bat0` lease, and accepts SSH for the configured gateway user:

```bash
hostname -s
sudo bash /opt/offlinemesh/setup_pi.sh node --profile mesh-a
```

If `discover` or setup reports duplicate hostnames, rename one of the Pis and rerun discovery. The gateway will not invent names like `node01` or `node02`.

If SSH fails, confirm the gateway orchestrator user can log in. The default is `meshlink` with password `1111`; override with `--user` and `OFFLINEMESH_NODE_PASSWORD`, or install an SSH key.

## Stack Install Fails

Run the gateway takeover script again:

```bash
sudo bash /opt/offlinemesh/setup_gateway.sh --force
```

Optional source cache inputs:

```text
/opt/offlinemesh/sources/lightning-v25.12.1.tar.gz      optional, avoids CLN git clone
/opt/offlinemesh/sources/rust-teos.tar.gz               optional, avoids rust-teos git clone
/opt/offlinemesh/sources/protoc-27.3-linux-aarch_64.zip optional, avoids protoc download
/opt/offlinemesh/sources/rust-1.81.0-aarch64-unknown-linux-gnu.tar.xz optional, avoids rustup download
```

These cache files are not committed to Git because they are large. During testing, Ethernet can be used for GitHub clones and apt. For final node behavior, the nodes should use only the gateway after mesh setup.

## Node Cannot Use Gateway Bitcoin RPC

On the gateway:

```bash
systemctl --no-pager -l status bitcoind
bitcoin-cli -testnet4 -datadir=/home/meshlink/.bitcoin getblockchaininfo
cat /etc/offlinemesh/bitcoin-rpc-password >/dev/null && echo rpc-secret-ok
```

On the node:

```bash
grep '^bitcoin-rpc' /home/meshlink/.lightning/config
python3 /opt/offlinemesh/scripts/lnmesh_common.py local-info
lightning-cli --lightning-dir=/home/meshlink/.lightning --network=testnet4 getinfo
```

If the node has the wrong gateway IP or mesh profile, switch every Pi to the same profile:

```bash
sudo python3 /opt/offlinemesh/scripts/mesh_profile.py set mesh-a --system --restart
```

## Watchtower Problems

On the gateway:

```bash
sudo bash /opt/offlinemesh/scripts/watchtower_setup.sh status
cat /var/lib/offlinemesh/src-cache/watchtower.json
```

On the node:

```bash
sudo bash /opt/offlinemesh/scripts/watchtower_setup.sh status
lightning-cli --lightning-dir=/home/meshlink/.lightning --network=testnet4 plugin list
```

If registration failed:

```bash
sudo systemctl restart lnmesh-watchtower-register.service
journalctl -u lnmesh-watchtower-register --no-pager -n 120
```

## Funding Problems

Ask the node for a fresh CLN receive address:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py discover
NODE_NAME=your-node-hostname
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py funding-request "$NODE_NAME" --amount-sat 150000
```

Fund that address from the Windows `offlinemesh_funder` wallet. The gateway command also writes `/var/lib/offlinemesh/funding-request.json`; if you put that JSON file next to this `Final` folder, the helper can make the normal wallet send for you:

```powershell
.\scripts\windows_fund_nodes.ps1 -RequestFile .\funding-request.json
```

The Windows helper starts local Bitcoin Core when RPC is down and loads `offlinemesh_funder` when needed. If you see `EOF reached` from `bitcoin-cli`, rerun the helper or start `bitcoind.exe -testnet4` manually and retry.

Wait from the gateway:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py wait-funds "$NODE_NAME" --timeout 7200
```

Do not fund the same node repeatedly unless you mean to. The request file records the address and amount.

Reset preserves the mesh by default. If a Pi must be stripped all the way back past BATMAN mesh setup, run the node reset script directly with `--strip-mesh` after funds are confirmed back in the Windows wallet.

## Channel Demo Problems

Check both nodes:

```bash
lightning-cli --lightning-dir=/home/meshlink/.lightning --network=testnet4 listfunds
lightning-cli --lightning-dir=/home/meshlink/.lightning --network=testnet4 listpeers
lightning-cli --lightning-dir=/home/meshlink/.lightning --network=testnet4 listpeerchannels
```

Then rerun:

```bash
FUNDED_NODE=your-funded-node-hostname
PEER_NODE=your-peer-node-hostname
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py demo --source "$FUNDED_NODE" --target "$PEER_NODE"
```

If a channel exists, close it before reset:

```bash
python3 /opt/offlinemesh/scripts/close_channel_offline.py --peer "$PEER_NODE" --mode auto
```

## Reset Problems

If reset refuses to run, that is usually correct. It means a node still has channels or sweepable funds.

Return funds first:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py return-funds
```

Only skip the fund check when you intentionally preserve wallets and know the funds are safe:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py reset-nodes --skip-fund-return-check
```
