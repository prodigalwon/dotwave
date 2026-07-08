# dotwave app-polish docket

Running list for the `app-polish-v0` worktree. Newest items on top.

---

## [ ] Messages banner: add "needs chat cert" state + "all set" affirmation

**Problem.** The Messages banner state machine (`ChatKeyState` in
`lib/services/chat_store.dart`) is `noName → needsKeys → ready`, where `ready`
is derived *only* from published records (`chatResolveIdentity`: CHAT + MESSAGE
+ SEAL live). But publishing records is not sufficient to actually send: the
user still needs a **chat-EKU'd zkpki cert** to drop onion blobs (admission is
gated on an Active chat-EKU cert). So a user can complete "Register Name" and
"Register Keys", see a "ready / Message Options" banner, and still fail to send.

**Desired flow (banner, in order):**
1. `noName`   → "Register a .rst name" (unchanged).
2. `needsKeys` → "Register Keys" — publish CHAT/MESSAGE/SEAL/PREKEY (unchanged).
3. `needsCert` → **NEW.** Name + records live, but no Active chat-EKU cert.
   Banner tells the user they need a chat cert and CTAs to mint one.
4. `ready`     → **all set.** Show the user's name (e.g. `anthony`) with a
   checkmark next to it. (Keep access to Message Options / rotate somewhere,
   but the banner's job here is the "you're all set" affirmation, not a CTA.)

**Wiring notes (from code read):**
- Add `needsCert` to the `ChatKeyState` enum.
- `ChatStore.keyState()` currently returns `ready` when
  `found && ed25519 && hasMessageKey && hasSealKey`. Extend it to also check
  for an Active chat-EKU cert before returning `ready`; otherwise `needsCert`.
  - Cert existence: `certAuth(address)` (local thumbprint, may be stale) vs
    `chatFetchCertThumbprint` (on-chain Active — authoritative but needs node).
  - **Offline nuance** (same principle as the name-drift fix): don't *demote*
    to `needsCert` just because the node is unreachable. Only assert
    `needsCert` when we can positively determine there is no Active cert. When
    offline, hold the last-known state / trust the local cert thumbprint.
- `_KeyStateBanner` in `lib/screens/messages_tab.dart` (~line 601 switch): add
  the `needsCert` arm (icon/title/subtitle/color/primary) and restyle the
  `ready` arm to render "<name> ✓ · You're all set".
- `_onBannerAction` (messages_tab.dart ~125): add the `needsCert` case →
  mint-cert flow (`ensureCert` / `chatMintCertStreamed` in a paid blade, same
  pattern as Register Keys).

**Open question for pickup:** is minting the chat cert a separate paid blade,
or should "Register Keys" mint the cert in the same ceremony (it already calls
`ensureCert` per chat_store.dart:559)? If keys+cert already mint together, the
`needsCert` state is mostly a *recovery* affordance for when the cert mint
failed/expired — worth confirming on-device before building the UI.

**Scope note (2026-07-08):** this banner is a client-side UX affordance ONLY,
not a security gate. Node-side trace confirmed the guard admits onion drops on
`cert_state == Active` alone (`gemini-node/src/chat_rpc.rs:780`/`:952`) and
never checks the ChatAuth EKU — so a modified client can skip the banner and
still send. Enforcing the chat-EKU charter at the guard is a **separate Rostro
chain-side workstream** (parked; not in this worktree). The high-value part
here is the **"all set" affirmation** (name + checkmark once records + cert are
present), which is honest UX regardless of the node gap.
