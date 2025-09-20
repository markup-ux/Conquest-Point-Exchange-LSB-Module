-----------------------------------
-- CP Exchange (Autospawn next to Signet/Conquest guards)
--
-- What it does:
--   • Auto-spawns a “CP Exchange” NPC beside every Signet/Conquest guard on zone load (no per-NPC edits).
--   • Converts Conquest Points into endgame currencies: Dynamis (singles/100s), Alexandrite, Cruor,
--     Heavy Metal Plate, Riftdross/Riftcinder, Nyzul Tokens, Therion Ichor.
--   • Paged quantity menus up to 5000 with a MAX option that asks “Are you sure?” before spending.
--   • Safer flow: pre-checks inventory space and refunds CP on unexpected failures.
--
-- Why it was created:
--   • Once players hit 75/max level they’re less likely to join lower-level groups; CP often goes unused.
--     Making CP a valuable sink encourages capped players to engage in low/mid content and helps group formation.
-----------------------------------

package.path = package.path .. ';./?.lua' .. ';./?/init.lua'

require('modules/module_utils')
require('scripts/globals/conquest')   -- xi.conquest.*
require('scripts/enum/item')          -- xi.item.*

local m = Module:new('cp_exchange_autospawn')

-- ======================
-- Exchange rates (approved)
-- ======================
local RATES = {
    -- Dynamis (singles)
    { id='byne',    label='Byne Bill',          type='item',     itemId=xi.item.ONE_BYNE_BILL,         cp_per_unit=50 },
    { id='obronze', label='O. Bronzepiece',     type='item',     itemId=xi.item.ORDELLE_BRONZEPIECE,   cp_per_unit=50 },
    { id='twhite',  label='T. Whiteshell',      type='item',     itemId=xi.item.TUKUKU_WHITESHELL,     cp_per_unit=50 },
    -- Dynamis (100s)
    { id='100byne', label='100 Byne Bill',      type='item',     itemId=xi.item.ONE_HUNDRED_BYNE_BILL, cp_per_unit=5000 },
    { id='msilver', label='M. Silverpiece',     type='item',     itemId=xi.item.MONTIONT_SILVERPIECE,  cp_per_unit=5000 },
    { id='ljade',   label='L. Jadeshell',       type='item',     itemId=xi.item.LUNGO_NANGO_JADESHELL, cp_per_unit=5000 },
    -- Alexandrite
    { id='alex',    label='Alexandrite',        type='item',     itemId=xi.item.ALEXANDRITE,           cp_per_unit=60 },
    -- Cruor
    { id='cruor',   label='Cruor',              type='currency', key='cruor',                          cp_per_unit=1,  out_mult=1 },
    -- Empyrean + misc
    { id='hmp',     label='Heavy Metal Plate',  type='item',     itemId=xi.item.PLATE_OF_HEAVY_METAL,  cp_per_unit=1000 },
    { id='dross',   label='Riftdross',          type='item',     itemId=xi.item.CLUMP_OF_RIFTDROSS,    cp_per_unit=7500 },
    { id='cinder',  label='Riftcinder',         type='item',     itemId=xi.item.PINCH_OF_RIFTCINDER,   cp_per_unit=10000 },
    { id='nyzul',   label='Nyzul Tokens',       type='currency', key='nyzul_isle_tokens',              cp_per_unit=1,  out_mult=1 },
    { id='ichor',   label='Therion Ichor',      type='currency', key='therion_ichor',                  cp_per_unit=10, out_mult=1 },
}

-- Quantity choices up to 5000 (paged to fit client caps)
local UNITS_CHOICES  = { 1, 10, 50, 99, 100, 250, 500, 1000, 2500, 5000 }
local UNITS_PER_PAGE = 4   -- Prev + 4 nums + MAX + Next + Back = <= 8 entries

-- ======================
-- Menu state + helpers
-- ======================
local menu  = { title = 'CP Exchange', options = {} }
local page1, page2, page3 = {}, {}, {}
local currentNpc = nil

local function delaySendMenu(player)
    player:timer(50, function(p) p:customMenu(menu) end)
end

