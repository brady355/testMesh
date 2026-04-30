# OfflineMesh Setup Instructions

This folder is the working OfflineMesh bundle. The mesh layer follows the original BATMAN setup: `wlan0` joins an IBSS/ad-hoc network, `batman-adv` creates `bat0`, the gateway serves DHCP/DNS on `bat0`, and nodes use the gateway for chain access.

Windows is only a test funding helper. The gateway drives setup. The final deployment is Raspberry Pis plus gateway/backhaul hardware.

## Hostnames And Roles

Pi hostnames do not choose the mesh role. Role selection is explicit:

```bash
sudo bash setup_pi.sh gateway
sudo bash setup_pi.sh node
```

The Linux hostname is the mesh/cluster identity. Each Pi must have a unique `hostname -s`, but the nodes do not need to be named `node01` or `node02`. The gateway records discovered Pis by their real Linux hostnames and stops setup with a duplicate-hostname error if two Pis report the same name.

The expected Linux user is:

```text
meshlink
```

The current clean-install password is:

```text
1111
```

## What The Pis Need First

During testing, Ethernet is allowed so each Pi can clone this repo quickly. That is only for setup speed. The final verification step disables or unplugs node Ethernet.

Clone the same repo on every Pi. From the cloned repo folder, run one command based on what that Pi should be:

```bash
sudo bash setup_pi.sh gateway
```

```bash
sudo bash setup_pi.sh node
```

`setup_pi.sh` copies the clone into `/opt/offlinemesh`, then configures only the BATMAN mesh layer. It does not build CLN, Bitcoin Core, or the watchtower. Run it once on the gateway Pi and once on every node Pi.

Use `--profile` if you want a non-default mesh profile:

```bash
sudo bash setup_pi.sh gateway --profile mesh-a
sudo bash setup_pi.sh node --profile mesh-a
```

After the mesh is up, assume the node Pis have only mesh and SSH. They do not need CLN, Bitcoin Core, TEOS, or old wallet state before gateway setup. The gateway copies and installs everything else over `bat0`.

The node mesh setup adds a default route through the gateway with a high metric. That lets a bare node use package/download access through the gateway during setup while still allowing Ethernet to be used during test preparation when it is plugged in.

This Git repo intentionally does not include downloaded source archives or toolchain tarballs. A clean install downloads/clones those inputs when needed. For a fully offline field install, seed `/opt/offlinemesh/sources/` after cloning with the optional cache files listed in `TROUBLESHOOTING.md`.

## 1. Check The Mesh

Check the mesh:

```bash
ip -4 addr show bat0
systemctl status batman-adv.service
```

On the gateway, also check DHCP/DNS:

```bash
systemctl status dnsmasq.service
cat /var/lib/misc/dnsmasq.leases
```

## 2. Let The Gateway Take Over

After every Pi has joined the mesh, run one command on the gateway:

```bash
sudo bash /opt/offlinemesh/setup_gateway.sh
```

That command installs the gateway stack, discovers mesh neighbors by Linux hostname, installs newly discovered node Pis, and verifies the result. During verification, each Pi waits for Core Lightning to catch up to Bitcoin Core and prints live progress like:

```text
[wait-sync] gateway01: CLN 60174/133010 blocks | 45.2% | lag 72836 | Still loading latest blocks from bitcoind.
```

On a first clean install this can take a while. Leave it running while the CLN block number climbs; verification continues once CLN is within a couple of blocks of Bitcoin Core and the sync warning clears. To intentionally reinstall nodes already seen by the gateway:

```bash
sudo bash /opt/offlinemesh/setup_gateway.sh --force
```

If your node SSH user or password is not the default, use:

```bash
sudo OFFLINEMESH_NODE_PASSWORD='your-password' bash /opt/offlinemesh/setup_gateway.sh --user meshlink
```

The gateway installs/runs:

```text
Bitcoin Core testnet4
Core Lightning
source cache
TEOS watchtower
```

If `/usr/local/bin/bitcoind` is missing on the gateway, the stack installer uses a bundled archive from `sources/` if present, otherwise it downloads the official Bitcoin Core `31.0` Linux archive for the Pi architecture.

The nodes install/run:

```text
Core Lightning
watchtower client plugin
```

Nodes do not run local `bitcoind`. Their CLN instances use gateway Bitcoin RPC over `bat0`.

## 3. Fund A Node From Windows During Testing

Funding is normal Bitcoin wallet funding. A node creates a CLN receive address, and the Windows Bitcoin Core wallet sends to that address.

On the gateway, ask the node for a receive address and save a request file. Use the hostname shown in gateway setup output, or run discovery to list the available names:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py discover
NODE_NAME=your-node-hostname
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py funding-request "$NODE_NAME" --amount-sat 150000 | tee /opt/offlinemesh/funding-request.json
```

Move `/opt/offlinemesh/funding-request.json` to the Windows machine, next to this repo folder.

On Windows, the helper script uses `config/funding_wallet.json`, starts Bitcoin Core if needed, loads `offlinemesh_funder` if needed, checks the balance, and broadcasts the send:

```powershell
cd C:\Users\bmlan\Desktop\OfflineMesh\Final
.\scripts\windows_fund_nodes.ps1 -RequestFile .\funding-request.json
```

Use `-DryRun` first if you want to verify the request without broadcasting:

```powershell
.\scripts\windows_fund_nodes.ps1 -RequestFile .\funding-request.json -DryRun
```

If you prefer to send manually from Windows, first make sure Bitcoin Core is running:

```powershell
Start-Process -FilePath "C:\Users\bmlan\AppData\Local\Programs\BitcoinCore\31.0\bin\bitcoind.exe" `
  -ArgumentList "-testnet4","-datadir=C:\Users\bmlan\AppData\Roaming\Bitcoin" `
  -WindowStyle Hidden
