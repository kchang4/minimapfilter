# MinimapFilter

A custom Ashita v4 addon that provides **filtered monster display** on the Minimap plugin. This addon works as an overlay on top of the Minimap plugin, allowing you to selectively show or hide monsters based on name patterns, claim status, and entity types.

## Features

- **Name Pattern Filtering** - Show only specific monsters (whitelist mode) or hide specific monsters (blacklist mode)
- **Claim Status Filtering** - Filter by unclaimed, claimed by you, claimed by party, or claimed by others
- **Entity Type Filtering** - Toggle visibility of monsters, NPCs, and players separately
- **Custom Colors** - Set different colors for each claim status and entity type
- **Real-time Updates** - Changes take effect immediately without reloading

## Requirements

- Ashita v4
- Minimap plugin loaded

## Installation

1. Copy the `minimapfilter` folder to your `Ashita4/addons/` directory
2. Load the addon: `/addon load minimapfilter`

## How to have Ashita load it automatically

1. Open `Ashita4/scripts/default.txt`
2. Add `/addon load minimapfilter` after the minimap plugin is loaded

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `/mmf` or `/minimapfilter` | Open the configuration GUI |
| `/mmf add <pattern>` | Add a mob name pattern to show (whitelist) |
| `/mmf hide <pattern>` | Add a mob name pattern to hide (blacklist) |
| `/mmf remove <pattern>` | Remove a pattern from either list |
| `/mmf addid <id>` | Add a Server ID to show (whitelist) |
| `/mmf hideid <id>` | Add a Server ID to hide (blacklist) |
| `/mmf removeid <id>` | Remove a Server ID from either list |
| `/mmf targetid` | Add current target's Server ID |
| `/mmf clear` | Clear all patterns and IDs |
| `/mmf clearids` | Clear all IDs |
| `/mmf toggle` | Toggle the filter on/off |
| `/mmf reload` | Reload settings |

### Examples

```
/mmf hide Rabbit           -- Hide all mobs with "Rabbit" in name
/mmf hide Crawler          -- Hide all crawlers
/mmf add Greater Colibri   -- Add Greater Colibri to show list
/mmf remove Rabbit         -- Remove the Rabbit pattern
/mmf targetid              -- Add current target's Server ID
/mmf addid 17043521        -- Add specific Server ID to filter
```

## ID-Based Filtering

When multiple monsters share the same name, use Server IDs to target specific ones:

1. Target the monster you want to filter
2. Open the GUI (`/mmf`) and expand the **Debug** section to see the Server ID
3. Click **"Add Current Target ID"** in the ID Filters section, or use `/mmf targetid`
4. Each ID in the list has a **color picker** - click it to set a custom color for that monster

### Pattern Matching

Patterns support:
- **Simple text matching** - `Rabbit` matches "Wild Rabbit", "Rabbit", etc.
- **Lua patterns** - `^Crab` matches names starting with "Crab"
- **Case insensitive** - patterns are matched regardless of case

## Filter Modes

### Blacklist Mode (Default)
Hide monsters that match any pattern in the hide list. All other monsters are shown.

### Whitelist Mode
Only show monsters that match patterns in the show list. All other monsters are hidden.

## Configuration

Settings are automatically saved per character to:
```
Ashita4/config/addons/minimapfilter/[character]/settings.lua
```

### Available Settings

| Setting | Description | Default |
|---------|-------------|---------|
| `enabled` | Enable/disable the filter overlay | `true` |
| `hidePluginMonsters` | Hide the minimap plugin's default monster dots | `true` |
| `filterMode` | `'blacklist'` or `'whitelist'` | `'blacklist'` |
| `showMonsters` | Show monster entities | `true` |
| `showNPCs` | Show NPC entities | `true` |
| `showPlayers` | Show player entities | `true` |
| `showUnclaimed` | Show unclaimed monsters | `true` |
| `showClaimedByMe` | Show monsters you've claimed | `true` |
| `showClaimedByParty` | Show monsters claimed by party | `true` |
| `showClaimedByOthers` | Show monsters claimed by others | `true` |
| `showIds` | Server IDs to show (whitelist mode) | `{}` |
| `hideIds` | Server IDs to hide (blacklist mode) | `{}` |
| `idColors` | Custom colors per Server ID | `{}` |
| `dotRadius` | Size of the dots on minimap | `3` |

### Color Settings

Colors are in RGBA format (0.0 to 1.0):

| Color Setting | Default |
|---------------|---------|
| `monsterColor` | Red (unclaimed monsters) |
| `claimedByMeColor` | Orange |
| `claimedByPartyColor` | Yellow |
| `claimedByOthersColor` | Purple |
| `npcColor` | Green |
| `playerColor` | Blue |

## How It Works

1. The addon reads the Minimap plugin's configuration from `config/minimap/minimap.ini`
2. It reads theme dimensions from `config/minimap/themes/<theme>/theme.ini`
3. It uses the `/minimap drawmonsters 0` command to disable the plugin's monster rendering
4. It creates an invisible ImGui overlay positioned precisely over the minimap
5. It iterates through all entities, applies your filters, and draws colored dots for matching entities
6. When unloaded, it restores monster rendering with `/minimap drawmonsters 1`

## Troubleshooting

**Dots don't align with minimap:**
- The addon reads minimap position every 2 seconds. If you move the minimap, wait a moment.
- Check the Debug section in the GUI to see the current minimap configuration being used.
- Make sure your theme.ini has correct frame/mask dimensions.

**Minimap plugin dots still showing:**
- Make sure `Hide Plugin Monster Dots` is enabled in settings
- The addon uses `/minimap drawmonsters 0` to hide the plugin's dots

**Performance issues:**
- The addon iterates through all entities each frame. This is generally fast but you can disable the filter when not needed.

## Credits

- Inspired by [minimapcontrol](https://github.com/onimitch/ffxi-ashita-minimapcontrol) by onimitch
- Uses techniques from ScentHound by Thorny for entity tracking

## License

MIT License
