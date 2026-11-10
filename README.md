# Pause and resume RIF on Chain with the RoC Safe

This guide prepares **one five-call Safe transaction** to pause RoC on Rootstock
Mainnet, and a second five-call transaction to resume it. Use the **proxy
addresses**, not implementation or changer addresses.

| Contract | Proxy address | Effect of its own `pause()` |
| --- | --- | --- |
| Multi-collateral guard | `0x0237Ad1f0831b479a344E56646BC48B0885cF46F` | Stops queue execution, combined operations, and guard-controlled rebalancing and liquidation. |
| RIF operation queue | `0x47f5014115d3bb29B20b5168Ee75050D6f8c3Bf1` | Rejects new RIF operations being enqueued. Its `execute()` does **not** check the queue's paused flag. |
| DOC operation queue | `0x2BBCBC2CD2F2655d5A4306637c46Bcf2E6D859f6` | Rejects new DOC operations being enqueued. Its `execute()` does **not** check the queue's paused flag. |
| RIF collateral bucket | `0xA27024Ed70035E46dba712609fc2Afa1c97aA36A` | Rejects new RIF-bucket user operations and pauses other protected bucket actions. |
| DOC collateral bucket | `0x697535055Aa7AfD2C280523C7B062b1F05284661` | Rejects new DOC-bucket user operations and pauses other protected bucket actions. |

