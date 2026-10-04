# Captain's Log

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