local function printLine(p, npc, text)
    local name = (npc and npc.getPacketName and npc:getPacketName()) or 'CP Exchange'
    p:printToPlayer(text, 0, name)
end

local function getCP(p)
    if p.getCP then return p:getCP() or 0 end
    if p.getCurrency then return p:getCurrency('conquest_points') or 0 end
    return 0
end

local function takeCP(p, amount)
    if amount <= 0 then return end
    if p.delCP       then p:delCP(amount) return end
    if p.delCurrency then p:delCurrency('conquest_points', amount) end
end

local function canAfford(p, r, units)
    local need = r.cp_per_unit * units
    return getCP(p) >= need, need
end

local function rateById(id)
    for _, r in ipairs(RATES) do if r.id == id then return r end end
end

local function formatRateLine(r)
    if r.type == 'currency' then
        return string.format('- %s: %d CP -> %d %s', r.label, r.cp_per_unit, (r.out_mult or 1), r.label)
    else
        return string.format('- %s: %d CP -> 1 %s', r.label, r.cp_per_unit, r.label)
    end
end

local function giveOut(p, r, units)
    if r.type == 'currency' then
        local total = units * (r.out_mult or 1)
        p:addCurrency(r.key, total)
        return total
    else
        if (p:getFreeSlotsCount() or 0) <= 0 then
            return false, 'You need at least 1 free inventory slot.'
        end
        local remain = units
        while remain > 0 do
            local give = math.min(remain, 99)
            if not p:addItem(r.itemId, give) then
                return false, 'Inventory full or item could not be added.'
            end
            remain = remain - give
        end
        return true
    end
end

-- Refund + space preflight
local function refundCP(p, amount)
    if amount <= 0 then return end
    if p.addCP then p:addCP(amount)
    elseif p.addCurrency then p:addCurrency('conquest_points', amount) end
end

-- Rough check for required empty slots for stackables (99 per stack)
local function hasSpaceFor(p, itemId, units)
    local stacksNeeded = math.ceil(units / 99)
    local free = p:getFreeSlotsCount() or 0
    return free >= stacksNeeded, stacksNeeded, free
end

-- Forward declaration so confirm helper can call it
local showUnitsPage

-- Confirm screen for MAX
local function showConfirmMax(player, rate, pageIndex, backPage)
    local cp = getCP(player)
    local u  = math.floor(cp / rate.cp_per_unit)
    if rate.type == 'item' then u = math.min(u, 12 * 99) end

    if u <= 0 then
        printLine(player, currentNpc, 'You cannot afford any units right now.')
        return
    end

    -- Preflight space for items before spending CP
    if rate.type == 'item' then
        local ok, needSlots, free = hasSpaceFor(player, rate.itemId, u)
        if not ok then
            printLine(player, currentNpc,
                ('Not enough inventory space: need %d empty slot(s), you have %d. No CP spent.'):format(needSlots, free))
            return
        end
    end

    local need = rate.cp_per_unit * u
    local outDesc, outCount
    if rate.type == 'currency' then
        outCount = (rate.out_mult or 1) * u
        outDesc  = string.format('%d %s', outCount, rate.label)
    else
        outCount = u
        outDesc  = string.format('%d %s', u, rate.label)
    end

    local opts = {}
    local function push(lbl, fn) table.insert(opts, { lbl, fn }) end

    push(('Yes - spend %d CP for %s'):format(need, outDesc), function(pp)
        takeCP(pp, need)
        local ok, err = giveOut(pp, rate, u)
        if ok == false then
            refundCP(pp, need)
            printLine(pp, currentNpc,
                ('Conversion failed: %s. CP refunded: %d.'):format(err or 'inventory/cap issue', need))
        else
            if rate.type == 'currency' then
                printLine(pp, currentNpc, ('Converted %d CP -> %d %s.'):format(need, outCount, rate.label))
            else
                printLine(pp, currentNpc, ('Converted %d CP -> %d %s.'):format(need, outCount, rate.label))
            end
        end
        showUnitsPage(pp, rate, pageIndex, backPage)
    end)

    push('No - go back', function(pp)
        showUnitsPage(pp, rate, pageIndex, backPage)
    end)

    menu.options = opts
    delaySendMenu(player)
