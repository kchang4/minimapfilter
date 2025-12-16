addon.name      = 'minimapfilter'
addon.author    = 'GaiaXI'
addon.version   = '1.0.0'
addon.desc      = 'Filters which monsters appear on the minimap plugin'
addon.link      = 'https://github.com/GaiaXI'

--[[
    MinimapFilter - Custom monster filtering for the Minimap plugin
    
    This addon works alongside the Minimap plugin to provide selective
    monster display based on configurable filters.
    
    Usage:
        /mmf or /minimapfilter - Open the configuration GUI
        /mmf add <pattern>     - Add a mob name pattern to show
        /mmf remove <pattern>  - Remove a mob name pattern
        /mmf hide <pattern>    - Add a mob name pattern to hide
        /mmf clear             - Clear all filters (show all)
        /mmf reload            - Reload settings
]]

require('common')
local imgui = require('imgui')
local settings = require('settings')
local chat = require('chat')
local ffi = require('ffi')

-- Default settings
local defaultSettings = T{
    -- Filter mode: 'whitelist' (only show matching) or 'blacklist' (hide matching)
    filterMode = 'blacklist',
    
    -- Patterns to match (Lua patterns supported)
    showPatterns = T{},      -- Whitelist patterns (names)
    hidePatterns = T{},      -- Blacklist patterns (names)
    
    -- ID-based filters (server IDs for specific entities)
    showIds = T{},           -- Whitelist IDs (only show these specific entities)
    hideIds = T{},           -- Blacklist IDs (hide these specific entities)
    idColors = T{},          -- Custom colors per ID: { [serverId] = {r, g, b, a}, ... }
    
    -- Entity type filters
    showMonsters = true,
    showNPCs = true,
    showPlayers = true,
    
    -- Claim status filters
    showUnclaimed = true,
    showClaimedByMe = true,
    showClaimedByOthers = true,
    showClaimedByParty = true,
    
    -- Display settings
    dotRadius = 3,
    monsterColor = { 1.0, 0.0, 0.0, 1.0 },      -- Red
    claimedByMeColor = { 1.0, 0.5, 0.0, 1.0 },  -- Orange
    claimedByPartyColor = { 1.0, 1.0, 0.0, 1.0 }, -- Yellow
    claimedByOthersColor = { 0.5, 0.0, 0.5, 1.0 }, -- Purple
    npcColor = { 0.0, 0.8, 0.2, 1.0 },          -- Green
    playerColor = { 0.0, 0.5, 1.0, 1.0 },       -- Blue
    
    -- Enable/disable the filter overlay
    enabled = true,
    
    -- Auto-hide minimap plugin's monster dots
    hidePluginMonsters = true,
    
    -- Debug mode
    debug = false,
}

-- Addon state
local minimapfilter = {
    settings = T{},
    showGui = false,
    initialized = false,
    minimapConfig = T{},
}

-- GUI state variables for ImGui
local guiState = {
    newShowPattern = { '' },
    newHidePattern = { '' },
    newShowId = { '' },
    newHideId = { '' },
    selectedShowIndex = 1,
    selectedHideIndex = 1,
}

-- Track the last state we set so we don't spam commands
local lastDrawMonstersState = nil

-- Track entity counts for debug (will be set by RenderFilteredEntities)
local lastEntityCounts = { monsters = 0, npcs = 0, players = 0, total = 0 }

-- ============================================================================
-- Helper Functions
-- ============================================================================

local function LogMessage(msg, ...)
    print(chat.header(addon.name):append(chat.message(msg:format(...))))
end

local function LogError(msg, ...)
    print(chat.header(addon.name):append(chat.error(msg:format(...))))
end

local function LogDebug(msg, ...)
    if minimapfilter.settings.debug then
        print(chat.header(addon.name):append(chat.message('[DEBUG] ' .. msg:format(...))))
    end
end

