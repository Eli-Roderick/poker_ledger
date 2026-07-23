# Poker Ledger — Complete Product Overview

A deep, feature-first tour of what the app is, what people can do in it, how they move through it, and how it feels to use.

---

## 1. What Poker Ledger Is

**Poker Ledger** is a private, account-based cash-game ledger for home poker nights. It is not a public poker network, not a table finder, and not a place where strangers browse games. It is the shared notebook your group uses when everyone buys in, rebuys, cashes out, and needs a clear answer to: *who owes whom?*

The product promise, in the app’s own words:

- Auth: *“Track buy-ins, cash-outs, and settlements with your group.”*
- Home: *“Your next required action, without the guesswork.”*
- Games empty state: *“Start a new game to track buy-ins, cash-outs, and who owes who at the end.”*

### What it optimizes for

1. **Clarity at the end of the night** — balanced books and concrete settlement instructions.
2. **Consent and privacy** — nobody becomes a player or appears in search without choosing to.
3. **Shared truth for a group** — one ledger, visible to the people who should see it.
4. **Auditability** — once a game is finalized, history is locked; fixes create new revisions with reasons.

### What it deliberately is *not*

- A public social network or “find a game nearby” product.
- An email-search directory (handles only; email is never searchable).
- A place where hosts invent silent “ghost” players for new games without consent.
- A follow/feed system (following was removed; visibility comes from shared games and groups).

---

## 2. The Shape of the App (UI Shell)

After you are signed in and set up, Poker Ledger is a five-tab app:

| Tab | Purpose |
|-----|---------|
| **Home** | “What should I do next?” — continue the active game, review invites, read notifications |
| **Games** | Create lobbies, join by code, accept invites, browse hosted/joined history |
| **Stats** | Personal and group numbers, top players, game lists, CSV export |
| **Groups** | Create crews, invite members, standings, attach games to a shared circle |
| **Profile** | Your identity, personal stats, settings, sign out |

### How the UI feels

- **Material Design 3** look: clean cards, rounded inputs (about 12px corners), floating snackbars with a close action.
- **Brand color**: teal seed (`#0E7C7B`) with a warm orange accent (`#EF6C00`) for emphasis.
- **Light / dark / system** themes (default follows the device).
- **Money language**: greens and reds for profit and loss; amounts shown as dollars in the UI.
- **Responsive layout**:
  - Phones / narrow windows: bottom **NavigationBar**
  - Wider (≥800px, e.g. web/desktop): side **NavigationRail** with labels
- Tabs stay “warm” (kept in memory) so switching Home ↔ Games ↔ Stats feels instant; Games and Stats refresh when you open them.
- Contextual **?** help buttons open short, screen-specific explainers — not a marketing site.

There is no separate marketing homepage inside the app. The product voice lives in the empty states, phase labels, dialogs, and help pages.

---

## 3. Getting In: Accounts, Identity, and First Run

### 3.1 Sign in / Create account

You land on a single auth entry with a segmented control: **Sign in** vs **Create account** (the app remembers which you used last).

- Email + password.
- Create account also confirms the password and sets expectations: *you will choose display name, unique handle, and invitation discoverability next.*
- Forgot password sends a reset email; recovery deep link: `io.supabase.pokerledger://reset-password`.

### 3.2 Finish your profile (required)

Before the main app opens, every new account hits **Finish your profile**:

- **Display name** — how you appear to others in games.
- **Unique handle** — `@something`, 3–24 characters, letters/numbers/underscore. This is how people invite you.
- **Allow invitation search** — optional discoverability. Off by default. When on, others can find you by handle/display name for invites. Email is never shown in search.

Until the handle is set, you cannot enter the main shell.

### 3.3 Getting started checklist (soft onboarding)

**Getting started / Your first poker ledger** walks through milestones that unlock as you actually use the product:

1. Complete profile  
2. Accept or invite a player  
3. Start a game  
4. Finalize a balanced ledger  

You can **Skip** or finish and **Open Poker Ledger**. Completing/skipping marks the tutorial done. You can restart it later from Settings → **App Tutorial**.

### 3.4 Other gates you might see

- **Local migration** — if an older on-device database is found, a migration screen offers to bring data to the cloud or skip.
- **Maintenance mode** — non-admins see an “Under Development” style screen and can only sign out. Admins can toggle this in Settings.
- **Backend compatibility** — if the client and server contract don’t match, you get an update/verify screen with **Try again** rather than a half-broken app.

---

## 4. Home — “What do I do next?”

