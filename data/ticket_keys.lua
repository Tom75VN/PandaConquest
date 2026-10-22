PandaConquest = PandaConquest or {}

-- Public keys of the Worker's membership ticket signatures (decision 0061),
-- by key id. Public on purpose: they only verify. Written by the companion
-- repository's worker/scripts/ticket-key.mjs, at most two at a time (rotation).
-- Empty: no ticket can be verified yet, every player stays unverified, nobody
-- is blocked (OBSERVE mode).
PandaConquest.TicketKeys = {
  schema = 1,
  keys = {
  },
}
