# Captain's Log

## 0.9.0

- Journey map notes sit in a tidy list in the map's corner (with each thing's icon) instead of beside the icons, where they ran into each other, and the big moments (a level, a quest done, a death, a boss, a first item) hold the playback a moment so you can read them. Both can be turned off in the Show menu.
- **Things pop up as they happen** on the journey map: while it plays (or you drag forward), each icon bounces in as you reach it with a short note beside it ("Quest done: ...", "Level 11"), then fades back so your route stays easy to see. Hover any icon to bring it back. The notes can be turned off in the Show menu.
- **Level ups stand out on the time bar** with a gold mark and the level number; click near one to jump right to it.
- **Quiet stretches are squeezed** on the time bar (time away, standing about), so the busy parts get the room. Turn it off in the Show menu with "Squeeze quiet stretches".
- A thin strip under the time bar shows where the most happened.
- **Every kill on the map**: a small dot wherever you killed something, with its name and time when you hover it.
- **Gathering**: herbs picked, ore mined and hides skinned are written in the log, and show on the map.
- **Travel**: flights (where from, where to and how long), hearthstone trips, boat and zeppelin crossings, and your very first mount.
- **Combat**: your fights show as red stretches of your route, and close calls (below 20% health and lived) get a line in the log.
- **Stops**: inns you rest at, and the vendors, trainers and mailboxes you visit (once each a day).
- **XP**: hover the time bar to see the experience you earned there, and turn on "XP" in the Show menu for dots on the map. The log also notes when your rested experience runs out.
- **You on the journey map**: a portrait of your character in the map's corner while it plays, in the gear you had on at that moment (your level's snapshot plus each upgrade since), with your level under it. Passing a level up plays the level-up sound and a golden burst around you, and changes into the new gear. Can be hidden in the Show menu.
- The journey map **follows you from map to map** as it plays or as you scrub: from Zephras Isle to Mulgore to the Barrens, it brings up the zone you were in at that moment (a map that already shows it, like a whole continent, stays). It can be turned off in the Show menu.
- Each level's page on the Character page shows **you as you were**: a model of your character in the gear you had on then (drag it to turn it round).
- Names on Forever include the surname: "Feral Streep", not just "Feral".
- **Choose what the journey map shows**: the Show button on its bar lists your route and each kind of entry (quests, loot and gear, kills, deaths, levels and milestones, places, people, fishing, pictures). Tick as much or as little as you like; the time bar's marks follow, and your choice is kept.

## 0.8.0

- **Character page** — a new page in the book about you: time played, how long you've been at this level and how long a level takes you on average, and every level you've reached with the date, how long it took and where. Click a level to see yourself as you were then: your gear, stats, health and mana, armour, talents, skills, coin and rested experience (snapshots are taken from now on, as you level).
- On the Character page too: **where your time goes** (fighting, flying, resting, away, in a group...) for all time, today and this level; **how far you've travelled** on foot, mounted, swimming, by flight and as a ghost; and **your characters** across the account, with their level, time played, coin and when you last saw them.
- **Ledger** — a new page for your coin: what it came from (selling, loot, quests, the auction house, mail, trades) and what it went on (buying, repairs, training, flights, postage...), for all time, the last seven days and each day, with what you came out ahead or behind. It also keeps your lifetime tallies (kills, quests, deaths, items looted and made, fish, flights, hearthstones, dungeons, bosses, duels) and where your experience came from.
- **Journey map with a time bar** — your route each day is written down, and the book plays it back on the world map. Open it from the new button on the map, from a day's timeline, or from the Character page. Pick a day (or all days), press Play, and choose a speed; or click and drag along the time bar to go back and forth through the day. Your route so far is drawn, a marker shows where you were, and things from the log (quests, kills, deaths, levels, pictures, firsts...) pop up where they happened; hover one to read its line. "Whole route" shows the full day at once.
- New timeline entries: upgrades you put on, spells learned, reputation steps ("Now Honored with Stormwind"), profession steps, joining or leaving a guild, duels won and lost, the first of each good item you find, and milestones (your 100th quest, your 1,000th kill...). The level line now says how long you'd played and how long the last level took, with a link to how you looked then.
- Settings: keep detailed routes for a number of days (older days keep a simpler line, so the saved file stays small), and hide the journey map's button if you don't want it.
- Asking the game for your time played no longer prints it to chat (your own /played still does).