-- Read minimap.ini to get minimap position and settings
local function ReadMinimapConfig()
    local installPath = AshitaCore:GetInstallPath()
    local iniPath = installPath .. '/config/minimap/minimap.ini'
    local config = T{
        x = 25,
        y = 25,
        scale_x = 1.0,
        scale_y = 1.0,
        zoom = 1.0,
        rotate_map = false,
        -- Theme defaults (circle theme)
        frame_w = 248,
        frame_h = 248,
        frame_p = 25,
        mask_w = 200,
        mask_h = 200,
        theme = 'circle',
    }
    
    local f = io.open(iniPath, 'r')
    if f == nil then
        LogDebug('Could not open minimap.ini')
        return config
    end
    
    for line in f:lines() do
        local key, value = line:match('^([%w_]+)%s*=%s*([%d%.%-]+)')
        if key and value then
            if key == 'x' then config.x = tonumber(value) or 25 end
            if key == 'y' then config.y = tonumber(value) or 25 end
            if key == 'scale_x' then config.scale_x = tonumber(value) or 1.0 end
            if key == 'scale_y' then config.scale_y = tonumber(value) or 1.0 end
            if key == 'zoom' then config.zoom = tonumber(value) or 1.0 end
            if key == 'rotate_map' then config.rotate_map = (tonumber(value) == 1) end
        end
        -- Read theme name
        local themeName = line:match('^name%s*=%s*(%w+)')
        if themeName then
            config.theme = themeName
        end
    end
    f:close()
    
    -- Read theme configuration
    local themePath = installPath .. '/config/minimap/themes/' .. config.theme .. '/theme.ini'
    local tf = io.open(themePath, 'r')
    if tf then
        local section = ''
        for line in tf:lines() do
            local sec = line:match('^%[([%w%.]+)%]')
            if sec then
                section = sec
            end
            local key, value = line:match('^([%w_]+)%s*=%s*([%d%.%-]+)')
            if key and value then
                if section == 'frame' then
                    if key == 'w' then config.frame_w = tonumber(value) or 248 end
                    if key == 'h' then config.frame_h = tonumber(value) or 248 end
                    if key == 'p' then config.frame_p = tonumber(value) or 25 end
                elseif section == 'mask' then
                    if key == 'w' then config.mask_w = tonumber(value) or 200 end
                    if key == 'h' then config.mask_h = tonumber(value) or 200 end
                end
            end
        end
        tf:close()
    end
    
    return config
end

-- Get party member IDs for claim checking
local function GetPartyMemberIds()
    local ids = T{}
    local party = AshitaCore:GetMemoryManager():GetParty()
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 then
            ids:append(party:GetMemberServerId(i))
        end
    end
    return ids
end

-- Get the player's server ID
local function GetPlayerId()
    local party = AshitaCore:GetMemoryManager():GetParty()
    return party:GetMemberServerId(0)
end

-- Check if an entity matches any pattern in a list
local function MatchesAnyPattern(name, patterns)
    if not name or #patterns == 0 then
        return false
    end
    
    local lowerName = name:lower()
    for _, pattern in ipairs(patterns) do
        local lowerPattern = pattern:lower()
        -- Try exact match first
        if lowerName == lowerPattern then
            return true
        end
        -- Try Lua pattern match
        local success, result = pcall(function() return lowerName:match(lowerPattern) end)
        if success and result then
            return true
        end
        -- Try simple contains match
        if lowerName:find(lowerPattern, 1, true) then
            return true
        end
    end
    return false
end

-- Check entity spawn flags to determine type
local function GetEntityType(spawnFlags)
    if bit.band(spawnFlags, 0x0001) ~= 0 then
        return 'player'
    elseif bit.band(spawnFlags, 0x0002) ~= 0 then
        return 'npc'
    elseif bit.band(spawnFlags, 0x0010) ~= 0 then
        return 'monster'
    end
    return 'unknown'
end

-- Determine claim status
local function GetClaimStatus(claimId, partyIds, playerId)
    if claimId == 0 then
        return 'unclaimed'
    elseif claimId == playerId then
        return 'mine'
    elseif partyIds:contains(claimId) then
        return 'party'
    else
        return 'others'
    end
end

-- Check if an entity should be shown based on filters
local function ShouldShowEntity(entity, entityType, claimStatus, serverId)
    local s = minimapfilter.settings
    local name = entity.Name or ''
    
    -- Type filter
    if entityType == 'monster' and not s.showMonsters then return false end
    if entityType == 'npc' and not s.showNPCs then return false end
    if entityType == 'player' and not s.showPlayers then return false end
    
    -- Claim status filter (only for monsters)
    if entityType == 'monster' then
        if claimStatus == 'unclaimed' and not s.showUnclaimed then return false end
        if claimStatus == 'mine' and not s.showClaimedByMe then return false end
        if claimStatus == 'party' and not s.showClaimedByParty then return false end
        if claimStatus == 'others' and not s.showClaimedByOthers then return false end
    end
    
    -- ID-based filters (take priority over name patterns)
    -- Check if this specific ID is in the hide list
    if #s.hideIds > 0 then
        for _, hideId in ipairs(s.hideIds) do
            if serverId == hideId then
                return false  -- Explicitly hidden by ID
            end
        end
    end
    
    -- Check if we have a show ID list (whitelist by ID)
    if #s.showIds > 0 then
        local idMatched = false
        for _, showId in ipairs(s.showIds) do
            if serverId == showId then
                idMatched = true
                break
            end
        end
        
        -- In whitelist mode with IDs: if not in ID list, hide the entity
        if s.filterMode == 'whitelist' then
            if not idMatched then
                return false  -- Not in whitelist IDs, hide it
            end
            return true  -- In whitelist IDs, show it
        else
            -- In blacklist mode: IDs in showIds are always shown (bypass other checks)
            if idMatched then
                return true
            end
        end
    end
    
    -- Pattern filters (name-based) - only reached if no ID filtering applied
    if s.filterMode == 'whitelist' then
        -- Whitelist mode: only show if matches a pattern (or if no patterns defined)
        if #s.showPatterns > 0 then
            return MatchesAnyPattern(name, s.showPatterns)
        end
        return true
    else
        -- Blacklist mode: hide if matches any hide pattern
        if #s.hidePatterns > 0 and MatchesAnyPattern(name, s.hidePatterns) then
            return false
        end
        return true
    end