```

Then check RPC and wallet state:

```powershell
& "C:\Users\bmlan\AppData\Local\Programs\BitcoinCore\31.0\bin\bitcoin-cli.exe" -testnet4 -datadir="C:\Users\bmlan\AppData\Roaming\Bitcoin" getblockchaininfo
& "C:\Users\bmlan\AppData\Local\Programs\BitcoinCore\31.0\bin\bitcoin-cli.exe" -testnet4 -datadir="C:\Users\bmlan\AppData\Roaming\Bitcoin" loadwallet offlinemesh_funder
& "C:\Users\bmlan\AppData\Local\Programs\BitcoinCore\31.0\bin\bitcoin-cli.exe" -testnet4 -datadir="C:\Users\bmlan\AppData\Roaming\Bitcoin" -rpcwallet=offlinemesh_funder getbalances
```

If `loadwallet` says the wallet is already loaded, continue.

Send to the address printed by the gateway:

```powershell
& "C:\Users\bmlan\AppData\Local\Programs\BitcoinCore\31.0\bin\bitcoin-cli.exe" `
  -testnet4 `
  -datadir="C:\Users\bmlan\AppData\Roaming\Bitcoin" `
  -rpcwallet=offlinemesh_funder `
  sendtoaddress NODE_ADDRESS_HERE 0.00150000
```

After Windows broadcasts the funding transaction, wait from the gateway:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py wait-funds "$NODE_NAME" --timeout 7200
```

The Windows wallet used for tests is configured in:

```text
config/funding_wallet.json
```

Funds must return to that wallet before nodes are stripped or reset.

## 4. Run The Channel Demo

With one node funded, the actual channel activity runs on the nodes. Use the hostnames shown by `discover` or setup output:

```bash
FUNDED_NODE=your-funded-node-hostname
PEER_NODE=your-peer-node-hostname
```

On the funded node, open a channel to the peer:

```bash
OPEN_JSON="$(python3 /opt/offlinemesh/scripts/open_channel_offline.py --peer "$PEER_NODE" --amount-sat 50000 --wait-state normal)"
CHANNEL_ID="$(printf '%s\n' "$OPEN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["channel_id"])')"
```

On the peer node, create an invoice:

```bash
INVOICE_JSON="$(python3 /opt/offlinemesh/scripts/pay_mesh.py invoice --amount-msat 1000 --description "OfflineMesh test")"
BOLT11="$(printf '%s\n' "$INVOICE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bolt11"])')"
```

On the funded node, pay the invoice:

```bash
python3 /opt/offlinemesh/scripts/pay_mesh.py pay --peer "$PEER_NODE" --bolt11 "$BOLT11"
```

On the funded node, close the channel:

```bash
python3 /opt/offlinemesh/scripts/close_channel_offline.py --peer "$PEER_NODE" --channel-id "$CHANNEL_ID" --mode auto --timeout 300
```

The gateway can run those same node-side commands remotely as a convenience:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py demo --source "$FUNDED_NODE" --target "$PEER_NODE" --channel-amount-sat 50000 --invoice-msat 1000
```

## 5. Return Funds Before Reset

Always do this before resetting or reinstalling nodes:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py return-funds
```

The node reset script blocks if it sees channels or sweepable funds:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py reset-nodes
```

That reset preserves the BATMAN mesh by default so the gateway can reinstall over `bat0`. To intentionally remove mesh configuration too, run the node reset script directly with `--strip-mesh`.

Run a complete reinstall pass:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py reinstall-pass
```

Repeat the install/demo/return/reset flow at least three times before trusting a field build.

## 6. Mesh-Only Verification

After setup and funding, unplug or disable Ethernet on the nodes. Leave the gateway backhaul connected if needed.

Set `FUNDED_NODE` and `PEER_NODE` to the discovered hostnames as in the demo section, then run:

```bash
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py verify
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py discover
sudo python3 /opt/offlinemesh/scripts/gateway_orchestrator.py demo --source "$FUNDED_NODE" --target "$PEER_NODE"
```

The `verify` command also shows live `[wait-sync]` progress for the gateway and each node if CLN is still scanning blocks. A node does not run its own `bitcoind`; its CLN sync progress is measured against the gateway Bitcoin RPC over `bat0`.

Successful mesh-only verification means:

```text
gateway can discover node Pis over bat0 by hostname
node CLN uses gateway Bitcoin RPC
nodes are registered to the gateway watchtower
the funded node can open a channel to the peer node
the funded node can pay the peer node
the channel can close
funds can be returned before reset
```

## 7. Switch Mesh Profiles

List profiles:

```bash
python3 /opt/offlinemesh/scripts/mesh_profile.py list
```

Switch a running Pi to another full profile:

```bash
sudo python3 /opt/offlinemesh/scripts/mesh_profile.py set mesh-b --system --restart
```

The profile switch changes ESSID, channel/frequency, subnet, gateway IP, DHCP range, and service environment together. Use this to run two separate meshes in the same area.

Run the same profile switch on every Pi that should join that mesh.

## 8. Troubleshooting

Use:

```bash
/opt/offlinemesh/TROUBLESHOOTING.md
```

The most important rule is simple: do not strip or reset a Pi with open channels or spendable funds still on it. Close channels first, return funds second, reset last.
