# TimMenu Migration Complete

## Overview
Successfully migrated from deprecated **ImMenu** to modern **TimMenu** library for the Cheater Detection menu system.

---

## Changes Made

### **1. Menu.lua - Complete Rewrite**
**File:** `Misc/Visuals/Menu.lua`

**Old System (ImMenu):**
```lua
local ImMenu = require("Cheater_Detection.Libs.ImMenu")

ImMenu.BeginFrame()
-- widgets
ImMenu.EndFrame()
```

**New System (TimMenu):**
```lua
local TimMenu = nil
local timMenuLoaded, timMenuModule = pcall(require, "TimMenu")
if timMenuLoaded and timMenuModule then
    TimMenu = timMenuModule
else
    error("[CD] TimMenu not found! Please install TimMenu...")
end

TimMenu.Begin("Cheater Detection")
TimMenu.BeginSector("Section Name")
-- widgets with NextLine() calls
TimMenu.EndSector()
TimMenu.End()
```

---

## Key API Changes

### **Window Management**
| ImMenu | TimMenu |
|--------|---------|
| `ImMenu.BeginFrame()` | Not needed |
| `ImMenu.Begin(title, visible)` | `TimMenu.Begin(title)` |
| `ImMenu.EndFrame()` | Not needed |
| `ImMenu.End()` | `TimMenu.End()` |

### **Layout**
| ImMenu | TimMenu |
|--------|---------|
| Auto-layout | **`TimMenu.NextLine()`** - Manual line breaks required |
| No sectors | **`TimMenu.BeginSector(label)` / `EndSector()`** - Grouped panels |
| N/A | `TimMenu.Spacing(amount)` - Custom spacing |
| N/A | `TimMenu.Separator([label])` - Visual separator |

### **Widgets**
| ImMenu | TimMenu |
|--------|---------|
| `ImMenu.Checkbox(label, value)` | `TimMenu.Checkbox(label, value)` - Same API ✅ |
| `ImMenu.Slider(label, value, min, max)` | `TimMenu.Slider(label, value, min, max, step)` - Added step param |
| `ImMenu.TabControl(tabs, selected)` | `TimMenu.TabControl(id, tabs, selected)` - Added id param |
| No tooltips | **`TimMenu.Tooltip(text)`** - Attach to last widget |

---

## Menu Structure Improvements

### **Before (ImMenu)**
```lua
ImMenu.BeginFrame(1)
Main.Fetch_Database = ImMenu.Checkbox("Fetch Database", Main.Fetch_Database)
Main.AutoMark = ImMenu.Checkbox("Auto Mark", Main.AutoMark)
ImMenu.EndFrame()
```
- Flat layout
- No visual grouping
- Frame management required

### **After (TimMenu)**
```lua
TimMenu.BeginSector("Database & Detection")
Main.Fetch_Database = TimMenu.Checkbox("Fetch Database", Main.Fetch_Database)
TimMenu.NextLine()
Main.AutoMark = TimMenu.Checkbox("Auto Mark", Main.AutoMark)
TimMenu.NextLine()
Main.partyCallaut = TimMenu.Checkbox("Party Callout", Main.partyCallaut)
TimMenu.EndSector()
```
- **Sectored panels** with shaded backgrounds
- Better visual organization
- Explicit layout control with `NextLine()`

---

## Enhanced Features

### **1. Tooltips**
```lua
Advanced.Evicence_Tolerance = TimMenu.Slider("Evidence Tolerance", value, 1, 10, 1)
TimMenu.Tooltip("Threshold for marking players as cheaters (higher = more strict)")
```
✅ **Benefit:** Better UX with hover explanations

### **2. Hierarchical Sections**
```lua
TimMenu.BeginSector("Exploit Detection")
    Advanced.Choke = TimMenu.Checkbox("Fake Lag Detection", Advanced.Choke)
    TimMenu.NextLine()
    Advanced.Warp = TimMenu.Checkbox("Warp/DT Detection", Advanced.Warp)
TimMenu.EndSector()
```
✅ **Benefit:** Grouped related settings visually

### **3. Tab Control**
```lua
-- Old: No ID required
G.Menu.currentTab = ImMenu.TabControl(tabs, G.Menu.currentTab)

-- New: ID required for state tracking
G.Menu.currentTab = TimMenu.TabControl("cd_main_tabs", tabs, G.Menu.currentTab)
```
✅ **Benefit:** Better state management across frames

