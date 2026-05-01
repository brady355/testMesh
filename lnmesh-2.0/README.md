# LNMesh 2.0

A 3-node testbed where Bitcoin Core + Core Lightning run over a wireless ad-hoc mesh. One Pi has internet; the other two reach the chain transparently through it via Bitcoin's built-in P2P relay. Open / close channels and route LN payments work even when the offline Pis have no idea which Pi is the online one.

This repo is a follow-up to the [LNMesh paper](https://ieeexplore.ieee.org/document/10195433) (IEEE WoWMoM 2023). For the original 8-Pi `batman-adv` setup see the [original repo](https://github.com/ahmet-kurt/LNMesh).

## What you need

- **3× Raspberry Pi** — Pi 4 or Pi 5, 8 GB RAM, 64 GB SD card each. Pi 5 makes the CLN build much faster.
- **1× Ethernet cable** for the gateway Pi.
- A POSIX-shell terminal — Linux/macOS/WSL, or **Git Bash on Windows** ([Git for Windows](https://git-scm.com/download/win)). PowerShell won't work for many of the bash idioms below.

## 1. Image the SD cards

Use Raspberry Pi Imager → **Raspberry Pi OS (64-bit)**. In **Edit Settings**:
- Hostname: `pi1`, `pi2`, `pi3` (one per card)
- Username + password: same on every Pi (this guide uses `akurt`). You'll need the password once, for `ssh-copy-id`.
- Wi-Fi: your home network
- **Services tab:** check "Enable SSH" with password authentication (no need to paste your public key here)

Boot all three Pis. Find each one's IP — easiest way is plugging in a monitor + keyboard and running `ip a`. Note them down — we'll refer to them as `<PI1_WIFI>`, `<PI2_WIFI>`, `<PI3_WIFI>` throughout this doc. (One Pi will get an Ethernet IP later we'll call `<PI1_ETH>`.)

## 2. Push your SSH key to each Pi

```bash
# Skip if you already have ~/.ssh/id_ed25519 or id_rsa on your laptop:
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

ssh-copy-id akurt@<PI1_WIFI>
ssh-copy-id akurt@<PI2_WIFI>
ssh-copy-id akurt@<PI3_WIFI>
```

Type the Pi's password (the one from the imager) when prompted. After this, SSH works without a password.

## 3. Passwordless sudo (one-time, per Pi)

```bash
ssh -t akurt@<PI1_WIFI> "echo 'akurt ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/akurt && sudo chmod 440 /etc/sudoers.d/akurt"
ssh -t akurt@<PI2_WIFI> "echo 'akurt ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/akurt && sudo chmod 440 /etc/sudoers.d/akurt"
ssh -t akurt@<PI3_WIFI> "echo 'akurt ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/akurt && sudo chmod 440 /etc/sudoers.d/akurt"
```

Type the Pi's password for each (`-t` allocates a TTY so `sudo` can prompt).

## 4. Wireless mesh (IBSS)

Pi's built-in Broadcom Wi-Fi doesn't support 802.11s mesh point, but it does support IBSS (ad-hoc). `mesh-up.sh` sets `wlan0` to IBSS mode with a fixed SSID + channel + IP.

**Plug Ethernet into pi1.** Find its new eth0 IP (run `ip a` on pi1 again, or check the router) — we'll call it `<PI1_ETH>` from here on.

Push the script to each Pi:
```bash
ssh akurt@<PI1_ETH>  'mkdir -p ~/lnmesh' && scp mesh-up.sh akurt@<PI1_ETH>:~/lnmesh/
ssh akurt@<PI2_WIFI> 'mkdir -p ~/lnmesh' && scp mesh-up.sh akurt@<PI2_WIFI>:~/lnmesh/
ssh akurt@<PI3_WIFI> 'mkdir -p ~/lnmesh' && scp mesh-up.sh akurt@<PI3_WIFI>:~/lnmesh/
```

Run it — pi1 first (Ethernet keeps SSH alive), then pi2 / pi3:
```bash
ssh akurt@<PI1_ETH>  'sudo bash ~/lnmesh/mesh-up.sh 10.0.0.1/24'
ssh akurt@<PI2_WIFI> 'sudo systemd-run --no-block --unit=mesh bash /home/akurt/lnmesh/mesh-up.sh 10.0.0.2/24'
ssh akurt@<PI3_WIFI> 'sudo systemd-run --no-block --unit=mesh bash /home/akurt/lnmesh/mesh-up.sh 10.0.0.3/24'
```

`systemd-run --no-block` is needed for pi2/pi3 because the script swaps wlan0 from your home Wi-Fi to IBSS mid-run, which kills the SSH session. Detaching the script lets it finish in the background.

After this, pi2/pi3 are reachable via pi1 as a jump host:
```bash
ssh -J akurt@<PI1_ETH> akurt@10.0.0.2
```

## 5. Internet bridge through pi1

So pi2/pi3 can reach the apt repos and bitcoincore.org for installs:

```bash
# On pi1:
ssh akurt@<PI1_ETH> 'sudo sysctl -w net.ipv4.ip_forward=1 && \
  sudo nft add table ip nat && \
  sudo nft "add chain ip nat postrouting { type nat hook postrouting priority 100; }" && \
  sudo nft add rule ip nat postrouting oifname eth0 masquerade'

# On pi2 and pi3:
for IP in 10.0.0.2 10.0.0.3; do
  ssh -J akurt@<PI1_ETH> akurt@$IP 'sudo ip route add default via 10.0.0.1 && \
    sudo rm -f /etc/resolv.conf && \
    echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf'
done
```

Tear down later with `sudo nft delete table ip nat` on pi1 (used during the offline scenarios below).

## 6. Bitcoin Core 31.0

Same one-liner on every Pi:

```bash
cd /tmp && \
  wget -q https://bitcoincore.org/bin/bitcoin-core-31.0/bitcoin-31.0-aarch64-linux-gnu.tar.gz && \
  sudo tar -xzf bitcoin-31.0-aarch64-linux-gnu.tar.gz -C /opt/ && \
  sudo ln -sf /opt/bitcoin-31.0/bin/bitcoind /usr/local/bin/ && \
  sudo ln -sf /opt/bitcoin-31.0/bin/bitcoin-cli /usr/local/bin/
```

## 7. Core Lightning v26.04.1

CLN doesn't ship aarch64 binaries — we build on pi1 (Pi 5 ≈ 20 min) and copy the result to the others.

### On pi1 — build

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

### On pi2 and pi3 — runtime deps only

```bash
sudo apt-get install -y libsodium23 jq
```

### Distribute the binaries (from pi1)

Generate an SSH key on pi1 and authorize it on pi2/pi3:
```bash
ssh akurt@<PI1_ETH> 'ssh-keygen -t ed25519 -N "" -f ~/.ssh/mesh_key -q'
PUB=$(ssh akurt@<PI1_ETH> 'cat ~/.ssh/mesh_key.pub')
for IP in 10.0.0.2 10.0.0.3; do
  ssh -J akurt@<PI1_ETH> akurt@$IP "echo '$PUB' >> ~/.ssh/authorized_keys"
done
```

Tar + scp + untar:
```bash
ssh akurt@<PI1_ETH> '
  sudo tar -cf /tmp/cln.tar -C / \
    usr/local/bin/lightning-cli \
    usr/local/bin/lightningd \
    usr/local/bin/lightning-hsmtool \
    usr/local/libexec/c-lightning && \
  sudo chmod a+r /tmp/cln.tar && \
  scp -o StrictHostKeyChecking=accept-new -i ~/.ssh/mesh_key /tmp/cln.tar akurt@10.0.0.2:/tmp/ && \
  scp -o StrictHostKeyChecking=accept-new -i ~/.ssh/mesh_key /tmp/cln.tar akurt@10.0.0.3:/tmp/'

for IP in 10.0.0.2 10.0.0.3; do
  ssh -J akurt@<PI1_ETH> akurt@$IP 'cd / && sudo tar -xf /tmp/cln.tar'
done
```

## 8. Configs

```bash
# Bitcoin (full-mesh peering — different per Pi)
scp bitcoin.conf.pi1 akurt@<PI1_ETH>:.bitcoin/bitcoin.conf
scp -J akurt@<PI1_ETH> bitcoin.conf.pi2 akurt@10.0.0.2:.bitcoin/bitcoin.conf
scp -J akurt@<PI1_ETH> bitcoin.conf.pi3 akurt@10.0.0.3:.bitcoin/bitcoin.conf

# Lightning (same on all)
ssh akurt@<PI1_ETH> 'mkdir -p ~/.lightning'
ssh -J akurt@<PI1_ETH> akurt@10.0.0.2 'mkdir -p ~/.lightning'
ssh -J akurt@<PI1_ETH> akurt@10.0.0.3 'mkdir -p ~/.lightning'
scp lightningd-config akurt@<PI1_ETH>:.lightning/config
scp -J akurt@<PI1_ETH> lightningd-config akurt@10.0.0.2:.lightning/config
scp -J akurt@<PI1_ETH> lightningd-config akurt@10.0.0.3:.lightning/config
```

## 9. Start the stack on each Pi

```bash
# pi1 (Ethernet)
ssh akurt@<PI1_ETH> 'bitcoind -daemon && bitcoin-cli -regtest -rpcwait getblockchaininfo > /dev/null && lightningd --daemon --network=regtest && sleep 8 && lightning-cli --regtest getinfo | jq "{id, alias, blockheight}"'

# pi2 (over the mesh, jumping through pi1)
ssh -J akurt@<PI1_ETH> akurt@10.0.0.2 'bitcoind -daemon && bitcoin-cli -regtest -rpcwait getblockchaininfo > /dev/null && lightningd --daemon --network=regtest && sleep 8 && lightning-cli --regtest getinfo | jq "{id, alias, blockheight}"'

# pi3
ssh -J akurt@<PI1_ETH> akurt@10.0.0.3 'bitcoind -daemon && bitcoin-cli -regtest -rpcwait getblockchaininfo > /dev/null && lightningd --daemon --network=regtest && sleep 8 && lightning-cli --regtest getinfo | jq "{id, alias, blockheight}"'
```

Each command should print that Pi's node ID and `blockheight: 0`.

---

# Test scenarios

These all run from your laptop. We use the regtest network — pi1 is the miner, which simulates "the node with internet to the public Bitcoin network".

## Setup — mine + open channels

```bash
PI1_ETH=192.168.1.152  # YOUR pi1 ethernet IP

# On pi1: create wallet, mine maturity, fund pi1+pi2 LN wallets
ssh akurt@$PI1_ETH 'bitcoin-cli -regtest createwallet miner'
PI1_ADDR=$(ssh akurt@$PI1_ETH 'lightning-cli --regtest newaddr | jq -r .bech32')
PI2_ADDR=$(ssh -J akurt@$PI1_ETH akurt@10.0.0.2 'lightning-cli --regtest newaddr | jq -r .bech32')
ssh akurt@$PI1_ETH "
  bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 101 \$(bitcoin-cli -regtest -rpcwallet=miner getnewaddress) > /dev/null
  bitcoin-cli -regtest -rpcwallet=miner sendtoaddress $PI1_ADDR 0.5
  bitcoin-cli -regtest -rpcwallet=miner sendtoaddress $PI2_ADDR 0.5
  bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 1 \$(bitcoin-cli -regtest -rpcwallet=miner getnewaddress) > /dev/null"

# Get LN ids
PI2_ID=$(ssh -J akurt@$PI1_ETH akurt@10.0.0.2 'lightning-cli --regtest getinfo | jq -r .id')
PI3_ID=$(ssh -J akurt@$PI1_ETH akurt@10.0.0.3 'lightning-cli --regtest getinfo | jq -r .id')

# Connect peers and open channels: pi1 <-> pi2 <-> pi3
ssh akurt@$PI1_ETH                       "lightning-cli --regtest connect $PI2_ID@10.0.0.2:9735"
ssh -J akurt@$PI1_ETH akurt@10.0.0.2     "lightning-cli --regtest connect $PI3_ID@10.0.0.3:9735"
ssh akurt@$PI1_ETH                       "lightning-cli --regtest fundchannel id=$PI2_ID amount=5000000 mindepth=1"
ssh -J akurt@$PI1_ETH akurt@10.0.0.2     "lightning-cli --regtest fundchannel id=$PI3_ID amount=5000000 mindepth=1"

sleep 6   # let funding txs propagate over the mesh
ssh akurt@$PI1_ETH 'bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 6 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress) > /dev/null'
sleep 6   # let lightningd lock in
```

Verify channels are `CHANNELD_NORMAL` on every Pi:
```bash
for H in "akurt@$PI1_ETH" "-J akurt@$PI1_ETH akurt@10.0.0.2" "-J akurt@$PI1_ETH akurt@10.0.0.3"; do
  ssh $H 'lightning-cli --regtest listpeerchannels | jq ".channels[] | {state, short_channel_id}"'
done
```

## Take pi2/pi3 offline

```bash
ssh akurt@$PI1_ETH 'sudo nft delete table ip nat'   # cuts pi2/pi3 from the internet
```

Verify: `ssh -J akurt@$PI1_ETH akurt@10.0.0.2 'ping -c 1 -W 2 1.1.1.1'` should fail.

## Scenario A — multi-hop LN payment, fully offline

```bash
INV=$(ssh -J akurt@$PI1_ETH akurt@10.0.0.3 'lightning-cli --regtest invoice amount_msat=1000000 label=A description=offline | jq -r .bolt11')
ssh akurt@$PI1_ETH "lightning-cli --regtest pay $INV"
```
Expected: `status: complete` in ~1 s.

## Scenario B — close + reopen pi2↔pi3 channel while offline

The closing/funding tx for pi2↔pi3 has to be confirmed on chain. With pi2/pi3 offline, the tx hops over the mesh through pi1's bitcoind, which (in regtest) mines it. Neither pi2 nor pi3 has to know that pi1 is the one with chain access — Bitcoin's P2P relay handles it.

```bash
# Close
ssh -J akurt@$PI1_ETH akurt@10.0.0.2 "lightning-cli --regtest close $PI3_ID"
sleep 6
ssh akurt@$PI1_ETH 'bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 1 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress) > /dev/null'

# Reopen
ssh -J akurt@$PI1_ETH akurt@10.0.0.2 "lightning-cli --regtest connect $PI3_ID@10.0.0.3:9735"
ssh -J akurt@$PI1_ETH akurt@10.0.0.2 "lightning-cli --regtest fundchannel id=$PI3_ID amount=5000000 mindepth=1"
sleep 6
ssh akurt@$PI1_ETH 'bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 6 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress) > /dev/null'
sleep 6
```

## Scenario C — late joiner (offline) opens a new channel

Imagine pi3 is a customer who has no channel with pi1 yet, has no internet, and doesn't know which Pi has internet. They just `fundchannel` with pi1; the funding tx propagates via mesh to whoever can mine it.

```bash
PI3_ADDR=$(ssh -J akurt@$PI1_ETH akurt@10.0.0.3 'lightning-cli --regtest newaddr | jq -r .bech32')
ssh akurt@$PI1_ETH "
  bitcoin-cli -regtest -rpcwallet=miner sendtoaddress $PI3_ADDR 0.5
  bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 1 \$(bitcoin-cli -regtest -rpcwallet=miner getnewaddress) > /dev/null"
sleep 4

PI1_ID=$(ssh akurt@$PI1_ETH 'lightning-cli --regtest getinfo | jq -r .id')
ssh -J akurt@$PI1_ETH akurt@10.0.0.3 "lightning-cli --regtest connect $PI1_ID@10.0.0.1:9735"
ssh -J akurt@$PI1_ETH akurt@10.0.0.3 "lightning-cli --regtest fundchannel id=$PI1_ID amount=5000000 mindepth=1"
sleep 6
ssh akurt@$PI1_ETH 'bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 6 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress) > /dev/null'
sleep 6
```

## Scenario D — divergent block heights converge

Simulates one community member losing internet earlier than the others. Their bitcoind sees fewer blocks; once back on the mesh, it catches up via P2P.

```bash
# Isolate pi2's bitcoind from the network
ssh -J akurt@$PI1_ETH akurt@10.0.0.2 'bitcoin-cli -regtest setnetworkactive false'

# Mine 5 blocks on pi1 — pi3 stays in sync (still peered), pi2 falls behind
ssh akurt@$PI1_ETH 'bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 5 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress) > /dev/null'

# Reconnect pi2 + force immediate dial (bitcoind otherwise backs off)
ssh -J akurt@$PI1_ETH akurt@10.0.0.2 'bitcoin-cli -regtest setnetworkactive true && \
  bitcoin-cli -regtest addnode 10.0.0.1 onetry && \
  bitcoin-cli -regtest addnode 10.0.0.3 onetry'
sleep 5

# All three should now be at the same height
for H in "akurt@$PI1_ETH" "-J akurt@$PI1_ETH akurt@10.0.0.2" "-J akurt@$PI1_ETH akurt@10.0.0.3"; do
  ssh $H 'bitcoin-cli -regtest getblockcount'
done
```

## Restore the bridge

```bash
ssh akurt@$PI1_ETH 'sudo nft add table ip nat && \
  sudo nft "add chain ip nat postrouting { type nat hook postrouting priority 100; }" && \
  sudo nft add rule ip nat postrouting oifname eth0 masquerade'
```

---

# Gotchas

- **Tx propagation over IBSS is 5–10 s, not instant.** Always `sleep ~6` after `fundchannel` / `close` before mining, or the miner block will be empty and you'll need to mine again. On testnet/mainnet this is invisible (real block intervals are minutes).
- **Bitcoind restart unloads wallets.** Run `bitcoin-cli -regtest loadwallet miner` after restarts, or add `wallet=miner` to `bitcoin.conf` for auto-load.
- **Pi's built-in Wi-Fi (brcmfmac) doesn't support 802.11s.** That's why we use IBSS via `mesh-up.sh`. For real 802.11s mesh you'd need a USB Wi-Fi adapter with an Atheros (`ath9k_htc`) or Ralink (`rt2800usb`) chipset.
- **`mesh-up.sh` doesn't enable on boot.** If you reboot a Pi, run the script again. (Adding a systemd unit is left as an exercise.)
- **Pass `--regtest` to `lightning-cli` every time.** The CLI looks for the RPC socket based on the `--network` flag.

# File reference

| File | What it is |
|---|---|
| `mesh-up.sh` | IBSS setup script — run on each Pi with its mesh IP |
| `bitcoin.conf.pi{1,2,3}` | Per-Pi bitcoind config (full-mesh peering) |
| `lightningd-config` | Shared lightningd config (regtest, listens on `0.0.0.0:9735`) |