All five have independent `paused` state. The guard and the two buckets are the
essential stops: pausing only the guard still allows users to enqueue operations
and lock funds; pausing only the buckets leaves the guard able to process
already-queued operations. The two queue pauses explicitly block enqueueing as
an additional layer, although the paused buckets already prevent normal users
from reaching the queues. A paused queue alone does **not** stop its execution.
The [RoC changer](https://github.com/money-on-chain/roc-sc-protocol-v2/blob/main/contracts/changers/pauserSplitRifProMigrationChanger/PauserSplitRifProMigrationChanger.sol)
delegated the `pauser` role to the same Safe on all five contracts. The
[guard](https://github.com/money-on-chain/main-sc-protocol-v2/blob/main/contracts/multiCollateral/MocMultiCollateralGuard.sol),
[buckets](https://github.com/money-on-chain/main-sc-protocol-v2/blob/main/contracts/core/MocOperations.sol),
and [queues](https://github.com/money-on-chain/main-sc-protocol-v2/blob/main/contracts/queue/MocQueue.sol)
show what each pause controls.

**Network:** Rootstock Mainnet, chain ID `30`.
**Safe:** `0x817aC952d616c1e2Fa5c6D6DD20b3D15f10dDb03`.
At the fork block used for this guide (`9400049`), the Safe was version `1.4.1`,
had nine owners, and required four approvals. Check the owners and threshold in
Safe again before proposing a live transaction.

## ABI and Safe transaction settings

The minimal ABI for a pause call is:

```json
[{"type":"function","name":"pause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]
```

The minimal ABI for a resume call is:

```json
[{"type":"function","name":"unpause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]
```

Both are also in [`abi/Pausable.json`](abi/Pausable.json). Each inner call has
`value = 0` and `operation = CALL`. `pause()` takes no arguments and has calldata
`0x8456cb59`; `unpause()` takes no arguments and has calldata `0x3f4ba83a`.
Safe's batch transaction uses an **outer** `DELEGATECALL` to its deployed
`MultiSendCallOnly` library; do not set any of the five contract calls to
`DELEGATECALL`. The [Safe deployment record](https://github.com/safe-global/safe-deployments/blob/main/src/assets/v1.4.1/multi_send_call_only.json)
maps Rootstock chain `30` to `0x9641d764fc13c8B624c04430C7356C1C7C8102e2`.
The test exercises exactly this Safe batch path.

## Create the pause transaction in Safe

1. Open `https://safe.rootstock.io/`, select **Rootstock Mainnet** and the Safe
   `0x817aC952d616c1e2Fa5c6D6DD20b3D15f10dDb03`. Start **one batch** of
   contract calls. Check that the five contracts currently return
   `paused() = false` and `pauser() = 0x817aC952d616c1e2Fa5c6D6DD20b3D15f10dDb03`.

2. Add the guard call first. **To:** `0x0237Ad1f0831b479a344E56646BC48B0885cF46F` · **ABI:** `[{"type":"function","name":"pause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]` · **Method:** `pause()` · **Value:** `0` · **Operation:** `CALL`.

3. Add the RIF queue. **To:** `0x47f5014115d3bb29B20b5168Ee75050D6f8c3Bf1` · **ABI:** `[{"type":"function","name":"pause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]` · **Method:** `pause()` · **Value:** `0` · **Operation:** `CALL`.

4. Add the DOC queue. **To:** `0x2BBCBC2CD2F2655d5A4306637c46Bcf2E6D859f6` · **ABI:** `[{"type":"function","name":"pause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]` · **Method:** `pause()` · **Value:** `0` · **Operation:** `CALL`.

5. Add the RIF bucket. **To:** `0xA27024Ed70035E46dba712609fc2Afa1c97aA36A` · **ABI:** `[{"type":"function","name":"pause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]` · **Method:** `pause()` · **Value:** `0` · **Operation:** `CALL`.

6. Add the DOC bucket. **To:** `0x697535055Aa7AfD2C280523C7B062b1F05284661` · **ABI:** `[{"type":"function","name":"pause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]` · **Method:** `pause()` · **Value:** `0` · **Operation:** `CALL`.

7. Review the batch: five `CALL`s in the order above, no native-token value,
   and no call to the governance changer or legacy Stopper. Submit it for the
   Safe's required approvals. After execution, read `paused()` on all five
   proxy addresses; each must be `true`.

The batch is atomic: if one inner call fails, none of the five pauses persists.
Before execution, check for pending queue operations. Pausing the guard freezes
their processing; their funds stay pending. The pause does not automatically
cancel or refund them.

## Create the resume transaction in Safe

The same Safe can call `unpause()` directly. A governance transaction is **not**
needed for these five contracts: their `Stoppable.unpause()` accepts the current
`pauser`. Resume the buckets and queues **before** the guard. This lets the guard
process existing queued operations only after the buckets can execute them.

1. In the same Rootstock Mainnet Safe
   `0x817aC952d616c1e2Fa5c6D6DD20b3D15f10dDb03`, start a new five-call
   batch. Confirm each target returns `paused() = true`.

2. Add the RIF bucket. **To:** `0xA27024Ed70035E46dba712609fc2Afa1c97aA36A` · **ABI:** `[{"type":"function","name":"unpause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]` · **Method:** `unpause()` · **Value:** `0` · **Operation:** `CALL`.

3. Add the DOC bucket. **To:** `0x697535055Aa7AfD2C280523C7B062b1F05284661` · **ABI:** `[{"type":"function","name":"unpause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]` · **Method:** `unpause()` · **Value:** `0` · **Operation:** `CALL`.

4. Add the RIF queue. **To:** `0x47f5014115d3bb29B20b5168Ee75050D6f8c3Bf1` · **ABI:** `[{"type":"function","name":"unpause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]` · **Method:** `unpause()` · **Value:** `0` · **Operation:** `CALL`.

5. Add the DOC queue. **To:** `0x2BBCBC2CD2F2655d5A4306637c46Bcf2E6D859f6` · **ABI:** `[{"type":"function","name":"unpause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]` · **Method:** `unpause()` · **Value:** `0` · **Operation:** `CALL`.

6. Add the guard last. **To:** `0x0237Ad1f0831b479a344E56646BC48B0885cF46F` · **ABI:** `[{"type":"function","name":"unpause","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]` · **Method:** `unpause()` · **Value:** `0` · **Operation:** `CALL`.

7. Review the five calls, collect the required approvals, and execute the Safe
   transaction. Confirm `paused() = false` on each target. Pending operations
   can then resume normal processing; they are not automatically canceled.

## References

- [RoC deployed proxy addresses](https://github.com/money-on-chain/address-book/blob/main/address-book.json)
- [RoC pauser-split changer](https://github.com/money-on-chain/roc-sc-protocol-v2/blob/main/contracts/changers/pauserSplitRifProMigrationChanger/PauserSplitRifProMigrationChanger.sol)
- [Protocol pause authorization and state](https://github.com/money-on-chain/main-sc-protocol-v2/blob/main/contracts/governance/Stoppable.sol)
- [Safe transaction execution](https://docs.safe.global/reference-smart-account/transactions/execTransaction)
- [Safe pre-approved hash signatures](https://docs.safe.global/reference-smart-account/signatures/approveHash)
- [Rootstock public mainnet RPC](https://dev.rootstock.io/dev-tools/wallets/metamask/)

## Appendix: run the mainnet fork test

The test in [`test/RoCPauserFork.t.sol`](test/RoCPauserFork.t.sol) uses only
Foundry's `forge` and `anvil`, Solidity interfaces declared in the test, the
deployed Safe and its deployed `MultiSendCallOnly`. It has no npm, Solidity
library, or `forge-std` dependency. Tested with **Foundry v1.9.0** against
Rootstock Mainnet block `9400049` on the public RPC
`https://public-node.rsk.co`. Use an up-to-date stable Foundry installation.

In terminal 1, start a local fork:

```bash
cd /work/moc/pauser-howto
anvil --fork-url https://public-node.rsk.co --chain-id 30 --port 18545
```

In terminal 2, run the test against that local fork:

```bash
cd /work/moc/pauser-howto
forge test --fork-url http://127.0.0.1:18545 -vv
```

The test discovers current Safe owners, verifies the four-owner threshold,
impersonates three owners to prove that they cannot execute the batch, then
impersonates a fourth owner and executes a **real Safe `execTransaction`** on
the fork. It asserts that all five targets are paused. Four other current
owners then approve and execute the reverse batch, and it asserts that all five
are unpaused. It also checks the guard-to-bucket and bucket-to-queue addresses
and that the Safe remains the configured pauser. No private keys are needed and
no transaction is sent to mainnet.

To reproduce the exact checked block rather than the latest mainnet state, add
`--fork-block-number 9400049` to the `anvil` command. If the Safe's owners,
threshold, or protocol addresses change later, the latest-state test is
designed to fail until this guide is reviewed.
