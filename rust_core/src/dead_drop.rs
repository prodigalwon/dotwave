//! Dead-drop ping-pong rotation state (Phase 3).
//!
//! Pure logic, no I/O and no randomness: the caller mints return addresses
//! (random 32-byte pickup keys via `OsRng`) and drives send/poll; this
//! module owns ONLY the rotation and the 3-round grace window, so it is
//! deterministic and unit-testable. The app persists a [`DeadDropThread`]
//! per conversation and a [`CallsignPool`] of standing callsigns.
//!
//! Two label classes (see `docs/DOTWAVE-CHAT-DEAD-DROPS.md`):
//!   * standing callsigns — manual, ≤[`MAX_CALLSIGNS`], the front door;
//!   * return addresses — auto, ephemeral, rotated per turn, with a grace
//!     window so a late reply to a just-superseded address still lands.

/// Rounds a superseded inbound return address is still polled before it is
/// dropped — catches late/in-flight replies the peer sent before learning
/// the rotation.
pub const GRACE_ROUNDS: u8 = 3;

/// Max standing callsigns a user may poll concurrently. Return addresses
/// are a SEPARATE, app-managed pool and do not count against this.
pub const MAX_CALLSIGNS: usize = 10;

/// A 32-byte pickup key (a routing bucket — never key material).
pub type Pickup = [u8; 32];

/// One conversation's ping-pong rotation state. Plain data the app
/// persists per thread.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeadDropThread {
    /// Where THIS party sends its next message. The opener's target is
    /// `for_deaddrop(callsign)`; thereafter it is the peer's latest return
    /// address. `None` for a responder that has not yet received.
    pub outbound_target: Option<Pickup>,
    /// The return address THIS party currently advertises (its inbound).
    /// `None` for a responder before its first received message.
    pub inbound_current: Option<Pickup>,
    /// Superseded inbound addresses still being polled, with rounds left.
    pub grace: Vec<(Pickup, u8)>,
}

impl DeadDropThread {
    /// Opener (Alice): address a callsign bucket, advertising a freshly
    /// minted inbound `first_inbound`. The callsign bucket itself never
    /// receives more than this one opening message — every reply rides the
    /// rotating return addresses.
    pub fn open(callsign_pickup: Pickup, first_inbound: Pickup) -> Self {
        Self {
            outbound_target: Some(callsign_pickup),
            inbound_current: Some(first_inbound),
            grace: Vec::new(),
        }
    }

    /// Responder (Bob): empty until its first received message initialises
    /// it via [`Self::on_turn`].
    pub fn responder() -> Self {
        Self { outbound_target: None, inbound_current: None, grace: Vec::new() }
    }

    /// A receive→send turn transition. The peer responded with
    /// `received_return` (their new inbound, learned from the message's
    /// `return_pickup`); adopt it as the new outbound target, age the grace
    /// window by one round, retire the just-superseded inbound into it, and
    /// advertise `new_inbound` (caller-minted) going forward.
    ///
    /// Within a burst (several sends before the peer replies) the caller
    /// does NOT call this — target and inbound stay put; rotation happens
    /// once per turn, on the peer's reply.
    pub fn on_turn(&mut self, received_return: Pickup, new_inbound: Pickup) {
        // Age existing grace entries; drop the expired.
        self.grace.retain_mut(|(_, left)| {
            *left = left.saturating_sub(1);
            *left > 0
        });
        // Retire the just-superseded inbound into a fresh grace window.
        if let Some(old) = self.inbound_current.take() {
            self.grace.push((old, GRACE_ROUNDS));
        }
        self.inbound_current = Some(new_inbound);
        self.outbound_target = Some(received_return);
    }

    /// Every bucket THIS party must poll for replies: the current inbound
    /// plus every live grace address. (Callsign polling is the separate
    /// standing pool, not per-thread.)
    pub fn poll_set(&self) -> Vec<Pickup> {
        let mut set = Vec::new();
        if let Some(cur) = self.inbound_current {
            set.push(cur);
        }
        set.extend(self.grace.iter().map(|(p, _)| *p));
        set
    }
}

