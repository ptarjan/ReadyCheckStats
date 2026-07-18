# Changelog

## 1.2.7
- Group filter buttons are now ordered by how often you raid with each group, so your usual group comes first
- When there are more groups than fit on the row, scroll through them with the mouse wheel
- The "Wasted" column is now "Raid-time" — it always measured everyone's time combined (your delay times the number of people kept waiting), which is why it could reach hours; now the name says so
- Fixed inflated raid-time: players who typed "r" after a failed check were being charged all the way until the pull, even if the raid leader waited minutes to pull — they're now only charged until they said "r"
- New always-on event log records every stat change as it happens; type /rcs audit any time to have the addon re-add everything up from scratch and confirm the displayed numbers match — if they ever don't, it tells you exactly which number is wrong
- Group filters now show only what happened with that group — previously a player's full all-time numbers appeared under every group they'd ever raided with, so one night with another group dragged in their whole record. Existing totals are split across groups based on how many nights you've recorded together; new nights are tracked per group exactly

## 1.2.6
- Ready for WoW 12.1.0

## 1.2.5
- Typing "r" (or "rdy", "back", etc.) while the ready check is still running now counts — you no longer have to say it again after the check ends
- If everyone who missed the check already said "r" during it, the "Everyone's ready — pull!" ding fires the moment the check ends

## 1.2.4
- Fix: typing "r" in chat now clears people who clicked "Not Ready" and plays the ready ding when everyone's back (previously only worked for people who never clicked anything)
- Fix: error when clicking Yes on the reset confirmation in the stats window
- Fix: a Ready click could occasionally be miscounted as Not Ready
- Fix: one of the perfect-check cheer messages showed a stray "%" sign
- Fix: the stats window no longer slowly uses more memory the longer it stays open during a raid
- Update for WoW 12.0.7

## 1.2.3
- Make the "Everyone's ready — pull!" message bright green so it's harder to miss in chat

## 1.2.2
- Update for WoW 12.0.5
- Chat trigger "b" now also means back

## 1.2.1
- Remove individual "X said ready in chat" messages — only shows "Everyone's ready — pull!"
- Auto-clean bogus data entries on load (blank names, timeout-bugged stats)

## 1.2.0
- Fix fail% sorting — now sorts by actual percentage, not count
- Fix fail% sometimes showing over 100%
- Fix duplicate group names in filters
- UI updates in real-time as people click ready

## 1.1.1
- Fix fail% sorting — now sorts by actual percentage, not count
- Fix fail% sometimes showing over 100%
- Fix duplicate group names in filters
- UI updates in real-time as people click ready

## 1.1.0
- Players waiting on others are marked ready when a pull timer starts or combat begins
- Chat detection for "r", "rdy", "ready", "here", "back" (word boundaries only)
- Group filter buttons on the All-Time tab
- 5-minute timeout if no pull happens after a ready check
- Group label auto-detected from raid leader's guild

## 1.0.0
- Initial release
- Ready check tracking with response times
- Tonight and All-Time leaderboards
- MVP and shame announcements
- Trend comparison across raid nights