end

-- Get the color for an entity based on type, claim status, and optional custom ID color
local function GetEntityColor(entityType, claimStatus, serverId)
    local s = minimapfilter.settings
    
    -- Check for custom ID color first (highest priority)
    if serverId and s.idColors then
        local idKey = tostring(serverId)
        if s.idColors[idKey] then
            return s.idColors[idKey]
        end
    end
    
    if entityType == 'player' then
        return s.playerColor
    elseif entityType == 'npc' then
        return s.npcColor
    elseif entityType == 'monster' then
        if claimStatus == 'mine' then
            return s.claimedByMeColor
        elseif claimStatus == 'party' then
            return s.claimedByPartyColor
        elseif claimStatus == 'others' then
            return s.claimedByOthersColor
        else
            return s.monsterColor
        end
    end
    
    return s.monsterColor
end

-- ============================================================================
-- Minimap Coordinate Conversion
-- ============================================================================

-- Convert world position to minimap screen position
local function WorldToMinimap(entityX, entityY, playerX, playerY, playerHeading)
    local config = minimapfilter.minimapConfig
    
    -- Get scaled frame and mask dimensions
    local frameP = config.frame_p * config.scale_x
    local maskW = config.mask_w * config.scale_x
    local maskH = config.mask_h * config.scale_y
    
    -- The map is drawn inside the mask area, centered within the frame
    -- Map center is at: frame position + frame padding + half of mask size
    local mapCenterX = config.x + frameP + (maskW / 2)
    local mapCenterY = config.y + frameP + (maskH / 2)
    local mapRadius = maskW / 2  -- Circular mask, use width as diameter
    
    -- Calculate relative position from player to entity in world coordinates
    local relX = entityX - playerX
    local relY = entityY - playerY
    
    -- The minimap shows approximately 50 yalms at zoom level 1.0
    -- Higher zoom = smaller view radius = more pixels per yalm
    local viewRadius = 50 / config.zoom  -- World units visible from center
    local pixelsPerYalm = mapRadius / viewRadius
    
    -- Rotation handling based on minimap mode
    local screenOffsetX, screenOffsetY
    
    if config.rotate_map then
        -- Map rotates with player - entities rotate around center based on player heading
        -- When player faces north (heading=0), entity north of player appears at top
        -- When player turns, the map rotates so player always faces "up"
        local cosH = math.cos(playerHeading)
        local sinH = math.sin(playerHeading)
        screenOffsetX = relX * cosH + relY * sinH
        screenOffsetY = -relX * sinH + relY * cosH
    else
        -- Map stays fixed with north up (default mode)
        -- No rotation needed - just convert world coords to screen coords
        -- In FFXI: +X is East, +Y is North
        -- On screen: +X is right, +Y is down
        screenOffsetX = relX   -- East = right
        screenOffsetY = -relY  -- North = up (negative because screen Y is inverted)
    end
    
    -- Convert to screen coordinates
    local screenX = mapCenterX + screenOffsetX * pixelsPerYalm
    local screenY = mapCenterY + screenOffsetY * pixelsPerYalm
    
    -- Check if within minimap bounds (circular mask)
    local distFromCenter = math.sqrt((screenX - mapCenterX)^2 + (screenY - mapCenterY)^2)
    if distFromCenter > mapRadius - 2 then
        return nil, nil  -- Outside minimap circle
    end
    
    return screenX, screenY
end

-- ============================================================================
-- Rendering
-- ============================================================================

