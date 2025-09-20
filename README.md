# CP Exchange — Signet Buddy (Autospawn next to Signet / Conquest Guards)

A tiny LandSandBoat/DSP-style Lua module that **auto-spawns a “CP Exchange” NPC beside every Signet/Conquest guard** when a zone loads. It lets players convert **Conquest Points (CP)** into end-game currencies with a clean, paginated UI and a safe purchase flow.

> **Why?**  
> Once players hit 75/max level, they’re less likely to join lower-level groups and CP often sits unused. This module turns CP into a valuable sink and convenience feature—encouraging capped players to engage in low/mid content and helping group formation—without teleporting all over.

---

## Features

- **Zero per-NPC edits** — Autodetects guards by their Conquest handler and spawns the exchanger on zone init.  
- **Safe UI** — Paged menus (≤8 entries per page), quantity choices up to **5000**, and a **MAX** option with an **“Are you sure?”** confirmation.  
- **Clear labels** — ASCII names and disambiguations (e.g., *Byne Bill*, *O. Bronzepiece*, *M. Silverpiece*, *L. Jadeshell*).  
- **CP safety** — Inventory space is **pre-checked**; on unexpected failures CP is **refunded** with a precise message.  
- **Click fallback** — If a guard slips past detection, the first click on that guard spawns the exchanger (optional, easy to disable).  
- **Drop-in** — Single file + one `require(...)` line.

### Included conversions (defaults)

- **Dynamis singles**: Byne Bill / O. Bronzepiece / T. Whiteshell (50 CP each)  
- **Dynamis 100s**: 100 Byne Bill / M. Silverpiece / L. Jadeshell (5000 CP each)  
- **Alexandrite** (60 CP)  
- **Cruor** (1 CP → 1 Cruor)  
- **Empyrean**: Heavy Metal Plate (1000 CP), Riftdross (7500 CP), Riftcinder (10000 CP)  
- **Other**: Nyzul Tokens (1 CP → 1), Therion Ichor (10 CP → 1)

You can change rates/items—see **Configuration**.

---

## Quick Start

1. **Place the module file** at:

   ```
   modules/custom/lua/cp_exchange_signet_buddy.lua
   ```

2. **Load it** (e.g., in your custom init/module loader):

   ```lua
   custom/lua/cp_exchange_signet_buddy/lua
   ```

3. **Restart map** and visit any Signet/Conquest guard — the **CP Exchange** book should already be standing next to them.

---

## Configuration

Open `cp_exchange_signet_buddy.lua` and tweak the following:

- **Rates & items** (`RATES` table):
  ```lua
  { id='alex', label='Alexandrite', type='item', itemId=xi.item.ALEXANDRITE, cp_per_unit=60 }
  ```

- **Quantities** (`UNITS_CHOICES`):
  ```lua
  local UNITS_CHOICES = { 1, 10, 50, 99, 100, 250, 500, 1000, 2500, 5000 }
  ```

- **Pagination size** (`UNITS_PER_PAGE`): keep to 4 to stay within the client’s 8-entry menu cap (Prev/Next/MAX/Back).

- **Name fallback** (`GUARD_NAME_PATTERNS`): optional; handler-based detection is primary.

- **Disable click fallback** (optional): remove the “Optional safety net” block that wraps `xi.conquest.signetOnTrigger` / `overseerOnTrigger`.

---

## How It Works

- On **zone init**, the module scans NPCs. If an NPC’s `onTrigger` is `xi.conquest.signetOnTrigger` or `xi.conquest.overseerOnTrigger`, it **inserts** a book-model NPC (“CP Exchange”) beside the guard via `zone:insertDynamicEntity`.
- The exchanger shows a **multi-page menu**:  
  `Rates & Info → Your CP → Dynamis → Alexandrite → Cruor → Others…`  
  Each item opens a **quantity page** with: `Prev • Buy xN • … • MAX • Next • Back`.
- **MAX** prompts: *“Yes – spend X CP for Y [Item/Currency]”* or *“No – go back”*.
- Before spending CP, the script checks **inventory space** (for item conversions). If the subsequent add fails for any reason, it **refunds** the CP and tells the player exactly how much was refunded.

---

## Troubleshooting

- **No exchanger spawns**
  - Ensure the file path and `require(...)` are correct.
  - Your fork must expose one of `zone:forEachEntity` or `zone:iterateEntities`.
  - Conquest handlers must be `xi.conquest.signetOnTrigger` / `xi.conquest.overseerOnTrigger`.
  - If your fork differs, either add another iterator or switch to an **ID registry** approach (see Roadmap).

- **Double spawns**
  - The module dedupes per `zoneId:npcId`. If you loaded it twice, remove the duplicate `require`.

- **CP spent but no item**
  - With this version, CP should **refund** and print “CP refunded: N”.
  - If your core lacks `addCP`, the module uses `addCurrency('conquest_points', amount)` as a fallback — ensure one of those exists.

- **Placement overlaps walls/NPCs**
  - Tweak the offset used in `spawnExchangeBeside()` (the `+ 1.2` / `+ 0.8` values).
  - Add a per-name/per-zone offsets table if needed.

---

## Compatibility

- Designed for **LandSandBoat/DSP-style** servers (Lua zones, `xi.*` namespace).
- Requires: `modules/module_utils`, `scripts/globals/conquest`, `scripts/enum/item`, and a zone API that supports iterating NPCs and inserting dynamic entities.