Home is deliberately not a dashboard full of charts. It is an action inbox.

At the top:

- Big **Poker Ledger** title  
- Subtitle: *Your next required action, without the guesswork.*

Then a primary action card, for example:

- **Start your next game** → jumps to Games (when nothing is active)
- **Continue** on your most recent unfinished game, with a phase-aware subtitle such as:
  - Draft · finish the lobby…
  - Live · record rebuys…
  - Settlement ready…
  - Host unavailable · read-only…
  - Legacy game · continue setup…
- Or an error card if games failed to load

Below that, when relevant:

- Pending **game invitations** (accepting is required before a game affects stats)
- Pending **group invitations**
- Unread **notifications** (title/body; tap may open a related game; can mark read)

Pull-to-refresh reloads games, invites, and notifications.

**UI vibe:** sparse, card-forward, one hero decision at a time.

---

## 5. Games — The Heart of the Product

### 5.1 Games list

The Games tab is your library of poker nights:

- Filters for **hosted / joined**, status, and date
- Badges / entry points for invitations and join codes
- Empty state that nudges you to start tracking buy-ins and who owes whom
- App-bar actions to enter a join code or review invites

Opening a game routes you into either:

- The modern **V2 guided flow** (Lobby → Mode → Live → Summary), or  
- A **legacy** wizard/summary for older unfinished or historical games

### 5.2 Creating a new game (V2)

**New poker game** dialog asks:

- Game name (optional)
- Visibility: **Private** *or* attached to **exactly one group**
- Default buy-in (dollars)
- **I am playing** toggle (host may or may not sit in the game)

CTA: **Create lobby**

Creation is server-gated. If the new-game flow is not enabled for the account, you see **New game flow unavailable** — existing games still open, but you cannot start a new V2 lobby yet.

### 5.3 The V2 journey (the main experience)

Progress is shown as four steps: **Lobby → Mode → Live → Summary**.

#### Lobby — build the table with consent

Host sees:

- Accepted players list (display names; backup host can be marked)
- Join requests waiting for approval
- Outgoing invitations still pending
- Actions: **Invite by handle**, **Generate code**
- Guidance: need at least two accepted players before continuing

Copy for hosts: invite account-backed players; everyone explicitly accepts before joining. Non-hosts wait for the host.

**Invite by handle**

- Search discoverable people by handle/display name
- Send invitation
- Invitee must accept before they become a participant or affect stats

**Join codes**

- Host generates a short-lived code (about **2 hours**)
- Can share via system share sheet with a friendly message + deep link  
  (`io.supabase.pokerledger://join/{code}`)
- Regenerating a code invalidates the previous one (confirm dialog)
- Someone entering a code creates a **join request**; the host still approves

**Backup host**

- Host can assign a backup among accepted players so the game is not stranded if the host disappears

#### Mode — how money settles (required checkpoint)

Before any buy-in is recorded, the host must choose:

- **Pairwise** — a small set of direct payments between players  
- **Banker** — every payment goes through one selected player  

For banker mode, the host also picks the banker and can mark who **already paid the banker** before the game started.

CTA: **Start live game**

This checkpoint exists so settlement rules are agreed *before* chips move in the ledger.

#### Live — the night is running

- Initial buy-ins are recorded when the game starts
- Host records **rebuys** as they happen (per player, amount)
- Host can still invite / share codes for late joiners (within rules)
- Host can **reverse** a mistaken ledger entry with a required reason
- Non-hosts mostly review and pull-to-refresh
- Host ends the night with **End game & enter cash-outs**

#### Summary / Settling — cash out and balance

- Enter each player’s cash-out
- UI calls out missing cash-outs and balance mismatches
- Shows **proposed transfers** once books can balance
- Host can **Return to live** with a reason (e.g. missed rebuy) if settlement was started too early
- When balanced: **Finalize** — confirms that the ledger and settlement become an auditable revision; later fixes need a new revision and a reason

#### After finalize

Players and host can:

- Share a summary
- Export **audit CSV**
- Export **PDF**
- **Correct finalized game** — pick events to reverse/replace, enter reason, keep projected books balanced
- Update settlement transfer status:
  - Payer: **Mark paid**
  - Recipient: **Confirm received**
  - Either party: **Dispute** (when allowed)

Transfers are not casual checkboxes; they are the lasting “who owes whom” record for that revision.

### 5.4 Joining a game (player side)

Paths into a game:

1. Games → enter join code  
2. Accept a host invitation from the invitations sheet / Home card  
3. Open a shared deep link with a code  