## 0.7.0

- **简体中文** — Captain's Log can now show in other languages, and starts with Simplified Chinese (used automatically on a Chinese game client). It's a first pass: corrections from native players are very welcome.
- Names and words the game gives (zones, creatures, items) were already in your language; this covers the addon's own text.
- Known gap on non-English clients: other players' pets and totems may slip into People, since spotting them reads English tooltip text.
- Options > AddOns with the gamepad interface: the Frog Wizard pages no longer upset the game's gamepad navigation (which could bring up errors on opening the settings). From FrogLib 1.5.0.

## 0.6.3

- CurseForge doesn't allow a .bat file inside an add-on, so **Set up pictures.bat** is no longer in the download (which is why 0.5.1 to 0.6.2 never appeared there). Download it from the link in the book instead (Settings > Set up pictures..., or "How?" on a day's pictures), put it in the add-on's folder and double-click it as before. Everything from 0.5.1 to 0.6.2 comes with this version.

## 0.6.2

- In a raid where the game hides who's who, you're no longer saved as a member of your own dungeon run or as your own photo's target.

## 0.6.1

### Fixes
- A dungeon run's "Creatures slain inside" no longer lists creatures as "Unknown creature #n:..." or twice. Inside dungeons the game hides which creature was killed, so some kills are counted by name; those now join the creature's own entry once the log knows it (runs already saved are fixed at login), and show their proper name until then.
- Writing down people, creatures, quests, places and dungeon groups no longer stops with an error where the game hides a name, a level, a map position, a quest's rewards or whether a unit is a player (some instances): the hidden detail is just left out.
- A dungeon group member whose class the game hides is saved without it, instead of breaking the run's record.

### Under the hood
- Class colours on the Dungeons page come from FrogLib, shared with the other Frog Wizard add-ons (a class colour add-on's colours are used if you have one).

## 0.6.0

### Fishing
- A new **Fishing** page in the book. Everything you fish up is written down: each kind of catch with its icon, how many you've caught, and when and where you first landed it. Search by name.
- Pick a catch to see every spot it has come from, how much of your catch there it makes up, and how many came from pools or open water, with links to the land's page in Lands and a map of where you caught it.
- **Spots**: every place you've fished, land by land. Each shows what it gives and how often, how many casts went into pools, and a map of where you cast from (with a Map button and a waypoint).
- Your fishing skill along the foot of the page. Click it for your milestones: each 25 points you gain is written down with the date, the place and the catch that did it.
- The daily log writes one line per spell of fishing ("Caught 12 fish at Auberdine, Darkshore (9 Raw Brilliant Smallfish...), among them your first Firefin Snapper") and notes each fishing skill milestone. The day's summary and each land's page count the fish too.
- Settings: switch the fishing journal off, or show all your fishing spots on the world map (off by default; right-click one there to hide them again).

### Conversations
- The book now writes down what people say to you. Each person's page has a **What they say** section: their greeting, and every reply their window offered, with its icon.
- Replies you chose are ticked, with how many times you picked them. Ones that only turn up now and then say how often they were offered, and ones that open a shop, training, the flight map or your bank say so.
- Follow a reply to another page of conversation and that page is written in under it, indented, so the whole conversation builds up as you explore it. Replies that lead back (to the greeting, say) point to where they return.
- When someone's words change (after a quest, say), the newest are shown with the date, and their earlier words are a click away.
- Quests on offer in the conversation are listed, linking to the quest journal for ones you've taken.
- The People search now looks through what people said and the replies they offered too: search "Wailing Caverns" to find who mentioned it.
- Settings: switch it off if you'd rather not keep conversations.

- Anyone you talk to, trade with or fly with now goes in People, even NPCs you could attack, such as the neutral goblins of Ratchet and Booty Bay. They were left out before.
### Under the hood
- Shares its options page with the other Frog Wizard add-ons (one copy of the code, so a fix reaches them all at once). Nothing changes in how it looks or works.

## 0.5.2

### Options
- Listed with the rest of Frog Wizard's add-ons: under a "Frog Wizard" heading in the AddOn list, and in its own "Frog Wizard" section of Options > AddOns, whose page lists them all with a button to each one's settings.

## 0.5.1

- No changes in the game. From this version, releases are published automatically to CurseForge and GitHub.

## 0.5.0

### Pictures of the journey
- Every screenshot you take goes into that day's page as a photo card: the picture, the time, your level, where you were, who you were with and what you were looking at. (Settings can limit it to the book's own pictures.)
- **Take a picture**: a button by your notes, a key binding (Key Bindings > AddOns) and `/log picture`. The book steps out of shot, and so does the rest of the interface when you're out of combat.
- A **Pictures** view for each day, as a list (with captions you can write, and Remove) or a grid. Click a picture to see it whole.
- **Where**: swaps the picture for a close-up map of the spot, with a gold cone showing the way you were facing. Click the map to mark the spot and the cone on your world map.
- Pictures also show in the timeline ("Took a picture at Jerod's Landing") and on each land's page.
- **Setting it up (once, Windows):** the game only reads files inside its own folders, so double-click **Set up pictures.bat** in the add-on's folder. It links your Screenshots folder in as `Interface\AddOns\CaptainsLogShots`; nothing is copied or moved. Then press **It's set up** in the book (Settings > Set up pictures... walks you through it). Running it again brings in screenshots you took before.
- New pictures show after a `/reload` (the game only notices new files when the interface loads); the book marks them and has a Reload button on hand.

