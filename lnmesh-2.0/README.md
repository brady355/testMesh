# LNMesh 2.0

A 3-node testbed where Bitcoin Core and Core Lightning run over a wireless
ad-hoc mesh. One Raspberry Pi has Ethernet/internet access; the other two reach
the chain through it via Bitcoin's built-in P2P relay. The final topology is the
same as the original manual guide: `pi1 <-> pi2 <-> pi3` on regtest, with
Lightning channels ready before you send a payment.

This repo is a follow-up to the [LNMesh paper](https://ieeexplore.ieee.org/document/10195433)
(IEEE WoWMoM 2023). For the original 8-Pi `batman-adv` setup, see the
[original repo](https://github.com/ahmet-kurt/LNMesh).

## What You Need

- 3 Raspberry Pis, named `pi1`, `pi2`, and `pi3`.
- Raspberry Pi OS 64-bit on each Pi.
- The same username and password on every Pi. This guide uses `akurt`.
- SSH enabled with password authentication.
- All Pis initially connected to the same normal Wi-Fi network.
- Ethernet plugged into `pi1`.
- This repo cloned on `pi1`, with commands run from `lnmesh-2.0`.

Pi 4 or Pi 5 with 8 GB RAM and 64 GB SD cards are recommended. Pi 5 builds Core
Lightning much faster.

## Automated Setup

Image the SD cards with Raspberry Pi Imager. In **Edit Settings**, set:

- Hostnames: `pi1`, `pi2`, `pi3`
- Username/password: the same on all three Pis
- Wi-Fi: your normal network
- Services: enable SSH with password authentication

Boot all three Pis. Leave `pi2` and `pi3` on normal Wi-Fi for discovery, and
plug Ethernet into `pi1`.

On `pi1`, clone this repo and run the gateway setup script:

```bash
git clone https://github.com/brady355/testMesh.git
cd testMesh/lnmesh-2.0
chmod +x gateway-setup.sh pay-demo.sh
./gateway-setup.sh --user akurt
```

The script prompts once for the shared Pi password unless you pass it explicitly:

```bash
LNMESH_NODE_PASSWORD='password' ./gateway-setup.sh --user akurt
./gateway-setup.sh --user akurt --node-password password
```

If LAN discovery cannot find `pi2` or `pi3`, pass their current Wi-Fi IPs:

```bash
./gateway-setup.sh --user akurt --node pi2=192.168.1.23 --node pi3=192.168.1.24
```

If `pi1`'s Ethernet interface is not `eth0`, name the uplink explicitly:

```bash
LNMESH_UPLINK_IFACE=end0 ./gateway-setup.sh --user akurt
```

For command construction checks without touching the Pis:

```bash
./gateway-setup.sh --user akurt --node pi2=192.168.1.23 --node pi3=192.168.1.24 --dry-run
```

Command reference:

```bash
./gateway-setup.sh [--user akurt] [--node-password PASSWORD] [--node pi2=HOST --node pi3=HOST] [--dry-run]
./pay-demo.sh [--amount-msat 1000000] [--verbose]
```

### What The Script Does

`gateway-setup.sh` automates the long manual setup:

- Discovers `pi2` and `pi3` on the normal Wi-Fi network.
- Installs a gateway SSH key and passwordless sudo on the node Pis.
- Moves all three Pis into IBSS/ad-hoc Wi-Fi mesh mode.
- Assigns mesh IPs:
  - `pi1`: `10.0.0.1/24`
  - `pi2`: `10.0.0.2/24`
  - `pi3`: `10.0.0.3/24`
- Configures the temporary NAT bridge through `pi1`.
- Installs Bitcoin Core 31.0 on all Pis.
- Builds Core Lightning v26.04.1 on `pi1` and copies the binaries to `pi2` and
  `pi3`.
- Writes Bitcoin and Lightning configs.
- Starts `bitcoind` and `lightningd`.
- Creates or loads the regtest `miner` wallet on `pi1`.
- Mines maturity blocks, funds CLN wallets, and opens the `pi1 <-> pi2` and
  `pi2 <-> pi3` channels.
- Verifies the channels are ready before exiting.

When setup finishes, the network should already be at the pre-payment state.

## Simple Payment

Run the default demo payment from `pi1`:

```bash
./pay-demo.sh
```

By default, this creates an invoice on `pi3` and pays it from `pi1` over the
`pi1 -> pi2 -> pi3` route. The script prints a concise receipt with the payer,
receiver, amount, status, payment hash, and preimage.

Use a different amount:

```bash
./pay-demo.sh --amount-msat 1000000
```

Show the raw `lightning-cli` JSON as well:

```bash
./pay-demo.sh --verbose
```

You can also set the default amount with an environment variable:

```bash
LNMESH_PAYMENT_MSAT=1000000 ./pay-demo.sh
```

## Manual Fallback

The automated path above is the normal workflow. Use this section only when you
need to debug or reproduce a setup step by hand.

### Mesh

`mesh-up.sh` puts `wlan0` into IBSS mode with SSID `lnmesh` on frequency `2412`.

```bash
sudo bash mesh-up.sh 10.0.0.1/24
sudo systemd-run --no-block --unit=mesh bash /home/akurt/lnmesh/mesh-up.sh 10.0.0.2/24
sudo systemd-run --no-block --unit=mesh bash /home/akurt/lnmesh/mesh-up.sh 10.0.0.3/24
```

`systemd-run --no-block` matters on `pi2` and `pi3` because moving `wlan0` from
normal Wi-Fi to IBSS kills the current SSH session.

After the mesh is up, `pi2` and `pi3` should be reachable from `pi1`:

```bash
ssh akurt@10.0.0.2
ssh akurt@10.0.0.3
```

### Internet Bridge

On `pi1`, enable forwarding and NAT:

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo nft add table ip nat
sudo nft "add chain ip nat postrouting { type nat hook postrouting priority 100; }"
sudo nft add rule ip nat postrouting oifname eth0 masquerade
```

On `pi2` and `pi3`, route through `pi1`:

```bash
sudo ip route add default via 10.0.0.1
sudo rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

To cut `pi2` and `pi3` off from the internet for offline scenarios:

```bash
sudo nft delete table ip nat
```

### Bitcoin Core 31.0

Run on each Pi if Bitcoin Core is missing:

```bash
cd /tmp
wget -q https://bitcoincore.org/bin/bitcoin-core-31.0/bitcoin-31.0-aarch64-linux-gnu.tar.gz
sudo tar -xzf bitcoin-31.0-aarch64-linux-gnu.tar.gz -C /opt/
sudo ln -sf /opt/bitcoin-31.0/bin/bitcoind /usr/local/bin/
sudo ln -sf /opt/bitcoin-31.0/bin/bitcoin-cli /usr/local/bin/
```

Copy the matching config to each Pi:

```bash
mkdir -p ~/.bitcoin
cp bitcoin.conf.pi1 ~/.bitcoin/bitcoin.conf
```

Use `bitcoin.conf.pi2` on `pi2` and `bitcoin.conf.pi3` on `pi3`.

### Core Lightning v26.04.1

Build on `pi1`:

```bash
sudo apt-get update
sudo apt-get install -y jq autoconf automake build-essential git libtool \
  libsqlite3-dev libffi-dev python3 python3-pip python3-venv net-tools \
  zlib1g-dev libsodium-dev libssl-dev gettext lowdown cargo rustfmt protobuf-compiler

curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH=$HOME/.local/bin:$PATH

git clone --branch v26.04.1 https://github.com/ElementsProject/lightning.git ~/cln
cd ~/cln
git submodule update --init --recursive
uv sync --all-extras --all-groups --frozen
source .venv/bin/activate
./configure
make -j$(nproc)
sudo make install
sudo strip /usr/local/bin/lightning* /usr/local/libexec/c-lightning/lightning_* /usr/local/libexec/c-lightning/plugins/*
```

On `pi2` and `pi3`, install runtime dependencies:

```bash
sudo apt-get install -y libsodium23 jq
```

Then tar the CLN binaries on `pi1`, copy them to `pi2` and `pi3`, and extract
them under `/`:

```bash
sudo tar -cf /tmp/cln.tar -C / \
  usr/local/bin/lightning-cli \
  usr/local/bin/lightningd \
  usr/local/bin/lightning-hsmtool \
  usr/local/libexec/c-lightning
sudo chmod a+r /tmp/cln.tar
scp /tmp/cln.tar akurt@10.0.0.2:/tmp/
scp /tmp/cln.tar akurt@10.0.0.3:/tmp/
ssh akurt@10.0.0.2 'cd / && sudo tar -xf /tmp/cln.tar'
ssh akurt@10.0.0.3 'cd / && sudo tar -xf /tmp/cln.tar'
```

Copy the shared Lightning config to all three Pis:

```bash
mkdir -p ~/.lightning
cp lightningd-config ~/.lightning/config
```

### Start And Verify

On each Pi:

```bash
bitcoind -daemon
bitcoin-cli -regtest -rpcwait getblockchaininfo
lightningd --daemon --network=regtest
sleep 8
lightning-cli --regtest getinfo | jq "{id, alias, blockheight}"
```

After channels are opened, verify they are normal:

```bash
lightning-cli --regtest listpeerchannels | jq ".channels[] | {state, short_channel_id}"
```

## Offline Scenarios

After automated setup, the easiest test is:

```bash
./pay-demo.sh
```

For manual offline payment testing, first remove the NAT bridge on `pi1`:

```bash
sudo nft delete table ip nat
```

Then create an invoice on `pi3` and pay it from `pi1`:

```bash
INV=$(ssh akurt@10.0.0.3 'lightning-cli --regtest invoice amount_msat=1000000 label=A description=offline | jq -r .bolt11')
lightning-cli --regtest pay "$INV"
```

Expected result: `status: complete`.

## Gotchas

- Discovery requires `pi2` and `pi3` to still be on normal Wi-Fi before
  `gateway-setup.sh` starts.
- Hostnames are expected to be exactly `pi1`, `pi2`, and `pi3`.
- The automation is fixed to the 3-Pi regtest topology.
- Reboot persistence is not installed. If a Pi reboots, rerun setup/start steps.
- Tx propagation over IBSS is 5-10 seconds, not instant. Mine after propagation,
  or the miner block may be empty.
- Bitcoind restart unloads wallets. Run `bitcoin-cli -regtest loadwallet miner`
  after restarts, or add `wallet=miner` to `bitcoin.conf`.
- The built-in Pi Wi-Fi driver supports IBSS, but not 802.11s mesh point mode.
  For real 802.11s mesh, use a compatible USB Wi-Fi adapter.
- Pass `--regtest` to `lightning-cli`. The CLI chooses the RPC socket based on
  the network flag.

## File Reference

| File | What it is |
|---|---|
| `gateway-setup.sh` | Gateway automation entrypoint |
| `pay-demo.sh` | One-command demo payment helper |
| `mesh-up.sh` | IBSS setup script; run on each Pi with its mesh IP |
| `bitcoin.conf.pi{1,2,3}` | Per-Pi bitcoind config for full-mesh regtest peering |
| `lightningd-config` | Shared lightningd config for regtest on `0.0.0.0:9735` |