Possible outcomes after a code: request sent, already invited, already participating, invalid/expired, or game no longer accepting players.

Until you accept (and the host accepts a join request when needed), you are **not** a player and the game does **not** affect your stats.

### 5.5 Canceling and host-unavailable states

- Host can **cancel** an open V2 game with a reason (audit-friendly; not a silent delete).
- If the host becomes unavailable, Home/Games can surface **read-only / host unavailable** states so participants are not left guessing.

### 5.6 Legacy games (still present, no longer the main create path)

Older games still open in the app:

- Unfinished hosted legacy games continue in a **Game setup wizard** (players → settlement mode → summary/cash-outs)
- Finalized or non-owned legacy games open in a **session summary**
- Hosts can rename/delete unfinished legacy games in some cases
- Guest/local-style player names remain as **historical snapshots**
- Private **quick-add notes** on legacy player detail never change standings or canonical stats

When V2 creation is available, the app does **not** offer creating brand-new legacy games — legacy is history and cleanup, not the future path.

---

## 6. Groups — Shared Crews and Shared Ledgers

Groups are how a regular poker circle shares a long-running record.

### 6.1 Groups list

- Create a group (name like “College Friends”)
- See member counts, **Owner** badge, **Archived** chip
- Mail icon for **group invitations**
- Empty state explains that groups exist so games can be shared with a crew

Accepting a group invite includes an important privacy note: members can see the **full ledgers of group games**, including games that happened before you joined.

### 6.2 Group detail (three tabs)

**Members**

- Who’s in, who owns, who can manage games
- Owner / game-admin tools: invite by handle, remove members, grant/revoke **Game admin**
- Non-owners can **Leave group**
- Owners cannot casually abandon ownership via Leave — they must transfer first

**Games**

- Games attached to this group
- Open into V2 flow or legacy summary depending on the game

**Standings**

- Rankings / net after finalized group games exist
- Empty until there is finalized group history

### 6.3 Roles (in plain language)

| Role | Can typically… |
|------|----------------|
| **Owner** | Rename, transfer ownership, archive, invite, remove members, grant game admins |
| **Game admin** | Invite, help manage membership/game attachment privileges |
| **Member** | See members, games, standings; leave |

After ownership transfer, the former owner stays as an administrator so the group is not left without experienced managers.

### 6.4 Archive vs delete

Groups with history are **archived**, not casually wiped:

- History and standings remain readable
- New games, invitations, and membership changes lock down
- Members can still leave an archived group

### 6.5 How groups interact with games

- A new game is either **private** or attached to **exactly one group** at creation
- Current accepted members of that group can see that game’s full ledger
- Leaving a group removes group-only access, but **does not erase** games you personally played
- Personal Stats and Group Stats are different scopes of the same finalized truth

---

## 7. Stats — Personal and Group Numbers

The **Stats** tab (analytics) answers: *How am I doing? How is the crew doing?*

### Scope

- **My Games** — every finalized game you accepted (hosted or joined)
- Or pick a **specific group** — standings for games attached to that group

### What you see

- KPI strip: Games, Players, Net Total (and related personal metrics elsewhere)
- **Top players** leaderboard
- Full players sheet with sort options (net gain/loss, sessions, max win/loss)
- List of games → open the game’s V2 or legacy summary
- Date filters
- **Export CSV** using the same canonical totals shown on screen

Empty states nudge you to finalize games or attach games to groups so standings have something to show.

### Opening people from Stats

- Linked accounts → **User profile** (mutual participation / mutual groups, filters, history)
- Legacy guest names → **Player detail** with summary, game nets, and private quick-adds

There is **no dedicated Players tab**. People are reached through Stats, games, and groups.

---

## 8. Profile, Settings, Privacy, and Account Lifecycle

### 8.1 Profile tab

- Avatar / display name / @handle / email / member since
- Personal stats snapshot: Games, Net, Win rate
- Note that history lives under Games
- Help (?) and Settings in the app bar
- **Sign out** with confirmation

### 8.2 Settings

- **Appearance → Theme**: System / Light / Dark  
- **Privacy → Discoverable profile**: toggle + explanation that discoverability is for invitations by handle; join codes and groups still work when you’re not discoverable  
- **Help → App Tutorial**: reopen onboarding checklist  
- **Account → Delete Account**: 30-day retention warning  
- **Admin** (admins only): Maintenance Mode toggle  

### 8.3 Discoverability (important product rule)

Default: **not discoverable**.