local function RenderFilteredEntities()
    if not minimapfilter.settings.enabled then
        return
    end
    
    -- Get player info
    local player = GetPlayerEntity()
    if player == nil then
        return
    end
    
    local playerX = player.Movement.LocalPosition.X
    local playerY = player.Movement.LocalPosition.Y
    local playerHeading = player.Movement.LocalPosition.Yaw
    local playerIndex = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0)
    
    local partyIds = GetPartyMemberIds()
    local playerId = GetPlayerId()
    local entMgr = AshitaCore:GetMemoryManager():GetEntity()
    
    -- Create invisible window over minimap area
    local config = minimapfilter.minimapConfig
    local frameW = config.frame_w * config.scale_x
    local frameH = config.frame_h * config.scale_y
    
    imgui.SetNextWindowPos({ config.x, config.y }, ImGuiCond_Always)
    imgui.SetNextWindowSize({ frameW, frameH }, ImGuiCond_Always)
    
    local windowFlags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoMove,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoInputs,
        ImGuiWindowFlags_NoBackground,
        ImGuiWindowFlags_NoSavedSettings
    )
    
    -- Entity counts for debug
    local counts = { monsters = 0, npcs = 0, players = 0, total = 0 }
    
    if imgui.Begin('MinimapFilterOverlay', true, windowFlags) then
        local drawList = imgui.GetWindowDrawList()
        
        -- Iterate through entities (0x400 = 1024, the max entity count)
        -- Based on scenthound's approach for better performance
        for index = 1, 0x400 do
            -- Skip self
            if index ~= playerIndex then
                local entity = GetEntity(index)
                if entity ~= nil then
                    -- Check render flags directly from entity (more reliable)
                    local isRendered = (bit.band(entity.Render.Flags0, 0x200) == 0x200) and 
                                       (bit.band(entity.Render.Flags0, 0x4000) == 0)
                    
                    -- For NPCs/monsters, check HP; for players, they're always valid if rendered
                    local spawnFlags = entity.SpawnFlags
                    local entityType = GetEntityType(spawnFlags)
                    
                    -- HP check: monsters and NPCs need HP > 0, players don't
                    local isValidEntity = isRendered
                    if entityType == 'monster' then
                        isValidEntity = isRendered and entity.HPPercent > 0
                    elseif entityType == 'npc' then
                        -- Some NPCs (like ??? targets) have 0 HP but should still show
                        isValidEntity = isRendered
                    end
                    
                    if isValidEntity then
                        local claimId = entMgr:GetClaimStatus(index)
                        local claimStatus = GetClaimStatus(claimId, partyIds, playerId)
                        local serverId = entMgr:GetServerId(index)
                        
                        if ShouldShowEntity(entity, entityType, claimStatus, serverId) then
                            local entX = entity.Movement.LocalPosition.X
                            local entY = entity.Movement.LocalPosition.Y
                            
                            local screenX, screenY = WorldToMinimap(
                                entX, entY,
                                playerX, playerY,
                                playerHeading
                            )
                            
                            if screenX and screenY then
                                local color = GetEntityColor(entityType, claimStatus, serverId)
                                local colorU32 = imgui.GetColorU32(color)
                                
                                drawList:AddCircleFilled(
                                    { screenX, screenY },
                                    minimapfilter.settings.dotRadius,
                                    colorU32
                                )
                                
                                -- Count entities drawn
                                counts.total = counts.total + 1
                                if entityType == 'monster' then counts.monsters = counts.monsters + 1
                                elseif entityType == 'npc' then counts.npcs = counts.npcs + 1
                                elseif entityType == 'player' then counts.players = counts.players + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    imgui.End()
    
    lastEntityCounts = counts
end

-- ============================================================================
-- Configuration GUI
-- ============================================================================