### Also
- Scroll bars on every page and list.
- Pages keep their place when they update (pressing a button, a new kill) instead of jumping back to the top.

## 0.5.1

- No changes in the game. From this version, releases are published automatically to CurseForge and GitHub.

## 0.4.1

### Lands
- Lands are grouped by landmass (Eastern Kingdoms, Kalimdor and so on), with dungeons and raids listed apart.
- A dungeon's page shows your runs, links to its full record in Dungeons, and shows the dungeon's own map in place of an empty one.

### Options
- Captain's Log now has an entry in the game's Options > AddOns list, with a button that opens the book's settings and its slash commands.

### Fixes
- Other players' totems, pets and companions are no longer recorded as people (or as creatures in the bestiary). Ones already recorded are cleared out.

## 0.5.1

- No changes in the game. From this version, releases are published automatically to CurseForge and GitHub.

## 0.4.0

The book is now one linked journal, and it can put what it knows on your world map.

### World map pins
- **Map** buttons throughout the book pin things to the game's own world map: quest givers (!) and hand-ins (?), where you've slain a quest's creatures, any creature in the bestiary, people, and a land's places, deaths and services.
- Creatures you've slain a lot are drawn as shaded hunting areas instead of a crowd of dots.
- Pins stay until you remove them. Hover one for details, click it to open that page in the book, right-click to remove that set, or shift-right-click to remove them all (also in Settings).
- **Waypoint** buttons set the game's waypoint, with the arrow on screen.
- The book stays open behind the map; click it to bring it back in front.

### Quests
- Each quest keeps its own words: the quest text, the objective, what's said when you hand it in, and its rewards (including the one you chose).
- A live objectives checklist. Under each objective are the creatures it needs (linked to the bestiary) and, for item objectives, who drops the item and how often.
- Who gave you the quest and who took it back, with Map and Waypoint buttons.
- Abandoned quests and repeat completions are recorded. The list has search and filters.

### A linked journal
- Names of creatures, quests, people and lands are links. Follow them around the book, then use "Back to..." to return.
- Bestiary entries show which quests want that creature ("Wanted for"). Finished quests move to the bottom.

### Lands
- Places discovered in each land (also in the daily timeline), number of visits and your level range there.
- A map of places, people and deaths, plus the folk you met there, quests begun and finished, notable foes and where you fell.
- Search and sorting.

### Dungeons
- New **By dungeon** view: full clears, fastest and average clear times, your record against each boss, regular companions, and all the loot.
- Each run now shows the boss checklist from the Encounter Journal, your role and your companions' roles, creatures slain, experience and gold, and which boss each item came from.

### People
- Trainers: everything they teach, with costs and requirements. Search finds lessons too.

### Notes
- Quest text and rewards are recorded for quests you pick up from now on.
- Map pins don't show inside instanced dungeons.