- Off: people generally need a join code, a direct path, or an existing relationship/group path — you are not in open invitation search.
- On: hosts/managers can find you by handle/display name to invite you to games or groups.
- Email is never a search key.

### 8.4 Delete and restore

**Delete**

1. Transfer ownership of every group you own first (app blocks deletion that would orphan groups).
2. Confirm deletion in Settings.
3. Account enters a scheduled deletion window (~30 days).
4. You are signed out; sign-in is disabled in the normal sense until restore.

**Restore**

1. Within the window, sign in with the same email/password.
2. If the account is in the deletion window, Sign in shows a restore banner with time remaining.
3. **Restore Account** brings the profile back and reconnects safe memberships.

Open games during deletion lean on backup hosts / group authority; private open games may become read-only so money history is not casually rewritten while the host is gone.

---

## 9. Notifications and “Things Waiting on You”

Poker Ledger avoids a giant social inbox. Instead:

- **Home** surfaces unread notifications and invite counts
- **Games** has invitation review / join-code entry
- **Groups** has group-invitation review
- Notification cards can deep-link into a relevant game

The mental model is: *actionable waiting items*, not a feed.

---

## 10. Help System

Almost every major surface has a **?** that opens a short help page with a title, paragraph, and bullet tips. Examples of the product vocabulary taught there:

- Games live in Lobby / Mode / Live / Summary phases  
- Finalized ledgers are locked; corrections create a new audit revision  
- Invite by handle or short-lived join code; acceptance is required  
- Groups share full ledgers with current members  
- Stats only use finalized, accepted participation  
- Legacy player lists exist for history and private notes, not for new-game rostering  

---

## 11. End-to-End User Flows

### Flow A — Brand-new player’s first night (hosted by a friend)

1. Create account → Finish profile (choose whether to be discoverable)  
2. Optionally skim Getting started, or Skip  
3. Home shows game invitation card **or** friend shares a join code  
4. Accept invite / enter code → wait for host approval if needed  
5. Appear in Lobby; after host starts, follow Live → Summary  
6. After finalize, if you owe or are owed money, mark paid / confirm received  
7. Later, check **Stats → My Games** for the night’s impact on your net  

### Flow B — You host a private game

1. Games → New Game → Private → set buy-in → Create lobby  
2. Invite two friends by handle (they must be discoverable) and/or share a join code  
3. Approve join requests; optionally set a backup host  
4. When ≥2 accepted → Mode → Pairwise or Banker → Start live game  
5. Record rebuys during the night  
6. End game → enter cash-outs until balanced → Finalize  
7. Share summary / export; chase settlement statuses over the next days  
8. If you made a bookkeeping mistake after finalize → Correct finalized game with a reason  

### Flow C — You host a group night for your regular crew

1. Groups → Create “Thursday Night” → invite members by handle  
2. Members accept (understanding they can see group game ledgers)  
3. Games → New Game → attach that group → Create lobby  
4. Same Lobby → Mode → Live → Summary flow  
5. After several finalized nights, Group → Standings and Stats → that group show the season picture  

### Flow D — Join with only a code (not discoverable)

1. Keep discoverability off in Settings  
2. Friend texts you a code / deep link  
3. Games → enter code → request sent  
4. Host approves → you are in  
5. You never needed to be searchable  

### Flow E — Manage a group as owner

1. Invite members; promote a trusted person to Game admin  
2. Let admins help attach/create group games  
3. When you leave the city, Transfer Ownership to a current member  
4. You remain an admin; they become owner  
5. Or Archive the group when the crew is done adding new nights  

### Flow F — Delete your account safely

1. Transfer every owned group  
2. Settings → Delete Account → confirm  
3. Signed out; 30-day restore window  
4. Change your mind → Sign in → Restore Account  

### Flow G — Returning legacy host

1. Home or Games shows an unfinished legacy game  
2. Continue in the old wizard (players / mode / cash-outs)  
3. Finalize or clean up  
4. New nights are created as V2 lobbies (when enrollment allows), not as new legacy games  

---

## 12. Money Model (In Human Terms)

Without diving into database design, this is the mental model the UI teaches:

1. **Buy-ins and rebuys** put money into the pot record.  
2. **Cash-outs** record what each person left with.  
3. The night must **balance** (money in equals money out, in ledger terms).  
4. **Settlement mode** decides the shape of repayments:
   - Pairwise: fewer direct edges between winners and losers  
   - Banker: everyone settles through one person  