local function RenderConfigGui()
    if not minimapfilter.showGui then
        return
    end
    
    imgui.SetNextWindowSize({ 450, 550 }, ImGuiCond_FirstUseEver)
    
    local windowOpen = { true }
    if imgui.Begin('MinimapFilter Settings', windowOpen, ImGuiWindowFlags_None) then
        -- Check if close button was clicked
        if not windowOpen[1] then
            minimapfilter.showGui = false
        end
        
        local s = minimapfilter.settings
        
        -- Enable toggle
        if imgui.Checkbox('Enabled', { s.enabled }) then
            s.enabled = not s.enabled
            settings.save()
            UpdateMinimapPluginState()
        end
        
        imgui.SameLine()
        
        if imgui.Checkbox('Hide Plugin Monster Dots', { s.hidePluginMonsters }) then
            s.hidePluginMonsters = not s.hidePluginMonsters
            settings.save()
            UpdateMinimapPluginState()
        end
        
        imgui.Separator()
        
        -- Entity Type Filters
        if imgui.CollapsingHeader('Entity Type Filters', ImGuiTreeNodeFlags_DefaultOpen) then
            if imgui.Checkbox('Show Monsters', { s.showMonsters }) then
                s.showMonsters = not s.showMonsters
                settings.save()
            end
            imgui.SameLine()
            if imgui.Checkbox('Show NPCs', { s.showNPCs }) then
                s.showNPCs = not s.showNPCs
                settings.save()
            end
            imgui.SameLine()
            if imgui.Checkbox('Show Players', { s.showPlayers }) then
                s.showPlayers = not s.showPlayers
                settings.save()
            end
        end
        
        -- Claim Status Filters
        if imgui.CollapsingHeader('Claim Status Filters (Monsters)', ImGuiTreeNodeFlags_DefaultOpen) then
            if imgui.Checkbox('Unclaimed', { s.showUnclaimed }) then
                s.showUnclaimed = not s.showUnclaimed
                settings.save()
            end
            imgui.SameLine()
            if imgui.Checkbox('Claimed by Me', { s.showClaimedByMe }) then
                s.showClaimedByMe = not s.showClaimedByMe
                settings.save()
            end
            
            if imgui.Checkbox('Claimed by Party', { s.showClaimedByParty }) then
                s.showClaimedByParty = not s.showClaimedByParty
                settings.save()
            end
            imgui.SameLine()
            if imgui.Checkbox('Claimed by Others', { s.showClaimedByOthers }) then
                s.showClaimedByOthers = not s.showClaimedByOthers
                settings.save()
            end
        end
        
        -- Pattern Filters
        if imgui.CollapsingHeader('Name Pattern Filters', ImGuiTreeNodeFlags_DefaultOpen) then
            -- Filter mode
            imgui.Text('Filter Mode:')
            imgui.SameLine()
            if imgui.RadioButton('Blacklist (hide matching)', s.filterMode == 'blacklist') then
                s.filterMode = 'blacklist'
                settings.save()
            end
            imgui.SameLine()
            if imgui.RadioButton('Whitelist (only show matching)', s.filterMode == 'whitelist') then
                s.filterMode = 'whitelist'
                settings.save()
            end
            
            imgui.Separator()
            
            if s.filterMode == 'blacklist' then
                -- Hide patterns
                imgui.Text('Hide Patterns (monsters matching these will be hidden):')
                
                imgui.PushItemWidth(250)
                imgui.InputText('##newHidePattern', guiState.newHidePattern, 256)
                imgui.PopItemWidth()
                imgui.SameLine()
                if imgui.Button('Add##hide') then
                    local pattern = guiState.newHidePattern[1]
                    if pattern and pattern ~= '' then
                        s.hidePatterns:append(pattern)
                        guiState.newHidePattern[1] = ''
                        settings.save()
                    end
                end
                
                -- List existing hide patterns
                for i, pattern in ipairs(s.hidePatterns) do
                    imgui.Text(string.format('%d: %s', i, pattern))
                    imgui.SameLine()
                    if imgui.SmallButton('X##hide' .. i) then
                        table.remove(s.hidePatterns, i)
                        settings.save()
                    end
                end
            else
                -- Show patterns
                imgui.Text('Show Patterns (only monsters matching these will be shown):')
                
                imgui.PushItemWidth(250)
                imgui.InputText('##newShowPattern', guiState.newShowPattern, 256)
                imgui.PopItemWidth()
                imgui.SameLine()
                if imgui.Button('Add##show') then
                    local pattern = guiState.newShowPattern[1]
                    if pattern and pattern ~= '' then
                        s.showPatterns:append(pattern)
                        guiState.newShowPattern[1] = ''
                        settings.save()
                    end
                end
                
                -- List existing show patterns
                for i, pattern in ipairs(s.showPatterns) do
                    imgui.Text(string.format('%d: %s', i, pattern))
                    imgui.SameLine()
                    if imgui.SmallButton('X##show' .. i) then
                        table.remove(s.showPatterns, i)
                        settings.save()
                    end
                end
            end
        end
        
        -- ID Filters
        if imgui.CollapsingHeader('ID Filters') then
            imgui.TextWrapped('Filter by specific entity Server IDs. Use /target <mob> then check the debug panel for the Server ID.')
            
            if s.filterMode == 'blacklist' then
                -- Hide IDs
                imgui.Text('Hide IDs (monsters with these Server IDs will be hidden):')
                
                imgui.PushItemWidth(150)
                imgui.InputText('##newHideId', guiState.newHideId, 32)
                imgui.PopItemWidth()
                imgui.SameLine()
                if imgui.Button('Add##hideId') then
                    local idStr = guiState.newHideId[1]
                    local id = tonumber(idStr)
                    if id then
                        s.hideIds:append(id)
                        guiState.newHideId[1] = ''
                        settings.save()
                    end
                end
                
                -- List existing hide IDs with color pickers
                for i, id in ipairs(s.hideIds) do
                    local idKey = tostring(id)
                    -- Initialize color if not set
                    if not s.idColors[idKey] then
                        s.idColors[idKey] = { 1.0, 0.0, 0.0, 1.0 }  -- Default red
                    end
                    
                    imgui.Text(string.format('%d: %d', i, id))
                    imgui.SameLine()
                    imgui.PushItemWidth(150)
                    if imgui.ColorEdit4('##color' .. idKey, s.idColors[idKey], ImGuiColorEditFlags_NoInputs) then
                        settings.save()
                    end
                    imgui.PopItemWidth()
                    imgui.SameLine()
                    if imgui.SmallButton('X##hideId' .. i) then
                        table.remove(s.hideIds, i)
                        s.idColors[idKey] = nil  -- Remove color too
                        settings.save()
                    end
                end
            else
                -- Show IDs
                imgui.Text('Show IDs (only monsters with these Server IDs will be shown):')
                
                imgui.PushItemWidth(150)
                imgui.InputText('##newShowId', guiState.newShowId, 32)
                imgui.PopItemWidth()
                imgui.SameLine()
                if imgui.Button('Add##showId') then
                    local idStr = guiState.newShowId[1]
                    local id = tonumber(idStr)
                    if id then
                        s.showIds:append(id)
                        guiState.newShowId[1] = ''
                        settings.save()
                    end
                end
                
                -- List existing show IDs with color pickers
                for i, id in ipairs(s.showIds) do
                    local idKey = tostring(id)
                    -- Initialize color if not set
                    if not s.idColors[idKey] then
                        s.idColors[idKey] = { 1.0, 0.0, 0.0, 1.0 }  -- Default red
                    end
                    
                    imgui.Text(string.format('%d: %d', i, id))
                    imgui.SameLine()
                    imgui.PushItemWidth(150)
                    if imgui.ColorEdit4('##color' .. idKey, s.idColors[idKey], ImGuiColorEditFlags_NoInputs) then
                        settings.save()
                    end
                    imgui.PopItemWidth()
                    imgui.SameLine()
                    if imgui.SmallButton('X##showId' .. i) then
                        table.remove(s.showIds, i)
                        s.idColors[idKey] = nil  -- Remove color too
                        settings.save()
                    end
                end
            end
            
            -- Add target's ID button
            if imgui.Button('Add Current Target ID') then
                local targetIndex = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0)
                if targetIndex > 0 then
                    local entMgr = AshitaCore:GetMemoryManager():GetEntity()
                    local serverId = entMgr:GetServerId(targetIndex)
                    if serverId and serverId > 0 then
                        if s.filterMode == 'blacklist' then
                            s.hideIds:append(serverId)
                        else
                            s.showIds:append(serverId)
                        end
                        settings.save()
                        print(chat.header(addon.name):append(chat.message('Added target ID: ' .. serverId)))
                    end
                end
            end
        end
        
        -- Display Settings
        if imgui.CollapsingHeader('Display Settings') then
            local dotRadius = { s.dotRadius }
            if imgui.SliderInt('Dot Radius', dotRadius, 1, 10) then
                s.dotRadius = dotRadius[1]
                settings.save()
            end
            
            imgui.Text('Colors:')
            
            if imgui.ColorEdit4('Unclaimed Monster', s.monsterColor) then
                settings.save()
            end
            if imgui.ColorEdit4('Claimed by Me', s.claimedByMeColor) then
                settings.save()
            end
            if imgui.ColorEdit4('Claimed by Party', s.claimedByPartyColor) then
                settings.save()
            end
            if imgui.ColorEdit4('Claimed by Others', s.claimedByOthersColor) then
                settings.save()
            end
            if imgui.ColorEdit4('NPC', s.npcColor) then
                settings.save()
            end
            if imgui.ColorEdit4('Player', s.playerColor) then
                settings.save()
            end
        end
        
        -- Debug
        if imgui.CollapsingHeader('Debug') then
            if imgui.Checkbox('Debug Mode', { s.debug }) then
                s.debug = not s.debug
                settings.save()
            end
            
            local config = minimapfilter.minimapConfig
            imgui.Text(string.format('Minimap Position: %.1f, %.1f', config.x or 0, config.y or 0))
            imgui.Text(string.format('Minimap Scale: %.2f x %.2f', config.scale_x or 1, config.scale_y or 1))
            imgui.Text(string.format('Minimap Zoom: %.2f', config.zoom or 1))
            imgui.Text(string.format('Theme: %s', config.theme or 'circle'))
            imgui.Text(string.format('Frame: %d x %d (pad: %d)', config.frame_w or 0, config.frame_h or 0, config.frame_p or 0))
            imgui.Text(string.format('Mask: %d x %d', config.mask_w or 0, config.mask_h or 0))
            imgui.Text(string.format('Map Rotation: %s', config.rotate_map and 'On' or 'Off'))
            
            imgui.Separator()
            imgui.Text(string.format('Plugin monsters hidden: %s', lastDrawMonstersState and 'Yes' or 'No'))
            imgui.Text(string.format('Entities drawn: %d (M:%d N:%d P:%d)', 
                lastEntityCounts.total, 
                lastEntityCounts.monsters, 
                lastEntityCounts.npcs, 
                lastEntityCounts.players))
            
            -- Show current target info
            imgui.Separator()
            imgui.Text('Current Target:')
            local targetIndex = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0)
            if targetIndex > 0 then
                local entMgr = AshitaCore:GetMemoryManager():GetEntity()
                local targetName = entMgr:GetName(targetIndex) or 'Unknown'
                local targetServerId = entMgr:GetServerId(targetIndex) or 0
                local targetSpawnFlags = entMgr:GetSpawnFlags(targetIndex) or 0
                imgui.Text(string.format('  Name: %s', targetName))
                imgui.Text(string.format('  Server ID: %d', targetServerId))
                imgui.Text(string.format('  Index: %d', targetIndex))
                imgui.Text(string.format('  SpawnFlags: 0x%04X', targetSpawnFlags))
            else
                imgui.Text('  (No target)')
            end
        end
        
        -- Close button
        imgui.Separator()
        if imgui.Button('Close') then
            minimapfilter.showGui = false
        end
    end
    imgui.End()