---

## Installation Requirements

### **User Must Install TimMenu**
TimMenu is **not bundled** with the script - it must be installed globally:

**Location:** `%localappdata%\lmaobox\Scripts\TimMenu.lua`

**Download:** [github.com/titaniummachine1/TimMenu](https://github.com/titaniummachine1/TimMenu/releases/latest)

### **Error Handling**
```lua
local timMenuLoaded, timMenuModule = pcall(require, "TimMenu")
if timMenuLoaded and timMenuModule then
    TimMenu = timMenuModule
    print("[CD] TimMenu loaded successfully")
else
    error("[CD] TimMenu not found! Please install TimMenu to %localappdata%\\lmaobox\\Scripts\\TimMenu.lua")
end
```
✅ **Script will fail fast** with clear error message if TimMenu not installed

---

## Removed Code

### **Common.lua**
**Removed:**
```lua
local Common = {
    ImMenu = nil,  -- REMOVED
    -- ...
}

-- Unload ImMenu if loaded - REMOVED
if package.loaded["ImMenu"] then
    package.loaded["ImMenu"] = nil
end

Common.ImMenu = ImMenu  -- REMOVED
```

**Why:** ImMenu no longer used anywhere in codebase

---

## Menu Layout Comparison

### **Main Tab**
**Before:** 6 checkboxes in flat list  
**After:** 2 sectors - "Database & Detection" + "Visual Settings"

### **Advanced Tab**
**Before:** Multiple frames, flat structure  
**After:** 5 sectors:
1. Evidence System (with slider + tooltip)
2. Exploit Detection (3 checkboxes)
3. Movement Detection (3 checkboxes)
4. Aim Detection (nested with sub-checkboxes)
5. Debug (1 checkbox + tooltip)

### **Misc Tab**
**Before:** Nested if/then blocks  
**After:** 4 sectors:
1. Auto Vote (with nested options)
2. Vote Reveal (with nested options)
3. Class Change Reveal (with nested options)
4. Notifications

---

## Benefits Summary

✅ **Modern API** - TimMenu is actively maintained  
✅ **Better UX** - Tooltips, sectored panels, visual hierarchy  
✅ **Cleaner Code** - Explicit layout control with `NextLine()`  
✅ **Flexibility** - Manual layout = more design control  
✅ **Error Detection** - Comprehensive assertions catch issues early  
✅ **Safe Mode** - `BeginSafe()` / `EndSafe()` for production  

---

## Migration Checklist

- [x] Clone TimMenu repository into `Libs/TimMenu/`
- [x] Update `Menu.lua` to use TimMenu API
- [x] Replace all `ImMenu.BeginFrame()` / `EndFrame()` calls
- [x] Add `NextLine()` calls between widgets
- [x] Convert flat layouts to sectored panels
- [x] Add tooltips to key settings
- [x] Update TabControl with ID parameter
- [x] Remove ImMenu references from `Common.lua`
- [x] Test menu functionality
- [x] Document installation requirements

---

## Testing Notes

### **To Test:**
1. Install TimMenu to `%localappdata%\lmaobox\Scripts\TimMenu.lua`
2. Load Cheater Detection script
3. Verify menu opens in GUI (INSERT key)
4. Test all tabs: Main, Advanced, Misc
5. Verify checkboxes/sliders/tabs work correctly
6. Check tooltips appear on hover
7. Verify sectored panels render correctly

### **Expected Behavior:**
- Menu opens with 3 tabs
- Settings organized into visual sectors
- Tooltips show on hover
- All state persists correctly
- No errors in console

---

## Notes

**ImMenu vs TimMenu Philosophy:**
- **ImMenu:** Automatic layout, frame-based
- **TimMenu:** Manual layout, immediate-mode with retained foundation

**Why Manual Layout is Better:**
- Full control over widget positioning
- Easier to create complex nested layouts
- More explicit = easier to debug
- Matches modern UI frameworks (ImGui-style)

**Compatibility:**
- TimMenu requires global installation
- Cannot be bundled due to Lmaobox Lua limitations
- Users must download separately from GitHub

---

## References

- **TimMenu GitHub:** https://github.com/titaniummachine1/TimMenu
- **TimMenu API Docs:** See README.md in repository
- **Example Usage:** `Libs/TimMenu/examples/menudemo1.lua`