5. **Finalize** freezes that night as a revision.  
6. **Transfers** are the actionable IOUs from that revision.  
7. **Corrections** don’t rewrite the past quietly — they append a new revision with a reason.

Names shown in history are **snapshots** from the night they were accepted, so later profile renames do not rewrite old box scores.

---

## 13. Privacy and Trust Rules (Product Principles)

These rules show up everywhere in copy and flows:

1. **Consent before participation** — invitation accept / host approve join request.  
2. **Opt-in discoverability** — search is a privilege you enable, not a default.  
3. **No email search** — identity for invites is the handle.  
4. **Private vs one group** — no multi-group fog for a single game.  
5. **Group membership sees full group ledgers** — join a group with eyes open.  
6. **Leave removes future access, not your played history.**  
7. **Finalized means locked; corrections are explicit.**  
8. **Private notes (quick adds) never rewrite standings.**  

---

## 14. UI Map by Screen (What You See)

| Screen | What it looks / feels like |
|--------|----------------------------|
| Auth entry | Brand mark, Sign in / Create account toggle, simple forms |
| Profile setup | Short form + discoverability switch; “how players find you” |
| Onboarding checklist | Milestone list with Skip / Open Poker Ledger |
| Home | Headline + one big continue/start card + invite/notification cards |
| Games list | Filterable list, FABs/actions for new game / join / invites |
| V2 game flow | Stepper/progress, phase-specific lists and primary CTAs, dialogs for money actions |
| Legacy wizard / summary | Older multi-step setup or read-only/final summary |
| Stats | Scope dropdown, KPI chips, leaderboards, game rows, export |
| Groups list | Cards/tiles with owner/archived cues; create + invites |
| Group detail | Tabbed Members / Games / Standings; owner overflow menu |
| User profile / history | Another person’s visible stats and shared history |
| Legacy player detail | Guest/history-focused; quick-add private notes |
| Profile | Identity header + personal KPIs + sign out |
| Settings | Grouped lists: theme, privacy, tutorial, delete, admin |
| Help | Title, paragraph, bullet tips |
| Maintenance / contract | Blocking status screens with limited actions |

---

## 15. Feature Inventory (Checklist)

### Always-on product surfaces

- [x] Email/password auth, password reset  
- [x] Profile setup (name, handle, discoverability)  
- [x] Soft onboarding checklist  
- [x] Five-tab shell (Home, Games, Stats, Groups, Profile)  
- [x] Home next-action + invites + notifications  
- [x] V2 game lifecycle (lobby, mode, live, settle, finalize)  
- [x] Handle invites + join codes + deep links  
- [x] Backup host  
- [x] Rebuys, cash-outs, reversals with reasons  
- [x] Pairwise and banker settlement  
- [x] Transfer paid / received / dispute  
- [x] Finalization revisions + corrections  
- [x] Share / CSV / PDF exports  
- [x] Groups with roles, invites, archive, transfer ownership  
- [x] Personal and group stats + CSV  
- [x] Theme modes  
- [x] Contextual help  
- [x] Account delete + restore window  
- [x] Legacy game viewing / unfinished legacy continuation  

### Gated or conditional

- [ ] **V2 game creation** — only if the server says the new flow is available for that account  
- [ ] **Discoverability** — user opt-in  
- [ ] **Admin maintenance toggle** — admins only  
- [ ] **Local→cloud migration** — only if old local data exists  

### Intentionally absent / retired

- Follow / social feed  
- Dedicated Players hub tab  
- Creating new legacy-style games when V2 is available  
- Public browse-anyone directory  

---

## 16. How a Typical Month Feels

Monday: create or reopen your Thursday group, invite a new friend who opted into discoverability.  
Thursday: host creates a group-attached lobby, shares a code for the one person who keeps discoverability off, starts pairwise mode, records two rebuys, finalizes, exports PDF for the group chat.  
Friday: people mark transfers paid/received from Home/notifications or the game summary.  
Sunday: Stats → group standings shows who’s up and who’s down for the month.  
Later: someone notices a wrong rebuy — host runs a correction revision with a reason; old revision stays in the audit trail.

That loop — **consent → play → balance → settle → remember** — is the whole product.

---

## 17. One-Sentence Summary

**Poker Ledger is a privacy-conscious, guided cash-game ledger that takes a poker night from invited lobby through live buy-ins to a locked settlement everyone can trust — with groups for ongoing crews and stats that only count games you actually accepted.**

---

*Document generated from the current Poker Ledger Flutter app product surfaces (screens, copy, help, and user-visible flows). It describes what the product does for people, not internal server architecture.*