/// The standing-callsign watch list, capped at [`MAX_CALLSIGNS`]. Stores
/// the human/random label strings; the poll bucket is `for_deaddrop(label)`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CallsignPool {
    labels: Vec<String>,
}

impl CallsignPool {
    pub fn new() -> Self {
        Self { labels: Vec::new() }
    }

    /// Add a callsign. Idempotent; errors at the [`MAX_CALLSIGNS`] cap
    /// (a hard cutover, never a silent drop).
    pub fn add(&mut self, label: String) -> Result<(), String> {
        if self.labels.contains(&label) {
            return Ok(());
        }
        if self.labels.len() >= MAX_CALLSIGNS {
            return Err(format!("callsign pool is full ({MAX_CALLSIGNS} max); remove one first"));
        }
        self.labels.push(label);
        Ok(())
    }

    pub fn remove(&mut self, label: &str) {
        self.labels.retain(|l| l != label);
    }

    pub fn labels(&self) -> &[String] {
        &self.labels
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(n: u8) -> Pickup {
        [n; 32]
    }

    #[test]
    fn opener_addresses_callsign_and_advertises_first_inbound() {
        let t = DeadDropThread::open(p(0xca), p(1));
        assert_eq!(t.outbound_target, Some(p(0xca)));
        assert_eq!(t.inbound_current, Some(p(1)));
        assert_eq!(t.poll_set(), vec![p(1)]);
        assert!(t.grace.is_empty());
    }

    #[test]
    fn responder_initialises_on_first_turn_without_grace() {
        // Bob: empty, then receives the opener advertising A1 (=p(1)) and
        // mints B1 (=p(10)). No prior inbound → nothing enters grace.
        let mut bob = DeadDropThread::responder();
        assert!(bob.poll_set().is_empty());
        bob.on_turn(p(1), p(10));
        assert_eq!(bob.outbound_target, Some(p(1)));
        assert_eq!(bob.inbound_current, Some(p(10)));
        assert!(bob.grace.is_empty());
        assert_eq!(bob.poll_set(), vec![p(10)]);
    }

    #[test]
    fn turn_rotates_inbound_and_retires_old_into_grace() {
        let mut a = DeadDropThread::open(p(0xca), p(1)); // advertises A1=1
        a.on_turn(p(10), p(2)); // peer replied (B1=10); mint A2=2
        assert_eq!(a.outbound_target, Some(p(10)));
        assert_eq!(a.inbound_current, Some(p(2)));
        // A1 retired into grace; poll set = current + grace.
        assert_eq!(a.grace, vec![(p(1), GRACE_ROUNDS)]);
        assert_eq!(a.poll_set(), vec![p(2), p(1)]);
    }

    #[test]
    fn grace_address_is_polled_for_exactly_three_rounds_then_dropped() {
        let mut a = DeadDropThread::open(p(0xca), p(1));
        // Turn 1 retires A1(=1) with 3 rounds.
        a.on_turn(p(101), p(2));
        assert!(a.poll_set().contains(&p(1)), "round 1: A1 live");
        // Turn 2.
        a.on_turn(p(102), p(3));
        assert!(a.poll_set().contains(&p(1)), "round 2: A1 live");
        // Turn 3.
        a.on_turn(p(103), p(4));
        assert!(a.poll_set().contains(&p(1)), "round 3: A1 live");
        // Turn 4: A1 has now aged out.
        a.on_turn(p(104), p(5));
        assert!(!a.poll_set().contains(&p(1)), "round 4: A1 dropped after 3-round grace");
    }

    #[test]
    fn callsign_pool_caps_at_max_and_is_idempotent() {
        let mut pool = CallsignPool::new();
        for i in 0..MAX_CALLSIGNS {
            pool.add(format!("cs{i}")).unwrap();
        }
        assert_eq!(pool.labels().len(), MAX_CALLSIGNS);
        // Idempotent re-add does not grow or error.
        pool.add("cs0".to_string()).unwrap();
        assert_eq!(pool.labels().len(), MAX_CALLSIGNS);
        // One past the cap errors.
        assert!(pool.add("overflow".to_string()).is_err());
        // Removing frees a slot.
        pool.remove("cs0");
        assert!(pool.add("overflow".to_string()).is_ok());
    }
}