end

-- ============================================================================
-- Minimap Plugin Control
-- ============================================================================

local function UpdateMinimapPluginState()
    local s = minimapfilter.settings
    
    -- Determine if we should hide the plugin's monster dots
    local shouldHideMonsters = s.enabled and s.hidePluginMonsters
    
    -- Only send command if state changed
    if shouldHideMonsters ~= lastDrawMonstersState then
        if shouldHideMonsters then
            -- Disable the minimap plugin's monster drawing
            AshitaCore:GetChatManager():QueueCommand(1, '/minimap drawmonsters 0')
            LogDebug('Disabled minimap plugin monster dots')
        else
            -- Re-enable the minimap plugin's monster drawing
            AshitaCore:GetChatManager():QueueCommand(1, '/minimap drawmonsters 1')
            LogDebug('Enabled minimap plugin monster dots')
        end
        lastDrawMonstersState = shouldHideMonsters
    end
end

-- ============================================================================
-- Event Handlers
-- ============================================================================

ashita.events.register('load', 'minimapfilter_load', function()
    minimapfilter.settings = settings.load(defaultSettings)
    minimapfilter.minimapConfig = ReadMinimapConfig()
    minimapfilter.initialized = true
    
    -- Initial state update (delayed to ensure minimap plugin is loaded)
    ashita.tasks.once(1, function()
        UpdateMinimapPluginState()
    end)
    
    LogMessage('Loaded. Use /mmf to open settings.')
end)

