param(
  [Parameter(Mandatory=$true)]
  [string]$RequestFile,

  [int]$DefaultAmountSat = 150000,

  [string]$ResponseFile = "",

  [int]$StartupTimeoutSec = 90,

  [switch]$NoAutoStart,

  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$fundingConfigPath = Join-Path $root "config\funding_wallet.json"
if (-not (Test-Path -LiteralPath $fundingConfigPath)) {
  throw "Missing funding wallet config: $fundingConfigPath"
}
if (-not (Test-Path -LiteralPath $RequestFile)) {
  throw "Missing funding request file: $RequestFile"
}

$fundingConfig = Get-Content -Raw -LiteralPath $fundingConfigPath | ConvertFrom-Json
$request = Get-Content -Raw -LiteralPath $RequestFile | ConvertFrom-Json

$bitcoinCli = $fundingConfig.main_machine.bitcoin_cli
$datadir = $fundingConfig.main_machine.datadir
$wallet = $fundingConfig.wallet_name
$network = $fundingConfig.network

if (-not (Test-Path -LiteralPath $bitcoinCli)) {
  throw "bitcoin-cli not found: $bitcoinCli"
}

function Invoke-BitcoinCli {
  param(
    [string[]]$CliArgs,
    [switch]$NoWallet
  )
  $base = @("-$network", "-datadir=$datadir", "-rpcwallet=$wallet")
  if ($NoWallet) {
    $base = @("-$network", "-datadir=$datadir")
  }
  $output = & $bitcoinCli @base @CliArgs
  if ($LASTEXITCODE -ne 0) {
    throw "bitcoin-cli failed: $($CliArgs -join ' ')"
  }
  return ($output -join "`n")
}

function Test-BitcoinRpc {
  $base = @("-$network", "-datadir=$datadir")
  $output = & $bitcoinCli @base getblockchaininfo 2>&1
  return ($LASTEXITCODE -eq 0)
}

function Start-BitcoinIfNeeded {
  if (Test-BitcoinRpc) {
    return
  }
  if ($NoAutoStart) {
    throw "Bitcoin Core RPC is not reachable. Start bitcoind with -$network and retry."
  }
  $bitcoind = Join-Path (Split-Path -Parent $bitcoinCli) "bitcoind.exe"
  if (-not (Test-Path -LiteralPath $bitcoind)) {
    throw "bitcoind not found next to bitcoin-cli: $bitcoind"
  }
  Start-Process -FilePath $bitcoind -ArgumentList @("-$network", "-datadir=$datadir") -WindowStyle Hidden
  $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-BitcoinRpc) {
      return
    }
  }
  throw "Bitcoin Core RPC did not become reachable within $StartupTimeoutSec seconds."
}

function Ensure-WalletLoaded {
  $walletsRaw = Invoke-BitcoinCli -CliArgs @("listwallets") -NoWallet
  $loaded = @($walletsRaw | ConvertFrom-Json)
  if ($loaded -contains $wallet) {
    return
  }
  Invoke-BitcoinCli -CliArgs @("loadwallet", $wallet) -NoWallet | Out-Null
}

Start-BitcoinIfNeeded
Ensure-WalletLoaded

$balanceRaw = Invoke-BitcoinCli @("getbalances")
$balance = $balanceRaw | ConvertFrom-Json
$trusted = [decimal]$balance.mine.trusted
$pending = [decimal]$balance.mine.untrusted_pending

$results = @()
foreach ($item in @($request.requests)) {
  $node = [string]$item.node
  $address = [string]$item.address
  if ([string]::IsNullOrWhiteSpace($address)) {
    throw "Funding request for $node has no address"
  }
  $amountSat = $DefaultAmountSat
  if ($item.PSObject.Properties.Name -contains "amount_sat" -and $item.amount_sat) {
    $amountSat = [int]$item.amount_sat
  }
  $amountBtc = "{0:N8}" -f ([decimal]$amountSat / 100000000)

  if ($DryRun) {
    $txid = ""
  } else {
    $txid = Invoke-BitcoinCli @(
      "-named",
      "sendtoaddress",
      "address=$address",
      "amount=$amountBtc",
      "comment=OfflineMesh $node test funding",
      "subtractfeefromamount=false",
      "replaceable=true",
      "estimate_mode=economical"
    )
    $txid = $txid.Trim()
  }

  $results += [pscustomobject]@{
    node = $node
    address = $address
    amount_sat = $amountSat
    amount_btc = $amountBtc
    txid = $txid
    dry_run = [bool]$DryRun
  }
}

$response = [pscustomobject]@{
  request_file = (Resolve-Path -LiteralPath $RequestFile).Path
  wallet = $wallet
  network = $network
  trusted_btc_before = "$trusted"
  pending_btc_before = "$pending"
  results = $results
  created_at = (Get-Date).ToUniversalTime().ToString("o")
}

if ([string]::IsNullOrWhiteSpace($ResponseFile)) {
  $requestPath = Resolve-Path -LiteralPath $RequestFile
  $ResponseFile = [System.IO.Path]::ChangeExtension($requestPath.Path, ".funded.json")
}

$response | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResponseFile -Encoding UTF8
$response | ConvertTo-Json -Depth 8