end

-- Quantity page (paged)
showUnitsPage = function(player, rate, pageIndex, backPage)
    printLine(player, currentNpc, formatRateLine(rate))

    local opts = {}
    local function push(lbl, fn) table.insert(opts, { lbl, fn }) end

    local start = (pageIndex - 1) * UNITS_PER_PAGE + 1
    local stop  = math.min(#UNITS_CHOICES, start + UNITS_PER_PAGE - 1)
    local hasPrev = start > 1
    local hasNext = stop  < #UNITS_CHOICES

    if hasPrev then push('<< Prev', function(pp) showUnitsPage(pp, rate, pageIndex - 1, backPage) end) end

    for i = start, stop do
        local u = UNITS_CHOICES[i]
        push(('Buy x%d'):format(u), function(pp)
            local ok, need = canAfford(pp, rate, u)
            if not ok then
                printLine(pp, currentNpc, ('Not enough CP. Need %d CP for x%d.'):format(need, u))
                return
            end

            if rate.type == 'item' then
                local spaceOK, slotsNeeded, free = hasSpaceFor(pp, rate.itemId, u)
                if not spaceOK then
                    printLine(pp, currentNpc,
                        ('Not enough inventory space: need %d empty slot(s), you have %d. No CP spent.'):format(slotsNeeded, free))
                    return
                end
            end

            takeCP(pp, need)
            local out, err = giveOut(pp, rate, u)
            if out == false then
                refundCP(pp, need)
                printLine(pp, currentNpc,
                    ('Conversion failed: %s. CP refunded: %d.'):format(err or 'inventory/cap issue', need))
                return
            end

            if rate.type == 'currency' then
                printLine(pp, currentNpc, ('Converted %d CP -> %d %s.'):format(need, out, rate.label))
            else
                printLine(pp, currentNpc, ('Converted %d CP -> %d %s.'):format(need, u, rate.label))
            end
        end)
    end

    push('MAX', function(pp)
        showConfirmMax(pp, rate, pageIndex, backPage)
    end)

    if hasNext then push('Next >>', function(pp) showUnitsPage(pp, rate, pageIndex + 1, backPage) end) end

    push('<< Back', function(pp)
        if backPage == 1 then menu.options = page1
        elseif backPage == 2 then menu.options = page2
        else                      menu.options = page3 end
        delaySendMenu(pp)
    end)

    menu.options = opts
    delaySendMenu(player)
end

-- Root pages (≤ 8 entries each) in required order
page1 = {
    { 'Rates & Info', function(p)
        printLine(p, currentNpc, 'Exchange Rates:')
        for _, r in ipairs(RATES) do printLine(p, currentNpc, '  ' .. formatRateLine(r)) end
        printLine(p, currentNpc, 'Tip: In the quantity menu, use "MAX" to spend as much CP as you can afford.')
    end },
    { 'Your CP', function(p) local cp = getCP(p); printLine(p, currentNpc, ('You currently have %d CP.'):format(cp)) end },

    { 'Byne Bill',      function(p) showUnitsPage(p, rateById('byne'),    1, 1) end },
    { 'O. Bronzepiece', function(p) showUnitsPage(p, rateById('obronze'), 1, 1) end },
    { 'T. Whiteshell',  function(p) showUnitsPage(p, rateById('twhite'),  1, 1) end },
    { '100 Byne Bill',  function(p) showUnitsPage(p, rateById('100byne'), 1, 1) end },
    { 'M. Silverpiece', function(p) showUnitsPage(p, rateById('msilver'), 1, 1) end },
    { 'Next >>',        function(p) menu.options = page2; delaySendMenu(p) end },
}
page2 = {
    { '<< Prev',        function(p) menu.options = page1; delaySendMenu(p) end },
    { 'L. Jadeshell',   function(p) showUnitsPage(p, rateById('ljade'), 1, 2) end },
    { 'Alexandrite',    function(p) showUnitsPage(p, rateById('alex'),  1, 2) end },
    { 'Cruor',          function(p) showUnitsPage(p, rateById('cruor'), 1, 2) end },
    { 'Heavy Metal Plate', function(p) showUnitsPage(p, rateById('hmp'),   1, 2) end },
    { 'Riftdross',         function(p) showUnitsPage(p, rateById('dross'), 1, 2) end },
    { 'Next >>',        function(p) menu.options = page3; delaySendMenu(p) end },
}
page3 = {
    { '<< Prev',       function(p) menu.options = page2; delaySendMenu(p) end },
    { 'Riftcinder',    function(p) showUnitsPage(p, rateById('cinder'), 1, 3) end },
    { 'Nyzul Tokens',  function(p) showUnitsPage(p, rateById('nyzul'),  1, 3) end },
    { 'Therion Ichor', function(p) showUnitsPage(p, rateById('ichor'),  1, 3) end },
}

-- ======================
-- Spawner (handler-first; optional name fallback)
-- ======================
local spawnedForGuard = {}  -- key: "zoneId:npcId"

local GUARD_NAME_PATTERNS = {
    'Conquest Overseer',
    'Gate Guard',
}

local function nameLooksLikeGuard(name)
    if not name or name == '' then return false end
    for _, pat in ipairs(GUARD_NAME_PATTERNS) do
        if string.find(name, pat, 1, true) then return true end
    end
    return false
end

local function spawnExchangeBeside(guardNpc)
    local zone = guardNpc and guardNpc:getZone()
    if not zone or not zone.insertDynamicEntity then return end
    local key = tostring(zone:getID()) .. ':' .. tostring(guardNpc:getID())
    if spawnedForGuard[key] then return end

    zone:insertDynamicEntity({
        objtype  = xi.objType.NPC,
        name     = 'CP Exchange',
        look     = 2433, -- book model
        x = guardNpc:getXPos() + 1.2,
        y = guardNpc:getYPos(),
        z = guardNpc:getZPos() + 0.8,
        rotation = guardNpc:getRotPos(),
        widescan = 1,
        onTrigger = function(player, exNpc)
            currentNpc   = exNpc
            menu.title   = 'CP Exchange'
            menu.options = page1
            delaySendMenu(player)
        end,
        onTrade = function(player, exNpc, trade)
            printLine(player, exNpc, 'No trades - use the menu to convert CP.')
        end,
    })

    spawnedForGuard[key] = true
end

local function autospawnInZone(zone)
    local function consider(npc)
        -- Handler-based match (authoritative)
        if npc.onTrigger and (npc.onTrigger == xi.conquest.signetOnTrigger or npc.onTrigger == xi.conquest.overseerOnTrigger) then
            spawnExchangeBeside(npc)
            return
        end
        -- Optional: name fallback
        local name = (npc.getPacketName and npc:getPacketName()) or (npc.getName and npc:getName()) or ''
        if nameLooksLikeGuard(name) then spawnExchangeBeside(npc) end
    end

    if zone.forEachEntity then
        zone:forEachEntity(xi.objType.NPC, consider)
    elseif zone.iterateEntities then
        zone:iterateEntities(xi.objType.NPC, consider)
    end
end

-- Hook every zone's onInitialize; scan after a short delay
for zoneName, zoneTbl in pairs(xi.zones or {}) do
    if type(zoneTbl) == 'table' and zoneTbl.Zone and zoneTbl.Zone.onInitialize then
        m:addOverride(string.format('xi.zones.%s.Zone.onInitialize', zoneName), function(zone)
            super(zone)
            zone:timer(200, function(z) autospawnInZone(z) end)
        end)
    end
end

-- Optional safety net: spawn on first click if anything was missed
do
    local oldSignet   = xi.conquest.signetOnTrigger
    local oldOverseer = xi.conquest.overseerOnTrigger
    if oldSignet then
        xi.conquest.signetOnTrigger = function(player, npc, ...)
            spawnExchangeBeside(npc)
            return oldSignet(player, npc, ...)
        end
    end
    if oldOverseer then
        xi.conquest.overseerOnTrigger = function(player, npc, ...)
            spawnExchangeBeside(npc)
            return oldOverseer(player, npc, ...)
        end
    end
end

return m
