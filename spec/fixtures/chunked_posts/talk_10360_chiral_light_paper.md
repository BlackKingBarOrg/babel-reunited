Light paper · 2026-06

![image|690x384](upload://fXzNzRVC8gn72ZXF5ELDiuG1Swm.png)


> **Status: research-stage.** Both legs have run their full lifecycle on public testnet (Cardano preview ↔ CKB Pudge). The protocol is **not audited and not production-ready**: the CKB→Cardano leg's soundness currently rests on a Groth16 trusted setup produced by a development ceremony, not a real multi-party one.

> **On the name.** *Chirality* is the property of a structure whose mirror image cannot be superimposed on it: two forms, oppositely handed, irreducibly distinct yet built from the same parts. Chiral's two legs are exactly that: one binding construction, mirrored into two oppositely-oriented oracles (Mithril-in-CKB-VM and Groth16-in-Plutus), neither reducible to the other.

> In the lineage of *RGB++* (Cipher / Nervos). RGB++ bound a CKB cell to a **Bitcoin** UTxO and let CKB follow Bitcoin via an SPV light client. This paper generalizes that construction: the anchor is no longer forced to be a chain that can only be *watched*, it can be a chain that **also verifies back**, and verification in **both** directions is done by a *succinct, in-script* light client rather than a committee, a multisig, or a custodian. Instantiated between **Cardano** and **CKB**, the result is a fully bidirectional isomorphic-binding protocol with no bonded authority anywhere in the safety path. Both directions have run their full lifecycle on testnet.

---

## Abstract

We describe a cross-chain construction in which an asset's **ownership** is a *single-use seal* on one chain and its **programmable state** is a *cell/UTxO* on another, exactly as in RGB++. RGB++ realizes this with Bitcoin as the anchor: Bitcoin holds ownership, CKB holds state, and CKB verifies Bitcoin through an on-chain SPV light client. Because Bitcoin cannot run a verifier of CKB, RGB++ binding is intrinsically **asymmetric in capability**: CKB can verify Bitcoin, never the reverse.

We observe that the binding itself is symmetric, *only the oracle each side runs is direction-specific*, and that two recent capabilities make the symmetric instantiation practical: **Mithril**, Cardano's stake-based BLS threshold certificate of settled history, which a CKB-VM script can verify for a few percent of a block; and **BLS12-381 builtins on Cardano**, which let a Plutus script verify a constant-size **Groth16** proof, and therefore verify a SNARK that attests CKB's Eaglesong PoW consensus, well within a transaction's budget.

Plugging one oracle into each direction yields **Chiral**: a symmetric isomorphic-binding protocol in which Cardano verifies CKB and CKB verifies Cardano, each by a single succinct proof checked *on-chain*, with the binding construction unchanged on both sides and **no committee in either**. Both legs have been built and run end-to-end on Cardano preview ↔ CKB Pudge.

---

## Why this matters

Today, moving an asset between two chains means trusting a **bridge**: a custodian, a bonded multisig, or a committee that holds the asset on one side and issues an IOU on the other. Bridges are where the money is lost, because the trust sits in a set of operators rather than in the chains themselves.

Isomorphic binding removes that intermediary: the asset is **anchored**, never **wrapped**. There is no peg to defend, no redemption queue, no custody pool, and no operator set whose honesty you must assume. What Chiral adds on top is **symmetry**: the same construction runs in both directions, so neither chain is a privileged custodian of the other. Concretely, this makes possible:

* **Custody-free cross-chain assets.** A token can live as programmable state on CKB while its ownership is a single-use seal on Cardano (or the reverse), with no wrapped representation and no bridge operator anywhere in the safety path.
* **Native cross-chain state, not just transfers.** Because the follower holds *programmable* state (a CKB cell or a Plutus UTxO), an asset can carry application logic across the boundary, not merely change hands: royalty rules, vesting schedules, or DEX positions survive the leap.
* **Symmetric composability.** Either chain can be the ownership layer for the other, so an application can put settlement where it is cheapest or most expressive and still have the counterparty chain verified on-chain.

The trust you are left with is exactly the two chains' own consensus plus the soundness of one cryptographic object per direction (a stake-threshold signature and a SNARK), both checked *on-chain*. That is a categorically smaller surface than any custodial or committee bridge.

---

## 1. Background: RGB and RGB++

RGB moves asset state off-chain and uses Bitcoin only as a commitment and double-spend layer: ownership is tied to the right to spend a particular Bitcoin UTxO (a *single-use seal*), and each transfer commits the new state into the spending transaction. This is powerful but client-heavy: there is no shared, programmable, globally-validated state.

**RGB++** (Cipher) gives that off-chain state a *home*: a **CKB cell**. CKB is a UTXO-model chain whose cells carry arbitrary data and whose RISC-V scripts ("CKB-VM") perform arbitrary verification. RGB++ binds a CKB cell *isomorphically* to a Bitcoin UTxO:

* the **Bitcoin UTxO holds ownership**: spending it authorizes a state transition;
* the **CKB cell holds the rich state and the transition script**;
* each transition is **committed into the Bitcoin transaction**, and a **Bitcoin SPV light client maintained on CKB** lets CKB scripts verify, in-script, that the commitment was really made on Bitcoin.

The enabling primitive is precisely *CKB as a verification layer that runs a light client of the anchor chain*. RGB++ also introduced **Leap**: because the binding is structure preserving, value can move ("leap") between the Bitcoin-anchored and purely-CKB representations without wrapping or custody.

### 1.1 The limit we remove

RGB++ binding is **one-directional in capability**, and this is forced by Bitcoin, not chosen:

> CKB can verify Bitcoin (SPV is cheap on CKB-VM), but **Bitcoin cannot verify CKB**: it has no facility to check Eaglesong PoW, an MMR proof, or a SNARK in-script.

So the anchor is permanently the *watched* chain and CKB is permanently the *watcher*. Leap between Bitcoin and CKB is still bidirectional (moving the anchor back to Bitcoin is just an ordinary Bitcoin spend that CKB observes, and **never requires Bitcoin to verify CKB**) but the *trust topology* is fixed: one chain dictates, one chain follows.

We ask: what if the anchor is a chain that can *also* verify back? Then the *same* binding runs in both directions, each side cryptographically checking the other, and neither side is privileged.

### 1.2 Relationship to RGB and RGB++, and why a new name

RGB and RGB++ are, at their core, **Bitcoin** constructions: Bitcoin is the anchor in each. Chiral keeps the *binding idea* but uses **no Bitcoin at all**:

||**RGB**|**RGB++** (Cipher / Nervos)|**Chiral**|
| --- | --- | --- | --- |
|Anchor chain|Bitcoin|Bitcoin|**Cardano** (no Bitcoin)|
|Where state lives|**off-chain** (client-side validation)|**on-chain**: a CKB cell|on-chain: a CKB cell / a Cardano UTxO|
|Who verifies whom|clients validate; Bitcoin = commitment layer|CKB verifies Bitcoin (SPV)|**both**: CKB verifies Cardano *and* Cardano verifies CKB|
|Direction of capability|n/a|**one-way** (Bitcoin can't verify CKB)|**two-way / symmetric**|
|Committee / custodian|none|none|none|

So the honest framing, in one paragraph:

> The **isomorphic-binding primitive is Cipher's** (RGB++), and that lineage is Bitcoin-rooted (RGB itself is a Bitcoin client-side-validation protocol). Chiral does **not** invent the binding. What Chiral contributes is **(i)** removing Bitcoin and substituting a *programmable* partner (Cardano) so the anchor can verify *back*, **(ii)** the resulting **symmetric, bidirectional** trust topology, and **(iii)** the in-script verification machinery the reverse leg requires: a **Groth16 SNARK of CKB's Eaglesong PoW consensus** checked inside Plutus, which Bitcoin structurally cannot host. The binding is unchanged; the anchor and the directionality are new.

Why this warrants a distinct name rather than "RGB++":

* RGB and RGB++ are **defined by Bitcoin's anchoring role**; Chiral has no Bitcoin and is bidirectional, so calling it "RGB++" would be inaccurate (and would misappropriate Cipher's term). Calling it RGB would be doubly wrong: RGB keeps state *off-chain*, which RGB++ already left behind and Chiral does not use.
* Conversely, in CKB circles "RGB++" is sometimes used **loosely** for "isomorphic binding on CKB" in general; under that loose usage one could say Chiral is *RGB++-style*. We prefer to be precise: **Chiral is in the RGB++ lineage, credited to Cipher, and is its symmetric generalization off Bitcoin**, not RGB++ itself, and not a new cryptographic primitive.

**Honest scope of the "trustless / no-committee" claim.** Both legs are committee-free *by construction* and have run their full lifecycle on testnet. But the CKB→Cardano leg's soundness rests on a Groth16 **trusted setup**, which today is a development ceremony (rogue-resistant, but not a real multi-party run), and the whole system has not had a third-party audit. So "each chain verifies the other, no committee" is true at the **cryptographic / design** level; it is **not yet** a deployed, value-bearing guarantee.

---

## 2. The core idea: the binding is symmetric, only the oracle differs

Strip isomorphic binding to its essence:

> **Ownership** = a *single-use seal* on the **anchor** chain. **State** = a *cell/UTxO* on the **follower** chain. The follower transitions its state **iff** it can prove, via an **oracle**, that the seal moved in the authorized way and committed to the new state.

Nothing there names a particular chain, nor even a particular *direction*. The only direction-specific component is the **oracle**: the in-script procedure by which the follower convinces itself the anchor's seal really moved. RGB++ instantiates it as *Bitcoin SPV in CKB-VM*. Swap the oracle and you re-point the binding at any pair of chains, in either direction.

||anchor (ownership = seal)|follower (state = cell)|oracle the follower runs in-script|
| --- | --- | --- | --- |
|**RGB++**|Bitcoin UTxO|CKB cell|Bitcoin SPV light client|
|**Cardano-anchored leg**|Cardano UTxO under a Plutus *binding lock*|CKB *bound cell*|**Mithril** stake-BLS cert + tx-membership proof, in CKB-VM|
|**CKB-anchored leg**|CKB *seal cell* (single-use by construction)|Cardano UTxO under a Plutus *binding lock*|**Groth16 proof of CKB consensus** (Eaglesong + header-MMR + inclusion), in Plutus|

These are *the same construction with two oracles*. We did not build two protocols; we built one binding and gave each direction its oracle. Run both at once and the protocol is symmetric: **each chain verifies the other, on-chain, with one succinct proof**, and there is **no committee, custodian, or governor** on either side. That is the whole contribution.

---

## 3. The binding, precisely

We use *seal* for the single-use ownership token and *bound cell* for the follower state. The construction is symmetric, so we state it once.

### 3.1 Objects

```
SEAL  (anchor chain): a single-use UTxO/cell whose spend authorizes one transition.
                      - On Cardano: a unique NFT at a Plutus "binding lock", datum = owner.
                      - On CKB: a cell (CKB cells are consumed exactly once by construction).

BOUND (follower chain): the asset's programmable state.
                      - data  = { seal: <anchor seal outpoint>, asset: <app state> }
                      - script = the transition rule (a CKB type script, or a Plutus lock)
                      - "owner" ≡ whoever can spend the current SEAL with a matching commitment.

COMMITMENT: H( serialise(next BOUND state) ‖ next seal outpoint )      [H = Blake2b-256]
            embedded inside the body of the anchor transaction that spends the seal,
            so it is covered by that transaction's hash.
```

The seal makes the bijection explicit and survivable: **exactly one seal ↔ one bound cell**. Anchor-chain consensus guarantees the seal is spent at most once: that supplies double-spend safety, inherited rather than re-implemented.

### 3.2 A transition (the "leap")

To move the asset from state `S` to `S'`:

*Step A, on the anchor.** The current owner spends the seal in transaction `T`, which (i) recreates the seal for the next owner (transfer) *or* destroys it (leap-out), and (ii) embeds `commitment = H(S' ‖ OP')`, where `OP'` is the next seal's outpoint. A thin *binding lock* on the anchor enforces only seal-uniqueness, commitment-emission, and owner authorization: **it never inspects the follower's state.*

**Step B, on the follower.** The relayer presents the body of `T`, an **oracle proof** that `T` is real and final on the anchor, and the new state `S'`. The transition script accepts **iff** all of:

1. **`T` is certified** by the oracle (real + final on the anchor);
2. **seal consumed**: `T`'s inputs contain the current seal `OP`;
3. **seal recreated / destroyed** as the redeemer claims, defining `OP'` (or none);
4. **commitment matches**: the value committed inside `T` equals `H(S' ‖ OP')`;
5. **single transition**: exactly one bound cell continues, naming `OP'`.

Because the commitment lives inside `T`'s hashed body, and the oracle certifies that hash, a relayer **cannot forge `S'`**: only the `S'` the real owner committed to on the anchor can satisfy check (4). The relayer is pure liveness: it can stall, never steal.

### 3.3 Leap-in / leap-out

* **Leap-in (anchor → follower):** create the seal committing to a genesis state `S0`; once the creation tx is oracle-certified, mint the bound cell (genesis rule = checks (1),(4) with no prior cell).
* **Leap-out (follower → anchor):** the owner spends the seal back to a plain output *without* recreating it; the bound cell is then finalized/burned, its script accepting a proof of the seal's consumption-without-recreation. **The anchor never verifies the follower here**: the owner simply controls the seal; the follower merely observes the unbind. This is what lets even a "dumb" anchor participate in leap-out.

---

### 3.4 A worked example

To make the mechanics concrete, follow one asset, owned by **Alice**, across the Cardano-anchored leg (ownership on Cardano, state on CKB).

1. **Leap-in (Cardano → CKB).** Alice mints a unique **seal NFT** at the Plutus binding lock on Cardano, committing to a genesis state `S0` (say, "1000 units, royalty = 2%"). A relayer presents that Cardano transaction, plus a **Mithril** proof that it is certified, to the CKB `BoundAsset` script, which mints the **bound cell** carrying `S0` and naming Alice's seal. The asset now lives as programmable state on CKB; ownership stays on Cardano.
2. **Transition (Alice → Bob).** Alice spends the seal on Cardano in a transaction that recreates it for **Bob** and embeds `commitment = H(S' ‖ OP')`, where `S'` is the new state (e.g. after the royalty is paid) and `OP'` is Bob's new seal outpoint. Once that spend is Mithril-certified, the relayer drives the CKB bound cell forward, and the script checks: the certificate (1), that Alice's seal was consumed (2), that the committed value equals `H(S' ‖ OP')` (4), and that exactly one bound cell continues naming `OP'` (5). A relayer cannot substitute a different `S'`: only the state Alice actually committed to on Cardano satisfies check (4).
3. **Leap-out (CKB → Cardano).** Bob spends the seal on Cardano to a plain output *without* recreating it. The CKB bound cell is then finalized and burned, its script accepting a proof of the seal's consumption-without-recreation. The asset is fully back under ordinary Cardano control, and **Cardano never had to verify CKB** for this step.

At no point did anyone hold Alice's or Bob's asset in custody, sign on their behalf, or wrap it into an IOU. The relayer was pure liveness throughout: it could have stalled the process, never stolen or forged a state. The CKB-anchored leg is the mirror image, with ownership on CKB and a Groth16 proof of CKB consensus standing in for the Mithril oracle.

---

## 4. Oracle A: verifying Cardano on CKB (Mithril, in CKB-VM)

When **Cardano is the anchor**, CKB must convince itself, in-script, that a Cardano transaction spending the seal is real and settled. Cardano offers a gift for exactly this: **Mithril**, a stake-based **BLS12-381 threshold multi-signature** that certifies snapshots of settled chain state, designed so a light client can trust "≥ a stake threshold signed this snapshot" *without* replaying Ouroboros Praos.

The CKB-VM oracle `cardano_tx_is_certified(tx_body) → bool` does two things:

1. **Verify the Mithril certificate**: the threshold BLS signature over the certified message, against the stake-key set, which is *advanced epoch to epoch* by a light-client checkpoint cell (each cert carries the next epoch's verification key).
2. **Prove tx-membership**: a two-level Mithril proof showing `tx_hash = H(tx_body)` is in the certified transaction-set root.

Together they certify *this specific transaction*, and therefore the commitment inside it. A replay accumulator (an O(1) sparse-Merkle-tree of consumed seal outpoints) prevents re-processing the same spend.

A full Mithril verify costs a **few percent of a CKB block**, comfortably within budget; the **bind → transition → leap-out** lifecycle, plus continuous epoch rotation of the light-client checkpoint, has run live on CKB Pudge against real Cardano preview certificates.

**Trust:** Cardano consensus (ownership/double-spend) + Mithril honest-stake-majority (the oracle). No committee. A *fully trustless* upgrade (a ZK proof of Ouroboros Praos behind the same `cardano_tx_is_certified` interface) is prototyped as a hash-based STARK proof of the Mithril statement (see §8), a drop-in for the BLS check.

---

## 5. Oracle B: verifying CKB on Cardano (Groth16 of consensus, in Plutus)

This is the direction RGB++ cannot have, because its anchor is Bitcoin. Here the anchor is **CKB**: a CKB seal cell holds ownership, and **Cardano follows**: a bound UTxO at a Plutus binding lock transitions only when convinced the CKB seal was spent in a confirmed CKB block with the matching commitment.

CKB has no Mithril. Its light-client story is consensus-native: **Eaglesong PoW** + a **header MMR** (every header commits to an MMR of all prior headers) + heaviest-chain cumulative work. Verifying *that* natively in Plutus is infeasible: the per-script budget is two-to-three orders of magnitude smaller than CKB-VM's, and Eaglesong is not a builtin. So we verify it **succinctly**: an off-chain prover produces a constant-size **Groth16** proof that CKB consensus holds, and Plutus verifies that single proof using Cardano's **BLS12-381 builtins** (Miller loops + final exponentiation + a small public-input MSM).

The off-chain circuit proves four relations on a real CKB block:

* **PoW**: `ckbhash(eaglesong(pow_hash ‖ nonce)) ≤ target`, target decoded in-circuit, header hash recomputed from scratch;
* **chain root**: the header is a member of the checkpoint's header-MMR;
* **inclusion**: the seal-spend tx is bound to the header's transactions root via a CBMT path;
* **commitment**: the spend committed `H(next Cardano state)`.

A separate **checkpoint-advance** proof moves a Cardano-side `{chain_root, total_difficulty}` UTxO forward trustlessly: it proves a new header has valid PoW *and* a verified difficulty, computes the new MMR root **in-circuit**, and the validator enforces heaviest-chain (`new_total > old_total`).

On-chain, the Groth16 verify costs roughly **a quarter of a Cardano transaction's budget**, leaving ample headroom for the binding logic; a tampered public input is rejected. The full **lock → verify → mint → burn → unlock** round trip has run live on testnet, with every gadget (Eaglesong, Blake2b/ckbhash, MMR/CBMT membership, target-compare, 256-bit add) differential-tested against native CKB on real data.

**Trust:** CKB PoW honest-majority + Groth16 soundness. Groth16 needs a per-circuit **trusted setup** (see §7); a transparent PLONK with a universal SRS retires it.

---

## 6. The symmetric protocol

Run both oracles and the protocol is genuinely symmetric:

```
        CARDANO  ⇄  CKB

  Cardano-anchored leg:  ownership on Cardano (seal)   ·  state on CKB (bound cell)
                         CKB verifies Cardano  via  Mithril cert + tx-proof, in CKB-VM

  CKB-anchored leg:      ownership on CKB (seal cell)   ·  state on Cardano (bound UTxO)
                         Cardano verifies CKB  via  Groth16 of Eaglesong consensus, in Plutus
```

Neither chain is privileged. Neither wraps the other's asset into a custodial IOU: value is *anchored*, not *wrapped*, so there is no peg, no redemption queue, no custody pool. Neither trusts a named set of operators: the only trusted things are the two chains' own consensus and the soundness of two cryptographic objects (a stake-threshold signature and a SNARK), both checked *on-chain*. A relayer in either direction is pure liveness.

This is what RGB++ could not be, for a precise reason: RGB++'s anchor (Bitcoin) can be *watched* but cannot *watch back*. Give the follower a succinct in-script verifier of the other chain, Mithril (Cardano→CKB) and Groth16-of-Eaglesong (CKB→Cardano), and the binding becomes two-way.

---

## 7. Security

|Invariant|Enforced by|
| --- | --- |
|One seal ↔ one bound cell|seal uniqueness on the anchor + the bound cell naming its seal|
|No double-move|anchor consensus: the seal is spent at most once|
|New follower state is the one the owner authorized|commitment inside the anchor tx (covered by its hash) `== H(S')`, oracle-certified|
|Spend is real + final|the oracle: Mithril cert+membership (→CKB), or Groth16 of PoW+MMR+inclusion (→Cardano)|
|Ownership|seal spend requires owner authorization on the anchor|
|Replay|seal consumed once; cell advances to the new outpoint; certified state is monotone (epoch root / heaviest chain)|

**The trust surface is one oracle per direction.** Cross-chain soundness reduces to the soundness of that oracle: a *cryptographic/economic* assumption (honest stake majority, or SNARK soundness), not "trust these N operators." Beyond that reduction, four points an implementer must weigh honestly:

* **Relayers cannot forge, only stall.** The authorizing commitment is inside the anchor transaction the oracle certifies; anyone may relay, and a wrong `S'` fails check (4). Liveness degrades under a censored relay; safety does not.
* **Genesis is a social checkpoint.** Each light client starts from an initial trusted anchor (the first Mithril verification key on CKB; the first CKB chain-root on Cardano), as every light client must. This is a one-time, publicly-auditable parameter, not an ongoing trusted party.
* **The Groth16 leg carries a trusted-setup assumption.** A compromised setup ceremony could forge proofs for the CKB→Cardano oracle. It is a one-time risk, mitigated by a multi-party ceremony and removable entirely by a transparent (PLONK/universal-SRS) verifier. The Mithril leg has no setup.
* **Finality, not the tip.** Both oracles act only on *settled* history (Mithril-certified snapshots / sufficiently-deep CKB headers), so tip reorgs are invisible by construction, at the cost of a settlement-style latency: the follower trails the anchor by the certification or confirmation delay, by design.

A relayer can be run by anyone, including the asset holder, so liveness need not be trusted to a third party at all.

---

## 8. Post-quantum posture

We state this honestly, because a protocol can be no more post-quantum than the chains it connects, and overclaiming helps no one.

* **The binding core is already quantum-resistant.** Seals, commitments, the header MMR, the CBMT inclusion proofs, and the replay accumulator are all **hash-based** (Blake2b / SHA-2 family), which Grover only weakens quadratically, addressed by hash width, not by a new scheme.
* **Both oracles, today, rest on pre-quantum assumptions** (Mithril's BLS12-381 threshold signature and the Groth16 BLS12-381 pairing), exactly as the endpoint chains' own signatures do (Cardano Ed25519, CKB secp256k1). The protocol is therefore *not* post-quantum at the signature/pairing layer, and *says so*.
* **The Cardano→CKB oracle has a clean PQ upgrade path that is already prototyped.** A **STARK** proof of the *same* Mithril statement uses **FRI (hashes only), so it is plausibly post-quantum and needs no trusted setup**. All four Mithril relations have been composed into a single STARK on a real certificate and proven; verifying *that* proof in CKB-VM (by wrapping it in Groth16 or by a native FRI verifier) is the remaining, resource-gated step (a FRI verifier has been run in CKB-VM on a smaller computation; the Mithril-STARK wrap awaits a ≥32 GB prover). Once that lands it is a drop-in behind `cardano_tx_is_certified`. Mithril itself is moving toward STARK-based certificates for the same reason.
* **The CKB→Cardano oracle's PQ upgrade is genuinely harder, and we do not pretend otherwise.** Groth16 is pairing-based; a post-quantum replacement would mean verifying a hash-based (FRI/STARK) proof *on Cardano*, which today has BLS12-381 builtins but no efficient FRI verifier in its script budget. Until such a primitive exists (or recursion wraps the STARK into something Cardano can check cheaply), this leg's quantum resistance tracks the underlying pairing assumption.

*Summary:** the data structures are PQ; one oracle has a ready PQ path; the other's PQ path is open research; and the endpoint signatures bound the whole: *a protocol cannot be more post-quantum than its two chains.

---

## 9. On Bitcoin (reconciling with RGB++)

Does this subsume RGB++ (can BTC leap to CKB here too)? **Yes, in exactly the RGB++ sense, and only in that sense.** Bitcoin can serve as an anchor: CKB runs a Bitcoin SPV light client as its oracle, and value can leap **BTC ⇄ CKB** bidirectionally, because leap-out to Bitcoin (§3.3) is just an ordinary Bitcoin spend the follower observes, and **never asks Bitcoin to verify CKB**.

What Bitcoin *cannot* do is host **Oracle B**: it cannot verify CKB consensus in-script, so the *CKB-anchored, Bitcoin-follows* leg is impossible. Bitcoin is therefore a **one-way anchor**: it can anchor (CKB follows), but it can never *follow*. The same property makes other PoW UTXO chains (LTC, DOGE) anchor-only. The symmetric, verify-each-other topology of §6 requires a follower that can check a succinct proof on-chain, which is why we built first on Cardano (Plutus + BLS12-381) rather than Bitcoin.

So BTC↔CKB leap is *inherited* from RGB++ as a degenerate (anchor-only) case; the new thing this protocol adds is the *symmetric* case, impossible with Bitcoin, demonstrated with Cardano.

---

## 10. Generalization: anchor-agnostic binding

Because only the oracle is direction-specific, adding a chain `X` reduces to writing the relevant oracle(s):

* **`X` as anchor, CKB follows**: needs an `X`-light-client oracle *in CKB-VM*. Cheap for SPV chains (Bitcoin family); a Mithril/ZK verifier for Cardano.
* **CKB as anchor, `X` follows**: needs a *CKB-consensus verifier on `X`*. Trivial where `X` has a native Groth16 builtin, tractable where `X` has BLS12-381 primitives (Cardano), and *impossible* where `X` has no in-script verification (Bitcoin → anchor-only).

The binding construction (§3) never changes. A chain that can both be watched and verify back becomes a **first-class, symmetric** counterparty; a chain that can only be watched becomes an **anchor-only** counterparty in the RGB++ tradition.

---

## 11. Endgame: symmetric and both succinct

Today the two oracles differ in *kind*: a stake-threshold signature one way, a SNARK the other. The trust-minimized endgame swaps Mithril for a **ZK proof of Ouroboros Praos** behind the same interface (prototyped as a STARK of the Mithril statement) and retires the Groth16 trusted setup with a **universal-SRS PLONK** verifier. The destination:

> a fully bidirectional, **anchor-agnostic, committee-free** protocol in which **each chain verifies the other by a single succinct proof**, the isomorphic-binding construction unchanged on both sides: same binding, two oracles, both succinct.

RGB++ showed that a chain can be a verification layer for another by running its light client in-script. This work shows that when *both* chains can do so, the binding becomes symmetric, and the protocol needs no one to trust but the two chains themselves.

----
Light paper · 2026-06

![image|690x384](upload://fXzNzRVC8gn72ZXF5ELDiuG1Swm.png)

> **状态：研究阶段。** 两条路径都已在公开测试网上完成全生命周期运行（Cardano preview ↔ CKB Pudge）。该协议尚未审计，也不适合生产环境：CKB→Cardano 这一路径的安全性目前依赖一个由开发仪式生成的 Groth16 trusted setup，而非真正的多方可信仪式。

> **关于名称。** Chirality 是指一种结构具有“镜像不可与自身重合”的性质：两种形式，左右手性相反、不可归约地不同，但由相同的部件构成。Chiral 的两条路径正是如此：同一种绑定构造，分别镜像为两个方向相反的 oracle（CKB 中的 Mithril 与 Plutus 中的 Groth16），彼此都不能被对方化约。

> 在 RGB++（Cipher / Nervos）的谱系中，RGB++ 将一个 CKB cell 绑定到 Bitcoin UTxO，并让 CKB 通过 SPV 轻客户端跟随 Bitcoin。本文把这一构造推广到：锚定链不再必须是一个只能被“观察”的链，它也可以是一个能够反向验证的链，而且双向验证都由一种简洁的、脚本内置的 light client 完成，而不是依赖委员会、多签或托管方。以 Cardano 与 CKB 为实例，最终得到的是一种完全双向的同构绑定协议，安全路径中没有任何有担保责任的权限方。双向路径都已在测试网上完整跑通。

***

## 摘要

我们描述了一种跨链构造：资产的所有权是链上一枚一次性封印（single-use seal），而资产的可编程状态是另一条链上的 cell/UTxO，与 RGB++ 的思路完全一致。RGB++ 将 Bitcoin 作为锚定链：Bitcoin 承载所有权，CKB 承载状态，而 CKB 通过链上 SPV 轻客户端验证 Bitcoin。由于 Bitcoin 不能运行 CKB 的验证器，RGB++ 的绑定在能力上本质是单向的：CKB 能验证 Bitcoin，反过来不行。

我们注意到：绑定本身是对称的，只是两侧运行的 oracle 具有方向性；而且两个近期能力使这种对称实例化变得可行：Mithril——Cardano 基于权益的 BLS 阈值历史证明，CKB-VM 脚本可以验证它，成本仅占区块的几个百分点；以及 Cardano 上的 BLS12-381 内置，它允许 Plutus 脚本验证一个常数大小的 Groth16 证明，从而验证一个证明 CKB 的 Eaglesong PoW 共识的 SNARK，其成本完全在交易预算之内。

把每个方向各接入一个 oracle，就得到 Chiral：一种对称的同构绑定协议，Cardano 验证 CKB，CKB 验证 Cardano，双方都通过链上单个简洁证明完成验证，绑定构造在两边保持不变，并且任一侧都没有委员会。两条路径都已在 Cardano preview ↔ CKB Pudge 上构建并端到端运行。

***

## 这件事的意义

今天，在两条链之间转移资产，通常意味着要信任一个桥：托管方、抵押多签或委员会，它们在一侧持有资产，并在另一侧发行 IOU。桥之所以最容易出问题，就是因为信任落在一组运营者身上，而不是链本身。

同构绑定去掉了这个中介：资产是被锚定的，而不是被封装的。不存在需要维护的锚定汇率，没有赎回排队，没有托管池，也没有必须假定其诚实性的运营者集合。Chiral 在此基础上增加的是对称性：同一构造可双向运行，因此没有哪条链天然充当对方的托管方。具体来说，这让以下场景成为可能：

- 无托管的跨链资产。一个代币可以作为 CKB 上的可编程状态存在，而它的所有权作为 Cardano 上的一次性封印存在（反之亦然），整个安全路径中没有包装资产，也没有桥运营方。
- 原生跨链状态，而不仅仅是转账。因为跟随链承载的是可编程状态（CKB cell 或 Plutus UTxO），资产可以把应用逻辑一起带过边界，而不只是换手：版税规则、归属期、DEX 仓位都可以保留下来。
- 对称可组合性。任一条链都可以作为对方的所有权层，因此应用可以把结算放在更便宜或更具表达力的一侧，同时仍然让对端链在链上获得验证。

你最终剩下的信任，正好就是两条链自身的共识，加上每个方向一个密码学对象的安全性（一个权益阈值签名和一个 SNARK），而且二者都在链上被验证。这比任何托管式或委员会式桥的攻击面都要小得多。

***

## 1. 背景：RGB 与 RGB++

RGB 把资产状态放到链下，并只把 Bitcoin 用作承诺层和防双花层：所有权绑定到某个 Bitcoin UTxO 的花费权上（一个 single-use seal），每次转移都把新状态提交进花费交易里。这个设计很强，但客户端负担很重：它没有共享的、可编程的、全局验证状态。

RGB++（Cipher）给这种链下状态找了一个“家”：一个 CKB cell。CKB 是 UTXO 模型链，cell 可以携带任意数据，而它的 RISC-V 脚本（"CKB-VM"）可以执行任意验证。RGB++ 将一个 CKB cell 与 Bitcoin UTxO 做同构绑定：

- Bitcoin UTxO 承载所有权：花费它就授权一次状态转移。
- CKB cell 承载丰富状态和转移脚本。
- 每次转移都提交进 Bitcoin 交易，而 CKB 上维护的 Bitcoin SPV light client 让 CKB 脚本可以在脚本内验证：该承诺确实已经在 Bitcoin 上发生。

关键原语就是：CKB 作为验证层，在链上运行锚定链的轻客户端。RGB++ 还引入了 Leap：因为绑定是结构保持的，价值可以在 Bitcoin 锚定表示与纯 CKB 表示之间"leap"移动，而不需要包装或托管。

### 1.1 我们要移除的限制

RGB++ 的绑定在能力上是单向的，这不是设计选择，而是由 Bitcoin 强制决定的：

> CKB 可以验证 Bitcoin（SPV 在 CKB-VM 上成本很低），但 Bitcoin 不能验证 CKB：它没有在脚本内检查 Eaglesong PoW、MMR 证明或 SNARK 的能力。

所以锚定链始终是被"观看"的链，而 CKB 始终是"观察者"。Bitcoin 与 CKB 之间的 Leap 虽然是双向的（把锚定资产迁回 Bitcoin 只是一次普通的 Bitcoin 花费，由 CKB 观察即可，不需要 Bitcoin 验证 CKB），但信任拓扑是固定的：一条链发号施令，另一条链跟随。

我们提出的问题是：如果锚定链本身也能反向验证会怎样？那么同一个绑定就能双向运行，两边都能在密码学上检查对方，谁也不再享有特权。

### 1.2 与 RGB 和 RGB++ 的关系，以及为何需要新名字

RGB 和 RGB++ 本质上都是 Bitcoin 构造：两者都以 Bitcoin 为锚。Chiral 保留的是"绑定"思想，但完全不使用 Bitcoin：

| | RGB | RGB++（Cipher / Nervos） | Chiral |
|---|---|---|---|
| 锚定链 | Bitcoin | Bitcoin | Cardano（无 Bitcoin） |
| 状态存放位置 | 链下（客户端验证） | 链上：CKB cell | 链上：CKB cell / Cardano UTxO |
| 谁验证谁 | 客户端验证；Bitcoin = 承诺层 | CKB 验证 Bitcoin（SPV） | 双向：CKB 验证 Cardano，Cardano 也验证 CKB |
| 能力方向 | 不适用 | 单向（Bitcoin 不能验证 CKB） | 双向 / 对称 |
| 委员会 / 托管方 | 无 | 无 | 无 |

所以，诚实地说，一句话概括如下：

> 同构绑定原语属于 Cipher（RGB++），而这一谱系以 Bitcoin 为根（RGB 本身就是一种 Bitcoin 的客户端验证协议）。Chiral 没有发明绑定。Chiral 的贡献在于：(i) 去掉 Bitcoin，改用一个可编程的伙伴（Cardano），使锚定链能够反向验证；(ii) 因而得到对称、双向的信任拓扑；以及 (iii) 反向路径所需的链内验证机制：一个在 Plutus 内检查的、对 CKB 的 Eaglesong PoW 共识的 Groth16 SNARK，而 Bitcoin 在结构上无法承载这一点。绑定不变；变化的是锚定链和方向性。

为什么这需要一个独立名字，而不是继续叫"RGB++"：

- RGB 和 RGB++ 的定义都与 Bitcoin 的锚定角色绑定；Chiral 没有 Bitcoin，而且是双向的，所以把它叫成 RGB++ 会不准确（也会误用 Cipher 的术语）。把它叫成 RGB 就更不对了：RGB 保持状态链下，而 RGB++ 已经把它带到了链上，Chiral 也不是这种模式。
- 反过来，在 CKB 圈子里，"RGB++"有时被宽泛地用来指"CKB 上的同构绑定"。在这种宽泛用法下，可以说 Chiral 是 RGB++ 风格的。我们更倾向于严谨：Chiral 属于 RGB++ 谱系，归功于 Cipher，是它在 Bitcoin 之外的对称推广，但它不是 RGB++ 本身，也不是一种新的密码学原语。

关于"无须信任 / 无委员会"这一说法的诚实范围。两条路径在设计上都是无委员会的，而且都已在测试网上完成完整生命周期。但 CKB→Cardano 路径的安全性目前依赖 Groth16 trusted setup，而这份 setup 现在只是一个开发级仪式（具备抗串谋能力，但还不是真正的多方正式仪式），而且整个系统尚未接受第三方审计。所以，"每条链都验证对方、没有委员会"在密码学 / 设计层面是真的；但它还不是一个已部署、可承载真实价值的保证。

***

## 2. 核心思路：绑定是对称的，只有 oracle 不同

把同构绑定剥到最核心：

> 所有权 = 锚定链上的一个一次性封印。状态 = 跟随链上的一个 cell/UTxO。只有当跟随链能够通过一个 oracle 证明封印以授权方式移动，并且提交了新的状态时，它才会接受状态转移。

这里没有指定某条链，甚至没有指定固定方向。唯一具有方向差异的是 oracle：也就是跟随链在脚本内用来确认锚定链上的封印确实移动了的过程。RGB++ 把它实现为 CKB-VM 内的 Bitcoin SPV。如果替换 oracle，就能把绑定重新指向任意一对链，且可双向应用。

| | 锚定链（所有权 = seal） | 跟随链（状态 = cell） | 跟随链在脚本内运行的 oracle |
|---|---|---|---|
| RGB++ | Bitcoin UTxO | CKB cell | Bitcoin SPV light client |
| Cardano 锚定路径 | Cardano UTxO（Plutus binding lock） | CKB bound cell | Mithril 权益 BLS 凭证 + 交易成员证明，运行于 CKB-VM |
| CKB 锚定路径 | CKB seal cell（按设计一次性使用） | Cardano UTxO（Plutus binding lock） | Groth16 证明 CKB 共识，运行于 Plutus |

这些其实是同一个构造，只是接了两个不同的 oracle。我们不是建了两个协议，而是建了一个绑定构造，并为两个方向各自接上了 oracle。把它们同时运行起来，协议就变成对称的：两条链都能在链上用一个简洁证明验证对方，而且双方都没有委员会、托管方或治理者。这就是全部贡献。

***

## 3. 绑定的精确定义

我们把锚定链上的一次性所有权 token 叫做 seal，把跟随链上的资产状态叫做 bound cell。由于构造是对称的，这里统一说明。

### 3.1 对象

```
SEAL（锚定链）: 一个一次性 UTxO / cell，其花费授权一次状态转移。
                - 在 Cardano 上：一个位于 Plutus "binding lock" 的唯一 NFT，datum = owner。
                - 在 CKB 上：一个 cell（CKB cell 按构造一次性消耗）。

BOUND（跟随链）: 资产的可编程状态。
                - data  = { seal: <锚定链 seal 的 outpoint>, asset: <应用状态> }
                - script = 转移规则（CKB type script 或 Plutus lock）
                - "owner" ≡ 当前 seal 的持有人，且该 seal 的花费与匹配提交相一致。

COMMITMENT: H( serialize(next BOUND state) ‖ next seal outpoint )      [H = Blake2b-256]
            嵌入到锚定链花费 seal 的交易体中，
            因而被该交易哈希所覆盖。
```

seal 使映射关系明确且可持续：一个 seal ↔ 一个 bound cell，且一一对应。锚定链共识保证 seal 最多只会被花费一次：这提供了双花安全性，而且是继承来的，不需要重新实现。

### 3.2 一次转移（"leap"）

要把资产从状态 S 迁移到 S'：

步骤 A，在锚定链上。当前所有者在交易 T 中花费 seal，交易中要么：(i) 为下一位所有者重新创建 seal（转移），要么 (ii) 直接销毁 seal（leap-out）；同时还要嵌入 commitment = H(S' ‖ OP')，其中 OP' 是下一个 seal 的 outpoint。锚定链上的一个轻量 binding lock 只负责检查 seal 唯一性、承诺的生成以及所有者授权：它从不检查跟随链状态。

步骤 B，在跟随链上。中继者提交交易 T 的主体、一个证明 T 在锚定链上真实且已最终确定的 oracle proof，以及新状态 S'。只有当以下条件全部满足时，转移脚本才接受：

1. T 被 oracle 认证（在锚定链上真实且最终确定）；
2. seal 已被消耗：T 的输入中包含当前 seal OP；
3. seal 被重新创建 / 被销毁，并且重建方式与 redeemer 的声明一致，从而定义出 OP'（或为空）；
4. 承诺匹配：T 中承诺的值等于 H(S' ‖ OP')；
5. 单次转移：只有一个 bound cell 继续存在，并且它指向 OP'。

由于承诺位于 T 的已哈希交易体内，并且 oracle 对该哈希进行认证，中继者无法伪造 S'：只有真实所有者在锚定链上承诺的 S' 才能通过条件 (4)。中继者只影响活性，不影响安全性。

### 3.3 Leap-in / leap-out

- Leap-in（锚定链 → 跟随链）：创建一个 seal，承诺一个创世状态 S0；一旦该创建交易被 oracle 认证，就可以铸造 bound cell（创世规则 = 检查 (1)、(4)，不需要前序 cell）。
- Leap-out（跟随链 → 锚定链）：所有者把 seal 花费回一个普通输出，且不再重新创建它；随后 bound cell 被最终化/销毁，其脚本接受一个关于 seal 已被消耗且未重建的证明。在这里锚定链并不验证跟随链：所有者只是在控制 seal；跟随链只是观察 unbind。这就是为什么即使是"愚钝"的锚定链也能参与 leap-out。

### 3.4 具体示例

为了让机制更直观，下面跟踪一笔资产，所有者为 Alice，沿着 Cardano 锚定路径移动（所有权在 Cardano，状态在 CKB）。

1. Leap-in（Cardano → CKB）。Alice 在 Cardano 的 Plutus binding lock 上铸造一个唯一的 seal NFT，并承诺一个创世状态 S0（例如："1000 单位，版税 = 2%"）。中继者把这笔 Cardano 交易及其 Mithril 认证证明提交给 CKB 的 BoundAsset 脚本，脚本据此铸造携带 S0 的 bound cell，并记录 Alice 的 seal。此时资产作为可编程状态存在于 CKB 上，而所有权仍在 Cardano 上。

2. 状态转移（Alice → Bob）。Alice 在 Cardano 上花费 seal，生成一笔交易：既为 Bob 重新创建 seal，又嵌入 commitment = H(S' ‖ OP')，其中 S' 是新状态（比如扣除版税后的状态），OP' 是 Bob 的新 seal outpoint。一旦这次花费被 Mithril 认证，中继者就推动 CKB 上的 bound cell 前进，脚本检查：认证证明 (1)、Alice 的 seal 已被消耗 (2)、承诺值等于 H(S' ‖ OP') (4)、并且只有一个 bound cell 继续存在且指向 OP' (5)。中继者无法替换成别的 S'：只有 Alice 真正在 Cardano 上承诺的状态才能通过 (4)。

3. Leap-out（CKB → Cardano）。Bob 在 Cardano 上花费 seal 到一个普通输出，但不再重新创建它。随后 CKB 上的 bound cell 被最终化并销毁，其脚本接受一个关于 seal 已被消耗且未重建的证明。资产此时完全回到 Cardano 的普通控制之下，而且在这一步中，Cardano 从未需要验证 CKB。

整个过程中，没有任何人持有 Alice 或 Bob 的资产，也没有替他们签名，更没有把资产包装成 IOU。中继者始终只负责活性：它可以阻塞流程，但无法窃取或伪造状态。CKB 锚定路径只是镜像版本，所有权在 CKB，而 Groth16 证明的 CKB 共识则取代 Mithril 作为 oracle。

***

## 4. Oracle A：在 CKB 上验证 Cardano（Mithril，运行于 CKB-VM）

当 Cardano 是锚定链时，CKB 必须在脚本内确认：某笔花费 seal 的 Cardano 交易真实存在且已最终确定。Cardano 恰好提供了一个非常适合这件事的能力：Mithril，它是基于权益的 BLS12-381 阈值多重签名，用于认证已最终确定的链状态快照，光客户端无需重放 Ouroboros Praos 就能信任"达到权益阈值的签名者共同签了这个快照"。

CKB-VM 上的 oracle cardano_tx_is_certified(tx_body) → bool 做两件事：

1. 验证 Mithril 认证书：针对被认证消息的阈值 BLS 签名，并与权益密钥集合进行比对，这个密钥集合会按 epoch 更新；轻客户端 checkpoint cell 会逐 epoch 推进（每个证书都带有下一个 epoch 的验证密钥）。
2. 证明交易成员关系：通过两层 Mithril 证明，证明 tx_hash = H(tx_body) 属于被认证的交易集合根。

两者合起来，就认证了这笔特定交易，因此也认证了其中的承诺。一个重放累加器（已消耗 seal outpoint 的 O(1) 稀疏 Merkle 树）可以防止同一笔花费被重复处理。

完整的 Mithril 验证大约只消耗 CKB 区块几个百分点的资源，完全在预算之内；而 bind → transition → leap-out 的全生命周期，以及轻客户端 checkpoint 的持续 epoch 轮换，已经在 CKB Pudge 上对真实 Cardano preview 认证证书完成了实网运行。

信任：Cardano 共识（所有权 / 防双花）+ Mithril 的诚实多数权益假设（oracle）。没有委员会。一个真正无信任的升级方案（在相同 cardano_tx_is_certified 接口下，用 ZK 证明 Ouroboros Praos）已经以对 Mithril 语句的 hash-based STARK 形式原型化了（见 §8），可直接替换 BLS 检查。

***

## 5. Oracle B：在 Cardano 上验证 CKB（Groth16 共识证明，运行于 Plutus）

这一方向是 RGB++ 无法拥有的，因为它的锚定链是 Bitcoin。这里锚定链是 CKB：一个 CKB seal cell 持有所有权，而 Cardano 跟随：Plutus binding lock 上的 bound UTxO 只有在确认 CKB seal 已在一个包含匹配承诺的已确认 CKB 区块中被花费时才会转移。

CKB 没有 Mithril。它的轻客户端故事完全依赖共识本身：Eaglesong PoW + header MMR（每个 header 都承诺一个包含所有先前 header 的 MMR）+ heaviest-chain 的累计工作量。要在 Plutus 中原生验证这一切不可行：每个脚本的预算比 CKB-VM 小两到三个数量级，而且 Eaglesong 不是内置函数。所以我们采用简洁证明：由链下证明者生成一个常数大小的 Groth16 证明，用于证明 CKB 共识成立，而 Plutus 只需要用 Cardano 的 BLS12-381 内置（Miller loop + final exponentiation + 少量公有输入 MSM）来验证这个单一证明。

链下电路在一个真实的 CKB 区块上证明四类关系：

- PoW：ckbhash(eaglesong(pow_hash ‖ nonce)) ≤ target，目标值在电路内解码，区块头哈希从头重新计算；
- 链根：该 header 是 checkpoint 所持有的 header-MMR 根中的成员；
- 包含性：seal 花费交易通过 CBMT 路径绑定到该 header 的交易根；
- 承诺：这笔花费确实承诺了 H(next Cardano state)。

一个单独的 checkpoint-advance 证明可以把 Cardano 侧的 {chain_root, total_difficulty} UTxO 无信任地推进：它证明新的 header 既具有有效 PoW，又具有已验证的 difficulty，电路内计算新的 MMR 根，并由验证器强制 heaviest-chain 规则（new_total > old_total）。

在链上，Groth16 验证大约只消耗 Cardano 交易预算的四分之一，因此绑定逻辑仍有充足余量；若 public input 被篡改，会直接被拒绝。完整的 lock → verify → mint → burn → unlock 往返已经在测试网上跑通，所有 gadget（Eaglesong、Blake2b/ckbhash、MMR/CBMT 成员关系、目标值比较、256 位加法）都已针对真实数据与原生 CKB 做差分测试。

信任：CKB PoW 的诚实多数 + Groth16 的安全性。Groth16 需要每个电路都做一次 trusted setup（见 §7）；未来可以用透明的、带通用 SRS 的 PLONK 验证器来消除它。

***

## 6. 对称协议

当两种 oracle 都运行起来时，协议就是真正对称的：

```
        CARDANO  ⇄  CKB

  Cardano 锚定路径：  所有权在 Cardano（seal）   ·  状态在 CKB（bound cell）
                    CKB 通过 Mithril 认证书 + 交易证明在 CKB-VM 中验证 Cardano

  CKB 锚定路径：      所有权在 CKB（seal cell）   ·  状态在 Cardano（bound UTxO）
                    Cardano 通过 Groth16 的 Eaglesong 共识证明在 Plutus 中验证 CKB
```

没有哪条链是特权方。任何一方都不是把对方资产包装成托管 IOU：价值是被锚定的，而不是被封装的，所以不存在锚定汇率、赎回队列或托管池。双方也都不依赖一个被点名的运营者集合：真正被信任的只是两条链自己的共识，以及两个密码学对象的安全性（一个权益阈值签名和一个 SNARK），而二者都在链上被验证。任意方向的中继者都只负责活性。

这正是 RGB++ 无法做到的，原因很明确：RGB++ 的锚定链（Bitcoin）可以被"观看"，但不能"反向观看"。只要让跟随链在脚本内拥有一个能验证对方链的简洁验证器——Mithril（Cardano→CKB）和 Groth16-of-Eaglesong（CKB→Cardano）——绑定就变成双向的了。

***

## 7. 安全性

| 不变量 | 由谁保证 |
|---|---|
| 一个 seal ↔ 一个 bound cell | 锚定链上的 seal 唯一性 + bound cell 指向其 seal |
| 不会双重移动 | 锚定链共识：seal 最多只会被花费一次 |
| 新的 follower 状态就是所有者授权的状态 | 锚定链交易内的承诺（被其哈希覆盖）== H(S')，并且已被 oracle 认证 |
| 花费真实且最终确定 | oracle：Mithril 认证书 + 成员证明（→CKB），或 PoW + MMR + 包含性的 Groth16 证明（→Cardano） |
| 所有权 | seal 的花费需要锚定链上的所有者授权 |
| 重放攻击 | seal 只能被消耗一次；cell 前进到新的 outpoint；已认证状态单调前进（epoch 根 / heaviest chain） |

跨链安全面的核心就是每个方向一个 oracle。跨链健全性最终归约到该 oracle 的健全性：一个密码学 / 经济学假设（诚实权益多数，或 SNARK 健全性），而不是"请相信这 N 个运营者"。在这个归约之外，实施者还必须诚实考虑四点：

- 中继者不能伪造，只能拖延。授权承诺位于 oracle 认证的锚定链交易中；任何人都可以中继，而错误的 S' 会在条件 (4) 失败。若中继被审查，活性下降；安全性不受影响。
- 创世点是一个社会化检查点。每个轻客户端都从一个初始可信锚点开始（CKB 上的第一份 Mithril 验证密钥；Cardano 上的第一份 CKB chain-root），这与任何轻客户端一样。它是一次性的、可公开审计的参数，而不是持续存在的受信任方。
- Groth16 路径包含 trusted setup 假设。如果 setup 仪式被攻破，攻击者可能伪造 CKB→Cardano 的证明。该风险是一锤子买卖，可通过多方仪式缓解，并可用透明的（PLONK / universal-SRS）验证器彻底移除。Mithril 路径不需要 setup。
- 验证的是最终确定历史，而不是 tip。两个 oracle 只处理已 settlement 的历史（Mithril 认证快照 / 足够深的 CKB headers），因此 tip reorg 在构造上不可见，但代价是 settlement 式延迟：跟随链会按认证或确认延迟落后于锚定链，这是设计如此。

任何人都可以运行中继器，包括资产持有人本人，所以活性并不需要依赖第三方信任。

***

## 8. 后量子立场

这里我们说实话：一个协议不可能比它所连接的链更"后量子"，过度宣称没有帮助。

- 绑定核心本身已经是抗量子的。seal、承诺、header MMR、CBMT 包含性证明以及重放累加器都基于哈希（Blake2b / SHA-2 系列），Grover 只能把它们的安全性平方级削弱，靠加宽哈希位数即可，不需要新方案。
- 两个 oracle 在今天都依赖量子前假设。Mithril 的 BLS12-381 阈值签名和 Groth16 的 BLS12-381 pairing 都是如此；这与终端链自身的签名体制一致（Cardano 的 Ed25519，CKB 的 secp256k1）。因此，这个协议在签名 / pairing 层面并不是后量子的，文中也明确如此说明。
- Cardano→CKB 这一路径已有清晰的后量子升级路径，并且已经原型化。用 STARK 证明同一份 Mithril 语句，使用 FRI（只依赖哈希），因此在理论上可认为是后量子的，而且不需要 trusted setup。四个 Mithril 关系已经在真实证书上合成为一个 STARK 并完成证明；把这个证明在 CKB-VM 中验证（无论是外面再包一层 Groth16，还是用原生 FRI 验证器）仍然是剩下的、受资源约束的一步。一个更小规模的 FRI 验证器已经在 CKB-VM 上针对较小计算跑过；Mithril-STARK 的外层封装还在等待一个 ≥32 GB 的证明器。一旦完成，它就可以作为 cardano_tx_is_certified 的直接替代。Mithril 本身也在朝着 STARK 证书演进，原因相同。
- CKB→Cardano 这一路径的后量子升级要难得多，我们不会假装它很容易。Groth16 是基于 pairing 的；要换成后量子方案，意味着必须在 Cardano 上验证一个基于哈希的（FRI/STARK）证明，而目前 Cardano 只有 BLS12-381 内置，没有高效的 FRI 验证器可在脚本预算内运行。除非出现这样的原语（或者通过递归把 STARK 包装成 Cardano 能廉价验证的形式），否则这一路径的抗量子性就仍然取决于底层 pairing 假设。

总结：数据结构本身是后量子的；其中一个 oracle 已有明确的后量子路径；另一个的后量子路径仍是开放研究；而终端链的签名能力决定了整个协议的上限：协议不可能比它连接的两条链更后量子。

***

## 9. 关于 Bitcoin（与 RGB++ 的关系）

这是否涵盖了 RGB++（也就是 BTC 能不能在这里跃迁到 CKB）？可以，而且严格来说只是在 RGB++ 的意义上可以。Bitcoin 可以作为锚定链：CKB 在其上运行 Bitcoin SPV 轻客户端作为 oracle，价值可以在 BTC ⇄ CKB 间双向 leap，因为回到 Bitcoin 的 leap-out（§3.3）只是一次普通的 Bitcoin 花费，由跟随链观察即可，并不要求 Bitcoin 验证 CKB。

但 Bitcoin 不能承载 Oracle B：它无法在脚本内验证 CKB 共识，所以"CKB 锚定、Bitcoin 跟随"这条路径是不可能的。Bitcoin 因而是一个单向锚定链：它可以做锚定者（CKB 跟随），却永远不能做跟随者。这个性质也适用于其他 PoW UTXO 链（LTC、DOGE）——它们都只能作为 anchor-only。真正的双向、彼此验证的拓扑需要一个能在链上检查简洁证明的跟随链，因此我们先选择了 Cardano（Plutus + BLS12-381），而不是 Bitcoin。

所以，BTC↔CKB 的 leap 作为 RGB++ 的退化情况是继承来的；而这篇协议新增的是对称情况——Bitcoin 无法做到，而 Cardano 可以证明这一点。

***

## 10. 通用化：与锚定链无关的绑定

由于只有 oracle 是方向相关的，给任意链 X 增加支持，归根结底只是编写对应的 oracle：

- X 作为锚定链、CKB 跟随：需要一个在 CKB-VM 里的 X 轻客户端 oracle。对于像 Bitcoin 家族这种可做 SPV 的链，这很便宜；对于 Cardano，则需要 Mithril / ZK 验证器。
- CKB 作为锚定链、X 跟随：需要在 X 上验证 CKB 共识。若 X 天然支持 Groth16 内置，这很容易；若 X 有 BLS12-381 原语，则还算可行；若 X 没有链内验证能力（如 Bitcoin），则不可能，只能作为 anchor-only。

绑定构造（§3）本身不会变化。能同时"被观察"又能"反向验证"的链，会成为一等公民式、对称的对手方；只能被观察的链，则会成为 RGB++ 传统里的 anchor-only 对手方。

***

## 11. 终局：对称且都简洁

今天这两个 oracle 在"种类"上不同：一个是权益阈值签名，另一个是 SNARK。真正最小信任的终局，是把 Mithril 换成一个 Ouroboros Praos 的 ZK 证明，接口保持不变（目前已用对 Mithril 语句的 STARK 原型化），并用通用 SRS 的 PLONK 验证器来消除 Groth16 的 trusted setup。最终目标是：

> 一个完全双向、与锚定链无关、无委员会的协议，其中每条链都只用一个简洁证明来验证另一条链，而同构绑定构造在两边保持不变：同一个绑定，两个 oracle，二者都很简洁。

RGB++ 证明了一条链可以通过在脚本内运行轻客户端，成为另一条链的验证层。本工作表明：当两条链都能做到这一点时，绑定就变成对称的，而协议最终只需要信任两条链本身。