ashita.events.register('unload', 'minimapfilter_unload', function()
    settings.save()
    
    -- Restore minimap plugin monster dots
    AshitaCore:GetChatManager():QueueCommand(1, '/minimap drawmonsters 1')
end)

ashita.events.register('command', 'minimapfilter_command', function(e)
    local args = e.command:args()
    if #args == 0 then
        return
    end
    
    local cmd = args[1]:lower()
    if cmd ~= '/mmf' and cmd ~= '/minimapfilter' then
        return
    end
    
    e.blocked = true
    
    if #args == 1 then
        -- Toggle GUI
        minimapfilter.showGui = not minimapfilter.showGui
        return
    end
    
    local subcmd = args[2]:lower()
    
    if subcmd == 'add' or subcmd == 'show' then
        -- Add a show pattern
        if #args >= 3 then
            local pattern = table.concat(args, ' ', 3)
            minimapfilter.settings.showPatterns:append(pattern)
            settings.save()
            LogMessage('Added show pattern: %s', pattern)
        else
            LogError('Usage: /mmf add <pattern>')
        end
        
    elseif subcmd == 'hide' then
        -- Add a hide pattern
        if #args >= 3 then
            local pattern = table.concat(args, ' ', 3)
            minimapfilter.settings.hidePatterns:append(pattern)
            settings.save()
            LogMessage('Added hide pattern: %s', pattern)
        else
            LogError('Usage: /mmf hide <pattern>')
        end
        
    elseif subcmd == 'remove' then
        -- Remove a pattern from either list
        if #args >= 3 then
            local pattern = table.concat(args, ' ', 3):lower()
            local removed = false
            
            for i = #minimapfilter.settings.showPatterns, 1, -1 do
                if minimapfilter.settings.showPatterns[i]:lower() == pattern then
                    table.remove(minimapfilter.settings.showPatterns, i)
                    removed = true
                end
            end
            
            for i = #minimapfilter.settings.hidePatterns, 1, -1 do
                if minimapfilter.settings.hidePatterns[i]:lower() == pattern then
                    table.remove(minimapfilter.settings.hidePatterns, i)
                    removed = true
                end
            end
            
            if removed then
                settings.save()
                LogMessage('Removed pattern: %s', pattern)
            else
                LogError('Pattern not found: %s', pattern)
            end
        else
            LogError('Usage: /mmf remove <pattern>')
        end
        
    elseif subcmd == 'clear' then
        minimapfilter.settings.showPatterns = T{}
        minimapfilter.settings.hidePatterns = T{}
        minimapfilter.settings.showIds = T{}
        minimapfilter.settings.hideIds = T{}
        settings.save()
        LogMessage('Cleared all patterns and IDs')
        
    elseif subcmd == 'addid' or subcmd == 'showid' then
        -- Add a show ID
        if #args >= 3 then
            local id = tonumber(args[3])
            if id then
                minimapfilter.settings.showIds:append(id)
                settings.save()
                LogMessage('Added show ID: %d', id)
            else
                LogError('Invalid ID: %s', args[3])
            end
        else
            LogError('Usage: /mmf addid <id>')
        end
        
    elseif subcmd == 'hideid' then
        -- Add a hide ID
        if #args >= 3 then
            local id = tonumber(args[3])
            if id then
                minimapfilter.settings.hideIds:append(id)
                settings.save()
                LogMessage('Added hide ID: %d', id)
            else
                LogError('Invalid ID: %s', args[3])
            end
        else
            LogError('Usage: /mmf hideid <id>')
        end
        
    elseif subcmd == 'removeid' then
        -- Remove an ID from either list
        if #args >= 3 then
            local id = tonumber(args[3])
            if id then
                local removed = false
                
                for i = #minimapfilter.settings.showIds, 1, -1 do
                    if minimapfilter.settings.showIds[i] == id then
                        table.remove(minimapfilter.settings.showIds, i)
                        removed = true
                    end
                end
                
                for i = #minimapfilter.settings.hideIds, 1, -1 do
                    if minimapfilter.settings.hideIds[i] == id then
                        table.remove(minimapfilter.settings.hideIds, i)
                        removed = true
                    end
                end
                
                if removed then
                    settings.save()
                    LogMessage('Removed ID: %d', id)
                else
                    LogError('ID not found: %d', id)
                end
            else
                LogError('Invalid ID: %s', args[3])
            end
        else
            LogError('Usage: /mmf removeid <id>')
        end
        
    elseif subcmd == 'clearids' then
        minimapfilter.settings.showIds = T{}
        minimapfilter.settings.hideIds = T{}
        settings.save()
        LogMessage('Cleared all IDs')
        
    elseif subcmd == 'targetid' then
        -- Add current target's ID
        local targetIndex = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0)
        if targetIndex > 0 then
            local entMgr = AshitaCore:GetMemoryManager():GetEntity()
            local serverId = entMgr:GetServerId(targetIndex)
            if serverId and serverId > 0 then
                if minimapfilter.settings.filterMode == 'blacklist' then
                    minimapfilter.settings.hideIds:append(serverId)
                    LogMessage('Added target to hide IDs: %d', serverId)
                else
                    minimapfilter.settings.showIds:append(serverId)
                    LogMessage('Added target to show IDs: %d', serverId)
                end
                settings.save()
            else
                LogError('Could not get target ID')
            end
        else
            LogError('No target')
        end
        
    elseif subcmd == 'reload' then
        minimapfilter.settings = settings.load(defaultSettings)
        minimapfilter.minimapConfig = ReadMinimapConfig()
        LogMessage('Settings reloaded')
        
    elseif subcmd == 'toggle' then
        minimapfilter.settings.enabled = not minimapfilter.settings.enabled
        settings.save()
        UpdateMinimapPluginState()
        LogMessage('Filter %s', minimapfilter.settings.enabled and 'enabled' or 'disabled')
        
    else
        LogMessage('Commands:')
        LogMessage('  /mmf - Toggle GUI')
        LogMessage('  /mmf add <pattern> - Add show pattern')
        LogMessage('  /mmf hide <pattern> - Add hide pattern')
        LogMessage('  /mmf remove <pattern> - Remove pattern')
        LogMessage('  /mmf addid <id> - Add show ID')
        LogMessage('  /mmf hideid <id> - Add hide ID')
        LogMessage('  /mmf removeid <id> - Remove ID')
        LogMessage('  /mmf targetid - Add current target ID')
        LogMessage('  /mmf clear - Clear all patterns and IDs')
        LogMessage('  /mmf clearids - Clear all IDs')
        LogMessage('  /mmf reload - Reload settings')
        LogMessage('  /mmf toggle - Toggle filter on/off')
    end
end)

-- Throttle config file reads
local lastConfigRead = 0
local configReadInterval = 2.0  -- Read config every 2 seconds

ashita.events.register('d3d_present', 'minimapfilter_render', function()
    if not minimapfilter.initialized then
        return
    end
    
    -- Periodically refresh minimap config (in case user moves minimap)
    local now = os.clock()
    if now - lastConfigRead > configReadInterval then
        minimapfilter.minimapConfig = ReadMinimapConfig()
        lastConfigRead = now
    end
    
    -- Render filtered entities on the minimap
    RenderFilteredEntities()
    
    -- Render configuration GUI
    RenderConfigGui()
    
    -- Update minimap plugin state if needed
    UpdateMinimapPluginState()
end)

-- Settings update callback
settings.register('settings', 'minimapfilter_settings_update', function(s)
    if s ~= nil then
        minimapfilter.settings = s
    end
end)
