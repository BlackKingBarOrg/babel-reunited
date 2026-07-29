_This post mirrors the [original security review report](https://github.com/ickb/contracts/blob/master/20260501-ICKB-Audit-Report.md) published in `ickb/contracts`: any question or feedback is more than welcomed :hugs:_

> - **Review completion date:** 2026-05-01.
> - **Reviewed contracts commit:** [`454cfa9`](https://github.com/ickb/contracts/tree/454cfa966052a621c4e8b67001718c29ee8191a2). This is the last commit that changed `scripts/contracts/**` or `scripts/Cargo.toml`.
> - **Executable test evidence:** current `scripts/tests/**` suite in this repository state.
> - **Scope:** `iCKB Logic`, `Owned Owner`, `Limit Order`, and the shared `utils` crate.
> - **Cross-references:** the [iCKB whitepaper](https://github.com/ickb/whitepaper/blob/cdbabf653ba98eacea397f94f8c894f32a538d6c/README.md) and Nervos L1 reference implementations.
> - **Prior external audit:** [Scalebit (2024-09-10)](https://scalebit.xyz/reports/20240911-ICKB-Final-Audit-Report.pdf). That audit reported three issues: two informational and one minor.

## Executive Summary

Under the current deployment assumptions, the review confirmed one live issue: the known `Limit Order` confusion attack.

- `iCKB Logic` has a provenance-blind path: receiptless DAO-shaped outputs can later be treated as deposits, and a separately funded aggregate-deposit path can realize the split-vs-aggregate soft-cap spread.
- Even so, the current `iCKB Logic` tests do not show theft, duplicated principal, or a standalone profit path beyond assets the caller already controls.
- `Limit Order` remains vulnerable to phantom-order continuation, real-order stranding through fake match-state cells, and master rebinding when cloned or otherwise indistinguishable orders are cross-wired at mint or during match.
- `Owned Owner` preserves its pairing rules under the current whole-transaction-binding lock model; the remaining weak-lock claim-reassignment cases stay at the integration boundary.
- All other candidate issues are blocked paths, generic CKB model constraints, or boundary cases relevant only to future integrations.

## Findings Summary

One known live issue remains in scope.

| ID    | Status | Component     | Finding                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ----- | ------ | ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| LO-01 | Known  | `Limit Order` | CKB [does not execute output locks at creation time](https://github.com/nervosnetwork/ckb/blob/6730f8023810d0888aa80c6a0d54cc2af918097d/script/src/types.rs#L716-L739), and [`limit_order` accepts swapped mint pairings](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/limit_order/src/entry.rs#L71-L79), so phantom and cross-wired order/master lineages can survive into later match or melt flows. |

## Protocol Model and Assumptions

The component analyses below rely on the following protocol model and deployment assumptions.

iCKB is an inflation-protected CKB token (`xUDT`) that tokenizes NervosDAO deposits into a liquid, fungible asset. The protocol owns all CKB deposits in a shared pool. Users deposit CKB and receive iCKB; later, they can burn iCKB to withdraw from any mature deposit in that pool.

Three on-chain scripts govern that flow:

1. **iCKB Logic** (dual-role): lock script on deposit cells, type script on receipt cells. Enforces the core balance equation and deposit-receipt accounting.
2. **Owned Owner**: pairs withdrawal request cells with owner cells so users can claim NervosDAO phase 2 withdrawals.
3. **Limit Order**: enables order-book-style exchange between CKB and UDTs, abstracting over NervosDAO and iCKB protocol constraints.

### Key Flows

**Deposit (two phases)**:

- Phase 1: CKB locked into NervosDAO deposit cells (lock = iCKB Logic, type = DAO). Receipts (type = iCKB Logic) track the deposits.
- Phase 2: Receipts converted to iCKB `xUDT` tokens using the deposit block's accumulated rate (AR).

**Withdrawal**:

- Phase 1: iCKB burned to release deposits from the pool into NervosDAO withdrawal requests.
- Phase 2: Standard NervosDAO withdrawal (outside iCKB scope).

**Mixed transactions**: A single transaction can combine deposit phase 1, phase 2, and withdrawal operations.

The next four execution rules explain why later findings hold or fail.

### Script Grouping

Mixed transactions execute `iCKB Logic` twice, but both runs see the same global cells and apply the same checks, so the dual execution does not create a desync path. CKB groups scripts by both hash and role. From [`script/src/types.rs:179-180`](https://github.com/nervosnetwork/ckb/blob/6730f8023810d0888aa80c6a0d54cc2af918097d/script/src/types.rs#L179-L180):

> A cell can have a lock script and an optional type script. Even they reference the same script, lock script and type script will not be grouped together.

Lock groups and type groups are stored in separate `BTreeMap`s ([`types.rs:657-659`](https://github.com/nervosnetwork/ckb/blob/6730f8023810d0888aa80c6a0d54cc2af918097d/script/src/types.rs#L657-L659)). `iCKB Logic` uses the same `{code_hash, Data1, empty_args}` for both roles, so a mixed transaction produces one lock group for deposit cells and one type group for receipt cells.

Both groups still see the same global cell set (`Source::Input` and `Source::Output`, not group-local sources) and apply the same balance checks, so duplicate execution does not create a path where one run succeeds and the other fails.

Script group construction at [`types.rs:716-740`](https://github.com/nervosnetwork/ckb/blob/6730f8023810d0888aa80c6a0d54cc2af918097d/script/src/types.rs#L716-L740): lock groups are built from input locks only; type groups are built from both input and output types.

### xUDT Owner Mode

`xUDT` owner mode stays within iCKB accounting because, in the deployed configuration, only two owner-mode routes are live and both co-execute `iCKB Logic`.

iCKB `xUDT` args are built as [`[ickb_logic_hash, XUDT_ARGS_FLAGS]`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L116-L126) with [`XUDT_ARGS_FLAGS = 0x80000000`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/constants.rs#L1-L2).

RFC 0052's [owner-mode update](https://github.com/nervosnetwork/rfcs/blob/4b502ffcb02fc7019e0dd4b5f866b5f09819cfbe/rfcs/0052-extensible-udt/0052-extensible-udt.md#owner-mode-update) has four triggers: matching `input lock`, matching `input type`, matching `output type`, and a witness `owner_script` whose hash matches the owner hash in args.

In the deployed configuration, the upstream [`xudt_rce.c` flag parsing](https://github.com/nervosnetwork/ckb-production-scripts/blob/26b0b4f15bb6eeb268b70d7ae006e244b7c06649/c/xudt_rce.c#L383-L458) enables `input lock` by default, enables `input type` when `flags & 0x80000000` is non-zero, and enables `output type` only when `flags & 0x40000000` is non-zero. It also [falls back to the witness `owner_script` path](https://github.com/nervosnetwork/ckb-production-scripts/blob/26b0b4f15bb6eeb268b70d7ae006e244b7c06649/c/xudt_rce.c#L645-L649).

The witness `owner_script` path requires an exported [`validate` symbol](https://github.com/nervosnetwork/ckb-production-scripts/blob/26b0b4f15bb6eeb268b70d7ae006e244b7c06649/c/xudt_rce.c#L36-L36) loaded via [`ckb_dlsym`](https://github.com/nervosnetwork/ckb-production-scripts/blob/26b0b4f15bb6eeb268b70d7ae006e244b7c06649/c/xudt_rce.c#L91-L113), while [`iCKB Logic`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/main.rs#L23-L35) is built as a CKB entrypoint (`program_entry` via `ckb_std::entry!`), not an xUDT `validate` extension. Under iCKB's deployed args `[ickb_logic_hash, 0x80000000]`, the live owner-mode paths are:

- A receipt (input type = iCKB Logic): needed for phase 2 minting
- A deposit (input lock = iCKB Logic): fires during withdrawal

In both cases `iCKB Logic` co-executes, as a type script for receipts or a lock script for deposits. Under this design, `xUDT` cannot enter owner mode without `iCKB Logic` also running.

### NervosDAO Interaction

The [deposit phase 1 section of the iCKB whitepaper](https://github.com/ickb/whitepaper/blob/cdbabf653ba98eacea397f94f8c894f32a538d6c/README.md#deposit-phase-1) pins `NervosDAO` to the historical [`814eb82` `dao.c`](https://github.com/nervosnetwork/ckb-system-scripts/blob/814eb82c44f560dbdad2be97eb85464062920237/c/dao.c). That version enforces the known [64-output-cell limit](https://github.com/nervosnetwork/ckb-system-scripts/blob/814eb82c44f560dbdad2be97eb85464062920237/c/dao.c#L565-L591) with an [`output_withdrawing_mask` bitset](https://github.com/nervosnetwork/ckb-system-scripts/blob/814eb82c44f560dbdad2be97eb85464062920237/c/dao.c#L445). iCKB inherits that as a platform constraint, but its own correctness does not depend on the limit.

Key NervosDAO constraints confirmed against the [whitepaper-pinned `dao.c`](https://github.com/nervosnetwork/ckb-system-scripts/blob/814eb82c44f560dbdad2be97eb85464062920237/c/dao.c):

- Withdrawal request must be at the [same output index](https://github.com/nervosnetwork/ckb-system-scripts/blob/814eb82c44f560dbdad2be97eb85464062920237/c/dao.c#L518-L523) as the consumed deposit.
- Withdrawal request capacity must [equal the deposit capacity](https://github.com/nervosnetwork/ckb-system-scripts/blob/814eb82c44f560dbdad2be97eb85464062920237/c/dao.c#L356-L365).
- Withdrawal request lock is [not checked by `validate_withdrawing_cell`](https://github.com/nervosnetwork/ckb-system-scripts/blob/814eb82c44f560dbdad2be97eb85464062920237/c/dao.c#L339-L385), but current CKB nodes still apply the [DaoScriptSizeVerifier](https://github.com/nervosnetwork/ckb/blob/6730f8023810d0888aa80c6a0d54cc2af918097d/verification/src/transaction_verifier.rs#L811-L885), so the withdrawing lock must at least match the consumed deposit lock's serialized size.
- AR is read from [`deposit_data.dao[8]`](https://github.com/nervosnetwork/ckb-system-scripts/blob/814eb82c44f560dbdad2be97eb85464062920237/c/dao.c#L282-L283), matching iCKB's [`AR_OFFSET = 160 + 8`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/utils/src/utils.rs#L51).

### Header Access

Header access explains why iCKB uses a two-phase deposit flow. From [`script/src/syscalls/load_header.rs`](https://github.com/nervosnetwork/ckb/blob/6730f8023810d0888aa80c6a0d54cc2af918097d/script/src/syscalls/load_header.rs):

- For `Source::Input`: returns the header of the block containing the cell's creation transaction. The block hash must appear in [`header_deps`](https://github.com/nervosnetwork/ckb/blob/6730f8023810d0888aa80c6a0d54cc2af918097d/script/src/syscalls/load_header.rs#L62-L66).
- For `Source::Output`: always returns `INDEX_OUT_OF_BOUND` ([`load_header.rs:80`](https://github.com/nervosnetwork/ckb/blob/6730f8023810d0888aa80c6a0d54cc2af918097d/script/src/syscalls/load_header.rs#L80)). Deposits require two phases.

Two shared boundaries matter in the later sections: authorization and accounting.

### Authorization Boundary

Several candidate issues turn on the boundary between lock-script authorization and type-script accounting. The [lock script](https://github.com/nervosnetwork/rfcs/blob/4b502ffcb02fc7019e0dd4b5f866b5f09819cfbe/rfcs/0022-transaction-structure/0022-transaction-structure.md#lock-script) / [type script](https://github.com/nervosnetwork/rfcs/blob/4b502ffcb02fc7019e0dd4b5f866b5f09819cfbe/rfcs/0022-transaction-structure/0022-transaction-structure.md#type-script) split means ownership is enforced by the user lock, while `ickb_logic` enforces value conservation. Its [balance equation](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L28-L34) and [cell classification](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L69-L81) never inspect who receives the output `iCKB` or the phase-1 DAO claim.

Under the [current whole-transaction-binding user-lock assumption](https://github.com/ickb/whitepaper/blob/cdbabf653ba98eacea397f94f8c894f32a538d6c/README.md#ancillary-scripts), that division is acceptable because the user's signature commits to the full transaction. The deployment model used for this review assumes current user-facing iCKB flows use strong transaction-binding locks and does not treat delegated or adopted `OTX` flows as in-scope present-day integrations.

The weak-lock tests in this report do not replay a current wallet path. They model future or custom delegated, `OTX`, or other non-output-binding integrations, where recipient binding is an integration invariant rather than a guarantee provided by the iCKB contracts.

Executed regressions show why that stays a boundary case rather than a current finding:

- **Weak-lock behavior:** Recipient reassignment is possible in both `iCKB Logic` and `Owned Owner`. The [phase-2 weak-lock redirect test](scripts/tests/src/tests/ickb_logic/phase2_recipient_binding.rs) and the [withdrawal weak-lock redirect test](scripts/tests/src/tests/owned_owner/weak_lock_output_rebinding.rs) demonstrate that weak-lock path.
- **Signed phase-2 minting:** Once `sighash` binds the full transaction, phase-2 redirects stop working. The [phase-2 sighash binding test](scripts/tests/src/tests/ickb_logic/phase2_recipient_binding.rs) and the [mixed phase-2 sighash binding test](scripts/tests/src/tests/ickb_logic/phase2_recipient_binding.rs) show that binding.
- **Signed withdrawals:** The same redirect pattern fails for withdrawal outputs once `sighash` binds the transaction. The [withdrawal sighash binding test](scripts/tests/src/tests/owned_owner/weak_lock_output_rebinding.rs) and the [mixed withdrawal sighash binding test](scripts/tests/src/tests/owned_owner/weak_lock_output_rebinding.rs) show the same result.
- **Witness binding:** The [input-group signing test](scripts/tests/src/tests/signing.rs) and the [full-witness signing test](scripts/tests/src/tests/signing.rs) confirm the witness-binding model used by the signed path.

The same [ancillary scripts section](https://github.com/ickb/whitepaper/blob/cdbabf653ba98eacea397f94f8c894f32a538d6c/README.md#ancillary-scripts) already warns that delegated and `OTX` ownership patterns have their own pitfalls.

### Accounting Basis and Build Setting

The main accounting claims in this report rest on three properties:

1. **Balance equation:** [`entry.rs:32`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L32) enforces `in_udt + in_receipts == out_udt + in_deposits`.
2. **Deposit-receipt accounting:** [`entry.rs:132-137`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L132-L137) requires `deposited == receipted` per amount bucket.
3. **Overflow checks:** [`overflow-checks = true`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/Cargo.toml#L6) keeps the release-build accumulators from silently wrapping.

Together, these preserve protocol accounting across deposit, conversion, withdrawal, and mixed transactions.

## Scope and Methodology

This section pins the reviewed sources and the checks behind the conclusions.

### Reference Repositories

| Repository                                                                                                                                    | Commit                                                                                                             |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| [ickb/contracts](https://github.com/ickb/contracts/tree/454cfa966052a621c4e8b67001718c29ee8191a2)                                             | [`454cfa9`](https://github.com/ickb/contracts/tree/454cfa966052a621c4e8b67001718c29ee8191a2)                       |
| [ickb/whitepaper](https://github.com/ickb/whitepaper/tree/cdbabf653ba98eacea397f94f8c894f32a538d6c)                                           | [`cdbabf6`](https://github.com/ickb/whitepaper/tree/cdbabf653ba98eacea397f94f8c894f32a538d6c)                      |
| [nervosnetwork/ckb](https://github.com/nervosnetwork/ckb/tree/6730f8023810d0888aa80c6a0d54cc2af918097d)                                       | [`6730f80`](https://github.com/nervosnetwork/ckb/tree/6730f8023810d0888aa80c6a0d54cc2af918097d)                    |
| [nervosnetwork/ckb-system-scripts](https://github.com/nervosnetwork/ckb-system-scripts/tree/814eb82c44f560dbdad2be97eb85464062920237)         | [`814eb82`](https://github.com/nervosnetwork/ckb-system-scripts/tree/814eb82c44f560dbdad2be97eb85464062920237)     |
| [nervosnetwork/ckb-production-scripts](https://github.com/nervosnetwork/ckb-production-scripts/tree/26b0b4f15bb6eeb268b70d7ae006e244b7c06649) | [`26b0b4f`](https://github.com/nervosnetwork/ckb-production-scripts/tree/26b0b4f15bb6eeb268b70d7ae006e244b7c06649) |
| [nervosnetwork/rfcs](https://github.com/nervosnetwork/rfcs/tree/4b502ffcb02fc7019e0dd4b5f866b5f09819cfbe)                                     | [`4b502ff`](https://github.com/nervosnetwork/rfcs/tree/4b502ffcb02fc7019e0dd4b5f866b5f09819cfbe)                   |

### Methodology

The review prioritized executable behavior over static plausibility and classified issues by their concrete impact.

- Reviewed the deployed release binaries and the transaction semantics they actually enforce, not just the latest source-level intent.
- Reproduced script behavior locally with `ckb-testtool`, using executable transaction tests rather than relying on inspection alone.
- Reused and extended the existing test suite, including replayed transaction shapes from observed protocol flows.
- Computed NervosDAO accounting with the exact DAO withdrawal math before classifying any claim-path discrepancy as a finding.
- Separated findings that affect the current deployment from weak-lock assumptions, operator mistakes, or broader integration-only scenarios.
- Removed or downgraded candidate issues that did not yield a harmful state transition, exploitable profit path, or realistic user loss.
- Explicitly tested mixed transactions and script-group interactions because iCKB safety depends on whole-transaction execution rather than isolated cell intent.

### Test Coverage

A [module wiring overview](scripts/tests/src/tests.rs) plus the [test layout note](scripts/tests/README.md) show three layers:

- **Test harness and utilities:** [root harness](scripts/tests/src/tests.rs), [fixtures](scripts/tests/src/tests/fixtures.rs), [encoders](scripts/tests/src/tests/encoders.rs), [signing](scripts/tests/src/tests/signing.rs), and [replay_helpers](scripts/tests/src/tests/replay_helpers.rs).
- **Scenario suite roots:** [ickb_logic](scripts/tests/src/tests/ickb_logic.rs), [owned_owner](scripts/tests/src/tests/owned_owner.rs), [limit_order](scripts/tests/src/tests/limit_order.rs), and [replay](scripts/tests/src/tests/replay.rs), each wiring topic-focused files under the matching subdirectory.
- **Helper-focused unit coverage:** [helpers](scripts/tests/src/tests/helpers.rs), which checks the shared encoders and witness/data builders used by the larger suites.

A fresh `cargo test -p tests` run passed `214` tests with no failures. Those tests cover deployment-hash sanity checks, helper encodings, core flows, blocked-path regressions, and replayed transaction shapes across `iCKB Logic`, `Owned Owner`, and `Limit Order`.

The strong-lock regressions in `ickb_logic`, `owned_owner`, and `signing` replay `secp256k1_blake160_sighash_all` as the representative whole-transaction-binding lock. This repo does not include a `QRL` fixture or harness, so conclusions for other strong-lock deployments rely on the same binding property and the stated deployment assumptions rather than a separate in-repo replay.

---

## Limit Order

The deployed [`Limit Order`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/limit_order/src/entry.rs) binary still carries one live issue: the known confusion attack. No other candidate path in this component validates as a live issue.

### Design

`Limit Order` supports three operations: `Mint` (create order plus master), `Match` (partial or full fill), and `Melt` (destroy order plus master). Orders store exchange ratios (`ckb_to_udt`, `udt_to_ckb`) and a minimum match size.

### Key Validations

**Value conservation** ([`entry.rs:103-105`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/limit_order/src/entry.rs#L103-L105)): uses [`C256`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/utils/src/c256.rs) (checked U256) to prevent overflow.

```rust
if i.ckb * ckb_mul + i.udt * udt_mul > o.ckb * ckb_mul + o.udt * udt_mul
```
---

**Concave ratio check** ([`entry.rs:233-235`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/limit_order/src/entry.rs#L233-L235)): ensures round-trip conversion doesn't lose value for the maker:

```rust
if c2u.ckb_mul * u2c.udt_mul < c2u.udt_mul * u2c.ckb_mul
```
---

**Minimum match enforcement** ([`entry.rs:108-129`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/limit_order/src/entry.rs#L108-L129)): prevents dust-level partial matches.

**Strict data length on execution** ([`entry.rs:166`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/limit_order/src/entry.rs#L166)): when `limit_order` executes, order data must be exactly `UDT_SIZE + ORDER_SIZE` bytes, so trailing data fails validation.

### Assessment

Executed tests confirm several live confusion manifestations under the current deployment assumptions, and separate tests bound the rebinding path.

| ID    | Status | Finding                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ----- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| LO-01 | Known  | CKB [does not execute output locks at creation time](https://github.com/nervosnetwork/ckb/blob/6730f8023810d0888aa80c6a0d54cc2af918097d/script/src/types.rs#L716-L739), and [`limit_order`'s mint branch](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/limit_order/src/entry.rs#L71-L79) accepts swapped mint pairings, so mint-time output creation can seed phantom or cross-wired order/master lineages that later pass match or melt validation. |

**Confirmed live manifestations:**

- Phantom orders can be created without master validation: the [phantom mint creation test](scripts/tests/src/tests/limit_order/phantom_lineage.rs).
- That phantom lineage can then enter and keep advancing through fake match state without a real master: the [phantom mint continuation test](scripts/tests/src/tests/limit_order/phantom_lineage.rs) and the [fake match lineage continuation test](scripts/tests/src/tests/limit_order/fake_match_lineage.rs).
- A fake match-shaped order can melt against a real master and strand the real order: the [real-order stranding test](scripts/tests/src/tests/limit_order/fake_match_lineage.rs).
- Cross-wired or cloned orders can rebind masters at mint or during match: the [mint crosswire test](scripts/tests/src/tests/limit_order/crosswire_mint_creation.rs) and the [cloned-order master-swap test](scripts/tests/src/tests/limit_order/crosswire_live_match.rs).
- The cloned-order continuation is reproduced with `secp256k1_blake160_sighash_all`-protected masters, so the live path is not a weak-lock-only artifact: the [cloned-order master-swap test](scripts/tests/src/tests/limit_order/crosswire_live_match.rs).

**Bounding evidence:** separate tests show that the rebinding path is narrower than arbitrary master rewriting:

- Differing mint capacities and differing match progress both block cross-wiring: the [distinct mint-capacity crosswire block test](scripts/tests/src/tests/limit_order/crosswire_blockers.rs) and the [distinct match-progress crosswire block test](scripts/tests/src/tests/limit_order/crosswire_blockers.rs).
- Even real orders fail to cross-wire arbitrarily, whether the checked info matches or differs: the [same-info real-order crosswire block test](scripts/tests/src/tests/limit_order/crosswire_blockers.rs) and the [different-info mainnet crosswire block test](scripts/tests/src/tests/limit_order/crosswire_blockers.rs).

The UDT -> CKB zero-UDT fulfilled-order shape still fails at the outer `InvalidMatch` check rather than surfacing a dedicated fulfilled-order guard.

---

## iCKB Logic

The deployed [`iCKB Logic`](https://github.com/ickb/contracts/tree/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src) binary is provenance-blind at cell classification, but once a cell is inside the scripted flow it still preserves receipt and `xUDT` accounting. The subsections below explain both properties and why the currently executed provenance-blind paths still stop short of a confirmed theft or profit finding.

### Core Invariant

[`entry.rs:32`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L32):

```rust
if in_udt_ickb + in_receipts_ickb != out_udt_ickb + in_deposits_ickb {
    return Err(Error::AmountMismatch);
}
```

---

- **Deposit phase 1**: `0 + 0 == 0 + 0` (deposits and receipts handled by accounting check only)
- **Deposit phase 2**: `0 + receipt_value == out_udt + 0`
- **Withdrawal**: `in_udt + 0 == out_udt + deposit_value`
- **Mixed**: any combination

### Cell Classification

[`celltype.rs:60-82`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L60-L82) classifies every cell in the transaction by examining lock and type script hashes, plus the DAO data shape when the DAO hash is present:

| Lock                               | Type                       | Classification         | Line                                                                                                                                    |
| ---------------------------------- | -------------------------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| iCKB Logic                         | DAO deposit (8 zero bytes) | `Deposit`              | [L69](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L69) |
| iCKB Logic                         | anything else              | `ScriptMisuse` (error) | [L72](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L72) |
| other                              | iCKB Logic                 | `Receipt`              | [L75](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L75) |
| other                              | iCKB xUDT                  | `Udt`                  | [L78](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L78) |
| DAO deposit (8 zero bytes) as lock | any                        | `ScriptMisuse` (error) | [L62](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L62) |
| iCKB xUDT as lock                  | any                        | `ScriptMisuse` (error) | [L63](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L63) |
| other                              | other                      | `Unknown` (ignored)    | [L81](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L81) |

`ScriptType::None` is only synthesized for [missing type scripts](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L48-L50); [`script_type()`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L95-L112) never returns `None` for locks, so the [`(ScriptType::None, _)`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L64) arm is unreachable. NervosDAO withdrawal requests, which have non-zero data, correctly classify as `Unknown` via [`is_deposit_data`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/utils/src/dao.rs#L17-L22).

### Deposit-Receipt Accounting (`check_output`)

[`entry.rs:86-140`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L86-L140) uses a `BTreeMap<u64, Accounting>` to ensure every group of same-sized output deposits is matched by equal receipt counts.

- Output deposit: [`extract_unused_capacity`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/utils/src/utils.rs#L47-L49) -> keyed by amount, `deposited += 1`
- Output receipt: [`extract_receipt_data`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/utils.rs#L18-L40) -> keyed by `deposit_amount`, `receipted += quantity`
- Final check at [`entry.rs:132-137`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L132-L137): all entries must have `deposited == receipted`

It also validates:

- Deposits: `1000 CKB <= unoccupied_capacity <= 1M CKB` ([`entry.rs:101-106`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L101-L106), bounds at [`constants.rs:5-6`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/constants.rs#L5-L6))
- Receipts: `deposit_quantity > 0` ([`entry.rs:114-116`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L114-L116))
- UDT: `amount <= u64::MAX` ([`entry.rs:123-125`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L123-L125))

### iCKB Conversion (`deposit_to_ickb`)

[`entry.rs:71-84`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L71-L84) uses the same conversion for minting and withdrawal:

```rust
let ickb_amount = amount * ar_0 / ar_m;
if ickb_amount > ICKB_SOFT_CAP_PER_DEPOSIT {
    return Ok(ickb_amount - (ickb_amount - ICKB_SOFT_CAP_PER_DEPOSIT) / 10);
}
```
---

- Division by zero: impossible (the [RFC 0023 accumulated-rate rule](https://github.com/nervosnetwork/rfcs/blob/4b502ffcb02fc7019e0dd4b5f866b5f09819cfbe/rfcs/0023-dao-deposit-withdraw/0023-dao-deposit-withdraw.md#calculation) sets `AR_0 = 10 ^ 16` and `AR_i = AR_{i-1} + floor(AR_{i-1} * s_i / C_{i-1})`, so `AR_m` is non-zero).
- Overflow: `u64 * u128` fits in u128 (~1.8e19 \* 1e16 = ~1.8e35 < 3.4e38).
- Precision: integer division loses at most 1 shannon per operation.
- Fee/discount symmetry: the same function is used for both input receipts (fee, [`entry.rs:58-59`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L58-L59)) and input deposits (discount, [`entry.rs:52`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/entry.rs#L52)). The protocol breaks even: minted amount = burned amount.

### `has_empty_args` Validation

Cell identification relies on the exact deployed script hash. [`utils/utils.rs:14-36`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/utils/src/utils.rs#L14-L36) enforces empty args on:

- The current script instance (covers input lock, input type, output type via CKB's execution model)
- All output locks matching the same code_hash + hash_type ([`utils.rs:29-31`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/utils/src/utils.rs#L29-L31))

Output types don't need explicit checking because they trigger execution and self-validate.

### Assessment

`iCKB Logic` has one state-admission blind spot plus several boundary points:

- **Provenance blind spot:** Receiptless DAO-shaped outputs can be admitted at output-lock creation time because CKB does not execute output locks, and later treated as pool deposits because [`cell_type_iter`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/ickb_logic/src/celltype.rs#L68-L75) classifies any `ickb_logic`-locked, DAO-typed, deposit-data input as `Deposit` with no receipt-provenance check. The [receiptless deposit-admission test](scripts/tests/src/tests/ickb_logic/receiptless_deposit_blind_spot.rs) confirms that admission-plus-later-classification path.
- **Accepted spread path is still self-funded:** When a separately provided split receipt is paired against a self-funded receiptless aggregate deposit, the contract accepts minting only the soft-cap valuation delta rather than the aggregate principal. The [delta-only spread test](scripts/tests/src/tests/ickb_logic/receiptless_deposit_blind_spot.rs) and the [oversized spread test](scripts/tests/src/tests/ickb_logic/receiptless_deposit_blind_spot.rs) show the accepted spread, while the [deposit-alone spread block test](scripts/tests/src/tests/ickb_logic/receiptless_deposit_blind_spot.rs) blocks the deposit-alone variant.
- **Ordinary mixed flows still apply the soft cap per receipt:** The [mixed phase1-phase2 soft-cap test](scripts/tests/src/tests/ickb_logic/soft_cap.rs) shows that adding fresh phase-1 deposits in the same transaction does not turn this into a general aggregate soft-cap bypass.
- **Executed path limit:** The [narrowing comment in the phase-2 claim test](scripts/tests/src/tests/ickb_logic/receiptless_deposit_blind_spot.rs) and the [self-funded principal claim test](scripts/tests/src/tests/ickb_logic/receiptless_deposit_blind_spot.rs) make the current limit explicit: the self-funded aggregate principal remains claimable in DAO phase 2, so the executed path does not show third-party principal theft or duplicated recovery.
- **Prefix behavior:** Trailing bytes in receipt and `xUDT` data reflect prefix-based parsing, while truncated encodings are still rejected. The [receipt trailing-bytes tests](scripts/tests/src/tests/ickb_logic/receipt_encoding.rs), [truncated receipt tests](scripts/tests/src/tests/ickb_logic/receipt_encoding.rs), and [trailing/short `xUDT` output-data tests](scripts/tests/src/tests/ickb_logic/phase2_xudt_output_data.rs) cover that behavior.
- **Weak-lock boundary:** Recipient-redirection scenarios remain boundary cases and do not apply under the current [whole-transaction-binding user-lock assumption](https://github.com/ickb/whitepaper/blob/cdbabf653ba98eacea397f94f8c894f32a538d6c/README.md#ancillary-scripts).
- **Rounding:** Whole-CKB rounding claims remain false leads. The [rounding mint test](scripts/tests/src/tests/ickb_logic/economic_precision.rs) and the [rounding withdrawal test](scripts/tests/src/tests/ickb_logic/economic_precision.rs) fail unless exact shannon precision is used.

On current executable evidence, that provenance-blind path is real, but it still falls short of a confirmed theft or standalone profit finding.

---

## Owned Owner

The deployed [`Owned Owner`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/owned_owner/src/entry.rs) binary preserves its pairing invariant under the current assumptions. The remaining questions concern which cells can be paired and who controls the pair at creation time.

### Design

`Owned Owner` pairs owned cells, namely NervosDAO withdrawal requests, with owner cells through a `MetaPoint` derived from the owner cell's `owned_distance` field:

- **Mint:** the owner cell stores a signed distance to the owned cell, so `owned_index == owner_index + owned_distance`.
- **Melt:** both cells must be consumed together.

### Validation

For inputs and outputs separately, the script enforces the same pairing rules:

- Each metapoint must have exactly `owned == 1` and `owner == 1` ([`entry.rs:57-60`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/owned_owner/src/entry.rs#L57-L60)).
- Owned cells must be NervosDAO withdrawal requests: DAO type + non-zero data ([`entry.rs:45-47`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/owned_owner/src/entry.rs#L45-L47)).
- A cell using the script as both lock and type is rejected ([`entry.rs:53`](https://github.com/ickb/contracts/blob/454cfa966052a621c4e8b67001718c29ee8191a2/scripts/contracts/owned_owner/src/entry.rs#L53)).

### Assessment

`Owned Owner` leaves four boundary points. The live claim-rotation path stays blocked in the currently modeled flows:

- **Live claim rotation remains blocked:** Attempts to roll a live claim into fresh `Owned Owner` pairs or to crosswire a fully DAO-constrained batch are rejected before a new live pairing survives. The [fresh-pair rotation block test](scripts/tests/src/tests/owned_owner/live_claim_rotation.rs), [new-pair rotation block test](scripts/tests/src/tests/owned_owner/live_claim_rotation.rs), and the [DAO index-rule crosswire block test](scripts/tests/src/tests/owned_owner/dao_crosswiring.rs) show that block.
- **Crosswired later-claim ownership still depends on weak phase-1 authorization:** When phase-1 owner outputs use weak or otherwise non-output-binding locks, later DAO claims can be reassigned across mixed foreign-plus-iCKB batches or fully iCKB batches. The [mixed foreign-plus-iCKB weak-lock crosswire test](scripts/tests/src/tests/owned_owner/mixed_asset_crosswiring.rs), [two-way weak-lock crosswire claim test](scripts/tests/src/tests/owned_owner/dao_crosswiring.rs), and [three-way weak-lock crosswire claim test](scripts/tests/src/tests/owned_owner/dao_crosswiring.rs) show that boundary case. Under the current strong-lock deployment assumption, this is not a present finding.
- **Foreign DAO withdrawal wrapping is allowed:** The [foreign DAO wrapping test](scripts/tests/src/tests/owned_owner/foreign_dao_wrapping.rs) shows that any DAO withdrawal request can be wrapped and later claimed, because the script checks only DAO type plus withdrawal-shaped data on the owned cell.
- **Creator-side dead states are narrower than arbitrary malformed pairs:** When `Owned Owner` actually executes as a type script, it rejects orphan and count-mismatch shapes, as shown by the [orphan-owner rejection test](scripts/tests/src/tests/owned_owner/pair_formation.rs) and the [two-owner mismatch test](scripts/tests/src/tests/owned_owner/pair_formation.rs). But creation still accepts pairs whose owner lock never validated, as shown by the [unspendable foreign-owner-lock test](scripts/tests/src/tests/owned_owner/foreign_owner_lock_boundaries.rs) and the [limit-order owner-lock stranding test](scripts/tests/src/tests/owned_owner/foreign_owner_lock_boundaries.rs). It also allows lock-only `Owned Owner` look-alikes that later fail on spend, as shown by the [lock-only non-DAO look-alike test](scripts/tests/src/tests/owned_owner/script_misuse.rs) and the [lock-only DAO-deposit look-alike test](scripts/tests/src/tests/owned_owner/script_misuse.rs).

---

## Deployment Context and Documented Risks

### Witness Malleability (Documented)

Witness malleability is a documented property, not a new finding. All three scripts use the script-as-lock (unsigned) plus script-as-type (controller) pattern, and none of them reads witnesses.

The [whitepaper states the consequence directly](https://github.com/ickb/whitepaper/blob/cdbabf653ba98eacea397f94f8c894f32a538d6c/README.md#unsigned-lock-witnesses-malleability): "if a script in a transaction needs to store data in the witness and this data can be tampered without the transaction becoming invalid, then this transaction must not employ the scripts presented in the current whitepaper."

### Non-Upgradable Deployment

The reviewed deployment is non-upgradable under the observed script references.

Under [RFC 0022](https://github.com/nervosnetwork/rfcs/blob/4b502ffcb02fc7019e0dd4b5f866b5f09819cfbe/rfcs/0022-transaction-structure/0022-transaction-structure.md#code-locating) and [RFC 0032](https://github.com/nervosnetwork/rfcs/blob/4b502ffcb02fc7019e0dd4b5f866b5f09819cfbe/rfcs/0032-ckb-vm-version-selection/0032-ckb-vm-version-selection.md#specification), the deployed scripts in transactions use `hash_type = data1`. Referencing scripts locate code from `cell_deps` by cell data hash and run it on CKB VM v1. That reference mode pins validation to the exact deployed binary bytes.

This pinning is not a property stored in the binary cell itself. It is a property of how scripts in transactions refer to that cell.

By contrast, `hash_type = type` would locate code by type-script hash, allowing a replacement code cell with the same type script and different contents, with upgrade policy then governed by that code cell's lock script. Separately, the published binary cells themselves are locked with a `secp256k1_blake160` zero lock, an unspendable lock, so no trusted operator key remains as an owner of the binaries.

Under the `hash_type = data1` reference mode, fixing a post-deployment bug would require migration to new script deployments and a new dep group.

---

## Conclusion

Under the current deployment assumptions, only the known `Limit Order` confusion attack remains live.

The `iCKB Logic` provenance-blind path exists, but the executed tests still stop at a self-funded edge case.

The remaining `Owned Owner` and cross-script cases are blocked or confined to integration/deployment boundaries.