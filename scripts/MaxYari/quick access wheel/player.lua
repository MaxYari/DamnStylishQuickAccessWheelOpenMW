-- Quick Access Wheel: two wheels of favourites, spells in the bottom-left corner and weapons in
-- the bottom-right, next to (not instead of) the vanilla quick keys.
--
-- Hold Ready Magic (R) or Ready Weapon (F) to open a wheel, steer its arrow with the mouse and let
-- go of the key to equip what it points at. Quick Menu (F1) together with either key, in either
-- order, adds the current spell or weapon to that wheel, or removes it when it is already there; a
-- right click removes the slot the arrow points at. A short press of R/F is still the vanilla
-- ready / put away, and Quick Menu alone opens the quick keys menu as it is let go. Everything goes
-- by those controls, so it follows whatever keys they are bound to.
--
-- Those controls can't be intercepted: the builtin controls script has already toggled the stance
-- (or opened the quick keys menu) by the time this script hears about the press. A stance only
-- reaches the animation later in the frame, and a menu only opens at the end of it, so the toggle
-- is undone (or the menu closed) on the spot and redone at release if the press calls for it.
--
-- While a wheel is open the arm on its side holds a pose. On the spell wheel
-- the casting hand's fingertips glow with the pointed spell's magic; on the weapon wheel the
-- pointed weapon is drawn once the hand has rested on it.
--
-- Engine calls: one Actor.getStance per frame (the stance before a press, see onFrame). Everything
-- else runs only while R/F is held, while a wheel is open, or for a moment after it equips.

-- Mod version, published to Nexus by .github/workflows/nexus-release.yml
-- (the first `version = ...` in this file)
local VERSION = "1.0"

local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local input = require('openmw.input')
local ui = require('openmw.ui')
local util = require('openmw.util')
local storage = require('openmw.storage')
local camera = require('openmw.camera')
local ambient = require('openmw.ambient')
local async = require('openmw.async')
local animation = require('openmw.animation')
local vfs = require('openmw.vfs')
local I = require('openmw.interfaces')

local mp = 'scripts/MaxYari/quick access wheel/'
require(mp .. 'settings')
-- Which corrected pose goes with which idle, see poseFor.
local POSE_FIXES = require(mp .. 'pose_fixes')

local settings = storage.playerSection('SettingsQuickAccessWheel')
local lookSettings = storage.playerSection('SettingsQuickAccessWheelLook')
local handSettings = storage.playerSection('SettingsQuickAccessWheelHands')
-- The names of the keys Quick Menu, Ready Magic and Ready Weapon are bound to, each learned the
-- first time it is pressed.
local keyNames = storage.playerSection('QuickAccessWheelKeys')

local Actor = types.Actor
local Player = types.Player
local STANCE = Actor.STANCE
local SLOT = Actor.EQUIPMENT_SLOT
local SWITCH = Player.CONTROL_SWITCH
local v2 = util.vector2

local MAX_SLOTS = 12
-- The mouse pushes a virtual stick; this is its reach in mouse pixels at sensitivity 1. The arrow
-- shows once the stick is out past DEADZONE of it. Pulling back toward the corner hides it again,
-- and letting go of the key then changes nothing.
local STICK_RADIUS = 120
local DEADZONE = 0.35
local PAD_DEADZONE = 0.5
local FADE_TIME = 0.12
local DOF_FADE_TIME = 0.3
local STANCE_TIMEOUT = 2
local GU_PER_METRE = 69.99
-- While a wheel is open the mouse steers its arrow; the view still follows it this much.
local LOOK_SCALE = 0.1
local MOD_ID = 'QuickAccessWheel'
local LABEL_PADDING = 6
local TUTORIAL_WIDTH = 380
-- Seconds of real time a wheel is open before the tutorial takes its place.
local TUTORIAL_DELAY = 1
-- Right mouse on a slot: a press shorter than CLICK_TIME that doesn't move the slot is a click, and
-- two clicks on the same slot within DOUBLE_CLICK_TIME remove it; held, it moves the slot.
local CLICK_TIME = 0.35
local DOUBLE_CLICK_TIME = 0.5

-- The hand. Must match tools/make_textures.py: frames per atlas, columns, cell size, and the
-- shaft pieces' half length in cell pixels. shaft.png holds the outlines, then the fills.
local ARROW_FRAMES, ARROW_COLS, ARROW_CELL = 64, 8, 64
local SHAFT_HALF_LENGTH = 5
local TEX = 'textures/MaxYari/quick access wheel/'
local ARROW_PATH, SHAFT_PATH, HUB_PATH = TEX .. 'arrow.png', TEX .. 'shaft.png', TEX .. 'hub.png'
-- Slots other than the pointed one fade back this much.
local UNPOINTED_ALPHA = 0.55
-- The hand is worn: large patches along it, from hub to arrowhead, are darker. WEAR_POINTS is a
-- smooth noise curve along the hand (0 = clean, 1 = darkest), WEAR_DARKEN how dark its darkest is.
-- Each shaft piece is shaded flat, so the pieces are short to keep the steps between them small.
local WEAR_POINTS = { 0.2, 0.9, 0.45, 0.0, 0.7, 0.3 }
local WEAR_DARKEN = 0.45

-- The arms. The poses are in Animations/xbase_anim.1st and Animations/xbase_anim, for first and
-- third person; their blend in is set by the .yaml next to each.
local POSE_PRIORITY = animation.PRIORITY.Scripted
-- A quarter-size VFX_Hands (the engine's casting glow), see tools/make_fingertip_vfx.py.
local FINGERTIP_VFX = 'meshes/MaxYari/quick access wheel/fingertip.nif'
local FINGERTIP_VFX_ID = 'QuickAccessWheel_fingertip'
-- Seconds of real time the hand must rest on a weapon before it is drawn, so sweeping across the
-- wheel doesn't pull out every weapon on the way.
local PREVIEW_DELAY = 0.3
-- How long a drawn preview's animation is sped back up to real time.
local PREVIEW_BOOST_TIME = 1.5
-- How long after a preview equip its sounds are listened for, in real seconds: the draw sound comes
-- with the (sped up) draw, an enchantment's with the next mechanics update.
local PREVIEW_SOUND_TIME = 1.0

-- Vanilla inventory backgrounds: the swirl of an enchanted item, the gold glow of an equipped one.
-- The textures carry a 2 px frame of their own; like the inventory, only the 40 px inside is drawn,
-- stretched over the whole slot.
local function iconBackground(path)
    return ui.texture { path = path, offset = v2(2, 2), size = v2(40, 40) }
end
local backgrounds = {
    magic = iconBackground('textures/menu_icon_magic.dds'),
    pointed = iconBackground('textures/menu_icon_equip.dds'),
}

local textures = {}
local function texture(path, offset, size)
    local key = offset and (path .. offset.x .. ',' .. offset.y) or path
    if not textures[key] then
        textures[key] = ui.texture { path = path, offset = offset, size = size }
    end
    return textures[key]
end

-- `firstRow`: where the frames start in the sheet, in rows.
local function frameTexture(path, frame, firstRow)
    local row = firstRow + math.floor(frame / ARROW_COLS)
    return texture(path, v2((frame % ARROW_COLS) * ARROW_CELL, row * ARROW_CELL), v2(ARROW_CELL, ARROW_CELL))
end

local KINDS = {
    spell = {
        action = input.ACTION.ToggleSpell,
        stance = STANCE.Spell,
        switch = SWITCH.Magic,
        actionName = 'ToggleSpell',
        side = 1, -- bottom-left corner, slots to the right of the centre
        pose = 'spellwheelpose',
        poseMask = animation.BLEND_MASK.LeftArm,
        noun = 'spell',
        empty = 'No favourite spells yet',
        nothingCurrent = 'No spell or enchanted item is selected',
    },
    weapon = {
        action = input.ACTION.ToggleWeapon,
        stance = STANCE.Weapon,
        switch = SWITCH.Fighting,
        actionName = 'ToggleWeapon',
        side = -1, -- bottom-right corner, mirrored
        pose = 'weaponwheelpose',
        poseMask = animation.BLEND_MASK.RightArm,
        noun = 'weapon',
        empty = 'No favourite weapons yet',
        nothingCurrent = 'No weapon is equipped',
    },
}
local KIND_BY_ACTION = {
    [input.ACTION.ToggleSpell] = 'spell',
    [input.ACTION.ToggleWeapon] = 'weapon',
}

local ENCHANTABLE = { [types.Weapon] = true, [types.Armor] = true, [types.Clothing] = true, [types.Book] = true }
local WIELDABLE = { [types.Weapon] = true, [types.Lockpick] = true, [types.Probe] = true }
-- Weapons that take both hands: the left hand's shield or torch comes off.
local TWO_HANDED = {
    [types.Weapon.TYPE.LongBladeTwoHand] = true, [types.Weapon.TYPE.BluntTwoClose] = true,
    [types.Weapon.TYPE.BluntTwoWide] = true, [types.Weapon.TYPE.SpearTwoWide] = true,
    [types.Weapon.TYPE.AxeTwoHand] = true, [types.Weapon.TYPE.MarksmanBow] = true,
    [types.Weapon.TYPE.MarksmanCrossbow] = true,
}
-- The engine's draw and put-away sounds per weapon type, "<sound> Up" and "<sound> Down"
-- (mwmechanics/weapontype.cpp).
local WEAPON_SOUNDS = {
    [types.Weapon.TYPE.ShortBladeOneHand] = 'Item Weapon Shortblade',
    [types.Weapon.TYPE.LongBladeOneHand] = 'Item Weapon Longblade',
    [types.Weapon.TYPE.BluntOneHand] = 'Item Weapon Blunt',
    [types.Weapon.TYPE.AxeOneHand] = 'Item Weapon Blunt',
    [types.Weapon.TYPE.LongBladeTwoHand] = 'Item Weapon Longblade',
    [types.Weapon.TYPE.BluntTwoClose] = 'Item Weapon Blunt',
    [types.Weapon.TYPE.AxeTwoHand] = 'Item Weapon Blunt',
    [types.Weapon.TYPE.BluntTwoWide] = 'Item Weapon Blunt',
    [types.Weapon.TYPE.SpearTwoWide] = 'Item Weapon Spear',
    [types.Weapon.TYPE.MarksmanBow] = 'Item Weapon Bow',
    [types.Weapon.TYPE.MarksmanCrossbow] = 'Item Weapon Crossbow',
    [types.Weapon.TYPE.MarksmanThrown] = 'Item Weapon Blunt',
}

-- The engine's equip and put-away animation groups (mwmechanics/weapontype.cpp). Drawing a weapon
-- from another stance first puts away the spell, fists or weapon in hand, so all of them are sped
-- up for a preview.
local EQUIP_GROUPS = {
    'spellcast', 'handtohand', 'pickprobe', 'weapononehand', 'shortbladeonehand', 'bluntonehand',
    'weapontwohand', 'blunttwohand', 'weapontwowide', 'bowandarrow', 'crossbow', 'throwweapon',
}

-- Favourites per wheel, in slot order: { kind = 'spell' | 'item', id, name, icon, magic }. The name
-- and icon are kept so that a slot can still be drawn after its item is gone.
local favourites = { spell = {}, weapon = {} }

local lastStance = Actor.getStance(self)
local press = nil -- R or F held, wheel not open yet
local wheel = nil -- the open wheel
local pendingStance = nil -- a stance to take once the equip has gone through
local pendingSounds = nil -- a chosen preview's sounds, played once time runs at full speed again
-- Spans of time in which given sounds on the player are stopped as they start: { listen = {id ->
-- whether to note it as heard}, heard = {id -> true}, untilTime }. They outlive the wheel, as the
-- loadout it puts back makes sounds after it closes.
local quietWindows = {}
local menuPress = nil -- Quick Menu held, its menu put off until it is let go
-- A control's key, matched between its action and the key press that caused it, which can come in
-- either order within a frame or two.
local frame = 0
local lastKey = nil -- { code, frame }
local pendingKeyAction = nil -- { name, frame }
local tutorial = nil -- the open tutorial window
local tutorialSeen = false -- per character: kept in the save

-- Favourites -----------------------------------------------------------------

local function spellIcon(spell)
    local effect = spell.effects[1]
    if not effect then return nil end
    local path = core.magic.effects.records[effect.id].icon
    -- Like the vanilla quick keys: the big version of the first effect's icon, when there is one.
    local big = path:gsub('[^/]+$', 'b_%0')
    if vfs.fileExists(big) then return big end
    return path
end

local function spellEntry(spell)
    return { kind = 'spell', id = spell.id, name = spell.name, icon = spellIcon(spell) }
end

local function itemEntry(item)
    local record = item.type.record(item)
    local enchant = ENCHANTABLE[item.type] and record.enchant
    return {
        kind = 'item',
        id = item.recordId,
        name = record.name,
        icon = record.icon,
        magic = enchant ~= nil and enchant ~= '',
    }
end

-- What a Quick Menu combo would add: the selected spell or enchanted item, or the weapon in hand.
local function currentEntry(kindName)
    if kindName == 'spell' then
        local item = Actor.getSelectedEnchantedItem(self)
        if item then return itemEntry(item) end
        local spell = Actor.getSelectedSpell(self)
        if spell then return spellEntry(spell) end
        return nil
    end
    local item = Actor.getEquipment(self, SLOT.CarriedRight)
    if item and WIELDABLE[item.type] then return itemEntry(item) end
    return nil
end

local function indexOf(list, entry)
    if not entry then return nil end
    for i, e in ipairs(list) do
        if e.kind == entry.kind and e.id == entry.id then return i end
    end
    return nil
end

-- Wheel geometry --------------------------------------------------------------
-- Angles are in the wheel's own space: 0 points from the corner along the bottom edge into the
-- screen, pi/2 straight up. The right wheel mirrors it on screen.

local function geometry(side, count)
    local hud = ui.layers[ui.layers.indexOf('HUD')].size
    local offset = hud.y * lookSettings:get('CornerOffset') / 100
    local slot = lookSettings:get('SlotSize')
    local boxSize = slot + 8 -- with the thick vanilla border
    local margin = boxSize / 2 + 4
    local radius = hud.y * lookSettings:get('WheelRadius') / 100

    -- The part of the circle the screen leaves open: a quarter, plus whatever fits past the
    -- edges when the centre sits away from the corner.
    local a0, a1
    local function sector()
        local extra = math.asin(util.clamp((offset - margin) / radius, -1, 1))
        a0, a1 = -extra, math.pi / 2 + extra
    end
    sector()
    -- Grow the wheel until every slot fits side by side.
    local needed = count * boxSize * 1.1
    for _ = 1, 4 do
        if radius * (a1 - a0) >= needed then break end
        radius = needed / (a1 - a0)
        sector()
    end

    return {
        side = side,
        center = v2(side == 1 and offset or hud.x - offset, hud.y - offset),
        radius = radius,
        slot = slot,
        a0 = a0,
        a1 = a1,
        bin = (a1 - a0) / math.max(count, 1),
        -- The arrowhead: just inside the slots, its tip short of their borders.
        arrowRadius = radius - boxSize / 2 - slot * 0.45,
        hubSize = slot * 0.55,
    }
end

local function slotAngle(g, i)
    return g.a1 - (i - 0.5) * g.bin
end

local function screenDirection(g, angle)
    return v2(g.side * math.cos(angle), -math.sin(angle))
end

-- The arrow moves between the first and the last slot, so it never points at empty space.
local function clampToSlots(g, count, angle)
    local low, high = g.a0, g.a1
    if count > 0 then low, high = slotAngle(g, count), slotAngle(g, 1) end
    if angle >= low and angle <= high then return angle end
    local toLow = math.abs(util.normalizeAngle(angle - low))
    local toHigh = math.abs(util.normalizeAngle(angle - high))
    return toLow < toHigh and low or high
end

local function arrowFrame(g, angle)
    local screenAngle = g.side == 1 and angle or math.pi - angle
    return math.floor(screenAngle / (2 * math.pi) * ARROW_FRAMES + 0.5) % ARROW_FRAMES
end

local function stickAngle()
    return math.atan2(wheel.stick.y, wheel.stick.x)
end

local function pointStickAt(i)
    if i then
        local angle = slotAngle(wheel.geo, i)
        wheel.stick = v2(math.cos(angle), math.sin(angle)) * STICK_RADIUS
    else
        wheel.stick = v2(0, 0)
    end
end

local function selectionFromStick()
    local count = #wheel.slots
    if count == 0 or wheel.stick:length() < STICK_RADIUS * DEADZONE then return nil end
    local i = math.floor((wheel.geo.a1 - stickAngle()) / wheel.geo.bin) + 1
    return util.clamp(i, 1, count)
end

local function isAvailable(entry, inventory, spells)
    if entry.kind == 'spell' then return spells[entry.id] ~= nil end
    return inventory:countOf(entry.id) > 0
end

-- Takes the items no longer carried and the spells no longer known off a wheel, as far as the
-- settings ask for it.
local function removeMissing(kindName)
    local removeItems, removeSpells = settings:get('RemoveMissingItems'), settings:get('RemoveMissingSpells')
    if not (removeItems or removeSpells) then return end
    local inventory = Actor.inventory(self)
    local spells = Actor.spells(self)
    local list = favourites[kindName]
    for i = #list, 1, -1 do
        local entry = list[i]
        local remove
        if entry.kind == 'spell' then remove = removeSpells else remove = removeItems end
        if remove and not isAvailable(entry, inventory, spells) then table.remove(list, i) end
    end
end

-- Rebuilds the slots from the favourites. `pointAt`: an entry to put the arrow on, or nil to leave
-- the arrow where it is.
local function refreshSlots(pointAt)
    local list = favourites[wheel.kind]
    local inventory = Actor.inventory(self)
    local spells = Actor.spells(self)
    wheel.slots = {}
    for i, entry in ipairs(list) do
        wheel.slots[i] = { entry = entry, available = isAvailable(entry, inventory, spells) }
    end
    wheel.geo = geometry(KINDS[wheel.kind].side, #list)
    if pointAt then pointStickAt(indexOf(list, pointAt)) end
    wheel.selected = selectionFromStick()
    wheel.dirty = true
end

-- Drawing ----------------------------------------------------------------------

-- `pointed`: the slot the hand points at, glowing like an equipped item and in a thick border.
-- `faded`: another slot is pointed at, so this one steps back.
local function slotLayout(slot, position, size, pointed, faded)
    -- An enchanted item keeps its swirl when pointed at; the thick border marks it.
    local background
    if slot.entry.magic then
        background = backgrounds.magic
    elseif pointed then
        background = backgrounds.pointed
    end
    local inner = ui.content {}
    if background then
        inner:add { type = ui.TYPE.Image, props = { resource = background, relativeSize = v2(1, 1) } }
    end
    if slot.entry.icon then
        local iconSize = math.floor(size * 32 / 42 + 0.5)
        inner:add {
            type = ui.TYPE.Image,
            props = {
                resource = texture(slot.entry.icon),
                size = v2(iconSize, iconSize),
                relativePosition = v2(0.5, 0.5),
                anchor = v2(0.5, 0.5),
                alpha = slot.available and 1 or 0.3,
            },
        }
    end
    return {
        template = pointed and I.MWUI.templates.boxTransparentThick or I.MWUI.templates.boxTransparent,
        props = { position = position, anchor = v2(0.5, 0.5), alpha = faded and UNPOINTED_ALPHA or 1 },
        content = ui.content {
            { type = ui.TYPE.Widget, props = { size = v2(size, size) }, content = inner },
        },
    }
end

local function padded(layout, padding)
    local function gap() return { props = { size = v2(padding, padding) } } end
    return {
        type = ui.TYPE.Flex,
        props = { horizontal = true },
        content = ui.content {
            gap(),
            { type = ui.TYPE.Flex, content = ui.content { gap(), layout, gap() } },
            gap(),
        },
    }
end

-- What a control is bound to: its key once seen pressed, else the control's own name.
local function keyLabel(actionName)
    return keyNames:get(actionName) or core.l10n('OMWControls')(actionName .. '_name')
end

-- A box of text lines in the wheel's own alignment: left on the left wheel, right on the right one.
local function textBox(g, lines, position, anchorY)
    return {
        template = I.MWUI.templates.boxTransparent,
        props = { position = position, anchor = v2(g.side == 1 and 0 or 1, anchorY) },
        content = ui.content {
            padded({
                type = ui.TYPE.Flex,
                props = { arrange = g.side == 1 and ui.ALIGNMENT.Start or ui.ALIGNMENT.End },
                content = lines,
            }, LABEL_PADDING),
        },
    }
end

-- The pointed slot's name (or the empty wheel's note), beside the wheel past its outermost slot and
-- high enough to clear the vanilla message boxes along the bottom of the screen.
local function titleLayout(g, kind)
    local slot = wheel.selected and wheel.slots[wheel.selected]
    local title
    if slot then
        title = slot.entry.name
        if not slot.available then
            title = title .. (slot.entry.kind == 'spell' and '  (no longer known)' or '  (not in inventory)')
        end
    elseif #wheel.slots == 0 then
        title = kind.empty
    else
        return nil
    end
    local lines = ui.content { { template = I.MWUI.templates.textHeader, props = { text = title } } }
    return textBox(g, lines, g.center + v2(g.side * (g.radius + g.slot / 2 + 16), -g.radius * 0.45), 0.5)
end

-- The controls, beside the wheel past its outermost slot, their bottom level with the hub the hand
-- turns on.
local function hintsLayout(g, kind)
    local menuKey = keyLabel('QuickKeysMenu')
    local lines = ui.content {
        {
            template = I.MWUI.templates.textNormal,
            props = { text = string.format('%s: add / remove the current %s', menuKey, kind.noun) },
        },
    }
    if #wheel.slots > 0 then
        lines:add {
            template = I.MWUI.templates.textNormal,
            props = { text = 'Right mouse: hold and steer to move, double click to remove' },
        }
    end
    return textBox(g, lines, g.center + v2(g.side * (g.radius + g.slot / 2 + 16), 0), 1)
end

local function sprite(resource, position, size, color)
    return {
        type = ui.TYPE.Image,
        props = { resource = resource, position = position, anchor = v2(0.5, 0.5), size = v2(size, size), color = color },
    }
end

-- The hand's shade at `t` along it (0 at the hub, 1 at the arrowhead).
local function wearShade(t)
    local x = util.clamp(t, 0, 1) * (#WEAR_POINTS - 1)
    local i = math.min(math.floor(x), #WEAR_POINTS - 2)
    local f = x - i
    f = f * f * (3 - 2 * f)
    local wear = WEAR_POINTS[i + 1] + (WEAR_POINTS[i + 2] - WEAR_POINTS[i + 1]) * f
    local shade = 1 - WEAR_DARKEN * wear
    return util.color.rgb(shade, shade, shade)
end

-- The clock-like hand: a shaft out of the hub with the arrowhead at its end. The shaft is a row
-- of short pre-rotated pieces; all their outlines go down before any of their gold, so the pieces
-- join into one line, and the gold also covers the head's outline where the shaft enters it.
local function addHand(content, g)
    local frame = arrowFrame(g, stickAngle())
    -- Laid out along the frame's own angle, so the pieces line up with how they are drawn.
    local angle = frame / ARROW_FRAMES * 2 * math.pi
    local direction = v2(math.cos(angle), -math.sin(angle))
    local cellSize = g.slot
    local pieceLength = 2 * SHAFT_HALF_LENGTH * cellSize / ARROW_CELL
    local from, to = g.hubSize * 0.3, g.arrowRadius
    local span = math.max(0, to - from - pieceLength)
    local count = math.ceil(span / (pieceLength * 0.85)) + 1
    local pieces, shades = {}, {}
    for i = 1, count do
        local t = count == 1 and 0.5 or (i - 1) / (count - 1)
        local distance = from + pieceLength / 2 + t * span
        pieces[i] = g.center + direction * distance
        shades[i] = wearShade(distance / g.arrowRadius)
    end
    local rows = ARROW_FRAMES / ARROW_COLS
    for _, position in ipairs(pieces) do content:add(sprite(frameTexture(SHAFT_PATH, frame, 0), position, cellSize)) end
    content:add(sprite(frameTexture(ARROW_PATH, frame, 0), g.center + direction * g.arrowRadius, cellSize, wearShade(1)))
    for i, position in ipairs(pieces) do
        content:add(sprite(frameTexture(SHAFT_PATH, frame, rows), position, cellSize, shades[i]))
    end
end

local function render()
    local g = wheel.geo
    local content = ui.content {}
    for i, slot in ipairs(wheel.slots) do
        local position = g.center + screenDirection(g, slotAngle(g, i)) * g.radius
        local pointed = i == wheel.selected
        content:add(slotLayout(slot, position, g.slot, pointed, wheel.selected ~= nil and not pointed))
    end
    if wheel.selected then addHand(content, g) end
    content:add(sprite(texture(HUB_PATH), g.center, g.hubSize, wearShade(0)))
    local title = titleLayout(g, KINDS[wheel.kind])
    if title then content:add(title) end
    content:add(hintsLayout(g, KINDS[wheel.kind]))

    local layout = {
        layer = 'HUD',
        type = ui.TYPE.Widget,
        props = { relativeSize = v2(1, 1), alpha = wheel.alpha },
        content = content,
    }
    if wheel.element then
        wheel.element.layout = layout
        wheel.element:update()
    else
        wheel.element = ui.create(layout)
    end
end

-- Equipping --------------------------------------------------------------------

local function requestStance(stance, waitForRecordId)
    pendingStance = { stance = stance, waitFor = waitForRecordId, deadline = core.getRealTime() + STANCE_TIMEOUT }
end

local function updatePendingStance()
    local pending = pendingStance
    if Actor.getStance(self) == pending.stance or core.getRealTime() > pending.deadline then
        pendingStance = nil
        return
    end
    if pending.waitFor then
        -- An equip lands a frame later: UseItem goes through a global script, setEquipment is
        -- applied at the end of the frame.
        local held = Actor.getEquipment(self, SLOT.CarriedRight)
        if not (held and held.recordId == pending.waitFor) then return end
    end
    -- Retried each frame: refused while an attack can't be interrupted, or for magic until the
    -- newly selected spell is applied.
    Actor.setStance(self, pending.stance)
end

local function useSlot(kindName, slot)
    local kind = KINDS[kindName]
    local entry = slot.entry
    if entry.kind == 'spell' then
        if not Actor.spells(self)[entry.id] then
            ui.showMessage(entry.name .. ' is no longer known')
            return
        end
        Actor.setSelectedSpell(self, entry.id)
        requestStance(kind.stance)
        return
    end

    local item = Actor.inventory(self):find(entry.id)
    if not item then
        ui.showMessage(entry.name .. ' is not in your inventory')
        return
    end
    if kindName == 'spell' then
        -- Puts the item on first when it has to be worn, like the vanilla quick keys.
        Actor.setSelectedEnchantedItem(self, item)
        requestStance(kind.stance)
        return
    end
    local held = Actor.getEquipment(self, SLOT.CarriedRight)
    if held and held.recordId == entry.id then
        requestStance(kind.stance)
    else
        -- The inventory's own equip: swaps out a shield for a two-hander, plays the sound.
        core.sendGlobalEvent('UseItem', { object = item, actor = self })
        requestStance(kind.stance, entry.id)
    end
end

-- The arms ----------------------------------------------------------------------

-- The poses were made over a chest standing about straight up. Drawn weapons whose idles turn it
-- far away (the spear's, the dagger's...) get a corrected pose, <pose>_fix<n>, with the arm
-- re-solved to end up in the same place on screen; idles with alike chests share one
-- (tools/make_pose_variants.py, which also writes pose_fixes.lua). With a weapon or spell readied
-- the chest keeps playing the idle while walking; anything else on it (an equip, say) keeps the
-- pose already chosen.
local function poseFor(torso)
    local kind = KINDS[wheel.kind]
    if torso:sub(1, 4) ~= 'idle' then return wheel.pose or kind.pose end
    local fix = POSE_FIXES[torso]
    local corrected = fix and kind.pose .. '_' .. fix
    if corrected and animation.hasGroup(self, corrected) then return corrected end
    return kind.pose
end

local function updatePose()
    local torso = animation.getActiveGroup(self, animation.BONE_GROUP.Torso)
    if torso == wheel.torso then return end
    wheel.torso = torso
    local group = poseFor(torso)
    if group == wheel.pose then return end
    if wheel.pose then animation.cancel(self, wheel.pose) end
    I.AnimationController.playBlendedAnimation(group, {
        startKey = 'start',
        stopKey = 'stop',
        priority = POSE_PRIORITY,
        blendMask = KINDS[wheel.kind].poseMask,
        -- Held on its last frame until the wheel closes.
        autoDisable = false,
    })
    wheel.pose = group
end

local function startPose()
    wheel.posePending = false
    if not animation.hasGroup(self, KINDS[wheel.kind].pose) then return end -- a skeleton without the poses
    wheel.posing = true
    updatePose()
end

-- The last joint of each finger of the casting hand, or the one before it on skeletons with
-- two-joint fingers.
local function fingertipBones()
    local bones = {}
    for finger = 0, 4 do
        for _, joint in ipairs({ '2', '1', '' }) do
            local bone = 'Bip01 L Finger' .. finger .. joint
            if animation.hasBone(self, bone) then
                bones[#bones + 1] = bone
                break
            end
        end
    end
    return bones
end

-- The particle texture of a slot's magic, false when it has none to show. Like the engine's own
-- casting glow, from the last effect.
local function slotParticle(slot)
    if slot.particle ~= nil then return slot.particle end
    local effects
    if slot.entry.kind == 'spell' then
        local spell = core.magic.spells.records[slot.entry.id]
        effects = spell and spell.effects
    else
        local item = Actor.inventory(self):find(slot.entry.id)
        local enchant = item and item.type.record(item).enchant
        local enchantment = enchant and enchant ~= '' and core.magic.enchantments.records[enchant]
        effects = enchantment and enchantment.effects
    end
    slot.particle = effects and #effects > 0 and core.magic.effects.records[effects[#effects].id].particle or false
    return slot.particle
end

local function clearFingertips(state)
    for i = 1, state.fingertipCount or 0 do animation.removeVfx(self, FINGERTIP_VFX_ID .. i) end
    state.fingertipCount = 0
    state.fingertipParticle = nil
end

local function updateFingertips()
    local slot = wheel.selected and wheel.slots[wheel.selected]
    local particle = slot and slot.available and slotParticle(slot) or nil
    if particle == wheel.fingertipParticle then return end
    clearFingertips(wheel)
    if not particle then return end
    for i, bone in ipairs(wheel.fingertipBones) do
        animation.addVfx(self, FINGERTIP_VFX, {
            boneName = bone,
            particleTextureOverride = particle,
            loop = true,
            vfxId = FINGERTIP_VFX_ID .. i,
        })
    end
    wheel.fingertipCount = #wheel.fingertipBones
    wheel.fingertipParticle = particle
end

local function setEquipSpeed(speed)
    for _, group in ipairs(EQUIP_GROUPS) do animation.setSpeed(self, group, speed) end
end

-- The draw (up) and put-away (down) sounds of a wielded item.
local function wieldSounds(item)
    local sound
    if types.Weapon.objectIsInstance(item) then
        sound = WEAPON_SOUNDS[types.Weapon.record(item).type]
    elseif types.Lockpick.objectIsInstance(item) then
        sound = 'Item Lockpick'
    elseif types.Probe.objectIsInstance(item) then
        sound = 'Item Probe'
    end
    if not sound then return nil, nil end
    return sound .. ' Up', sound .. ' Down'
end

-- The hit sounds the engine plays as a constant-effect enchantment comes on with its item
-- (mwmechanics/spellcasting.cpp, playEffects): each effect's own, or else its school's.
local function enchantmentSounds(item)
    local sounds = {}
    local enchant = ENCHANTABLE[item.type] and item.type.record(item).enchant
    local enchantment = enchant and enchant ~= '' and core.magic.enchantments.records[enchant]
    if not enchantment or enchantment.type ~= core.magic.ENCHANTMENT_TYPE.ConstantEffect then return sounds end
    for i = 1, #enchantment.effects do
        local effect = core.magic.effects.records[enchantment.effects[i].id]
        local sound = effect.hitSound
        if sound == '' then sound = core.stats.Skill.records[effect.school].school.hitSound end
        sounds[#sounds + 1] = sound
    end
    return sounds
end

-- Puts an item in the right hand (nil: empty it) without the inventory's equip action and its
-- sound, taking the left hand's shield or torch off for a two-hander like that action does.
local function wield(item)
    local equipment = Actor.getEquipment(self)
    equipment[SLOT.CarriedRight] = item
    if item and types.Weapon.objectIsInstance(item) and TWO_HANDED[types.Weapon.record(item).type] then
        equipment[SLOT.CarriedLeft] = nil
    end
    Actor.setEquipment(self, equipment)
end

local function keepQuiet(listen)
    local window = { listen = listen, heard = {}, untilTime = core.getRealTime() + PREVIEW_SOUND_TIME }
    quietWindows[#quietWindows + 1] = window
    return window
end

local function stopKeepingQuiet(window)
    for i, other in ipairs(quietWindows) do
        if other == window then
            table.remove(quietWindows, i)
            return
        end
    end
end

local function updateQuiet(now)
    for i = #quietWindows, 1, -1 do
        local window = quietWindows[i]
        if now > window.untilTime then
            table.remove(quietWindows, i)
        else
            for id, note in pairs(window.listen) do
                if core.sound.isSoundPlaying(id, self) then
                    core.sound.stopSound3d(id, self)
                    if note then window.heard[id] = true end
                end
            end
        end
    end
end

-- The sounds an item makes in the hand: its draw and put-away, and its constant enchantment's.
local function itemSounds(item, listen, note)
    for _, id in ipairs(enchantmentSounds(item)) do listen[id] = listen[id] or note end
    local up, down = wieldSounds(item)
    if up then listen[up] = listen[up] or note end
    if down then listen[down] = listen[down] or false end
end

-- Draws the pointed weapon, for a look at it before letting go. Quietly: the sounds it sets off are
-- stopped as they start (updateQuiet), and its own (the draw, its enchantment coming on) are
-- played if it is the one chosen.
local function previewWeapon(slot)
    local item = Actor.inventory(self):find(slot.entry.id)
    if not item then return end
    local held = Actor.getEquipment(self, SLOT.CarriedRight)
    if not (held and held.recordId == slot.entry.id) then wield(item) end
    requestStance(STANCE.Weapon, slot.entry.id)
    wheel.loadoutChanged = true
    -- The game runs slowed, and so would the draw: its animations are sped back up to real time.
    wheel.boostUntil = core.getRealTime() + PREVIEW_BOOST_TIME

    -- Sound id -> whether it is the preview's own (played if chosen) or just to be kept quiet.
    local listen = {}
    itemSounds(item, listen, true)
    if held then itemSounds(held, listen, false) end
    if wheel.preview then stopKeepingQuiet(wheel.preview) end
    wheel.preview = keepQuiet(listen)
    wheel.preview.entry = slot.entry
end

-- Puts back the weapon, shield or torch and stance the wheel opened with, after previews. Like the
-- previews, without the equip action's sounds.
local function restoreLoadout(state)
    local original = state.original
    local inventory = Actor.inventory(self)
    local equipment = Actor.getEquipment(self)
    local right = equipment[SLOT.CarriedRight]
    if (right and right.recordId) ~= original.right then
        equipment[SLOT.CarriedRight] = original.right and inventory:find(original.right) or nil
    end
    local left = equipment[SLOT.CarriedLeft]
    if original.left and not (left and left.recordId == original.left) then
        -- A two-hander's preview took the shield or torch off.
        equipment[SLOT.CarriedLeft] = inventory:find(original.left)
    end
    Actor.setEquipment(self, equipment)
    requestStance(original.stance, original.stance == STANCE.Weapon and original.right or nil)
    -- Putting things back isn't news: what comes back on (an enchantment, say) and what goes away
    -- are kept quiet too.
    local listen = {}
    for _, item in pairs(equipment) do itemSounds(item, listen, false) end
    if right then itemSounds(right, listen, false) end
    keepQuiet(listen)
end

-- The tutorial -------------------------------------------------------------------

local function closeTutorial()
    tutorial:destroy()
    tutorial = nil
    tutorialSeen = true
    if I.UI.getMode() == I.UI.MODE.Interface then I.UI.removeMode(I.UI.MODE.Interface) end
end

-- Shown the first time a wheel stays open for TUTORIAL_DELAY, in its place: how to open the wheels,
-- and add, remove and move what is on them. A plain interface mode with no windows gives it the
-- cursor.
local function showTutorial()
    I.UI.addMode(I.UI.MODE.Interface, { windows = {} })
    local magic, weapon, menu = keyLabel('ToggleSpell'), keyLabel('ToggleWeapon'), keyLabel('QuickKeysMenu')
    local function paragraph(text)
        return { template = I.MWUI.templates.textParagraph, props = { text = text, size = v2(TUTORIAL_WIDTH, 0) } }
    end
    local function gap() return { props = { size = v2(0, 10) } } end
    tutorial = ui.create {
        layer = 'Windows',
        template = I.MWUI.templates.boxSolidThick,
        props = { relativePosition = v2(0.5, 0.5), anchor = v2(0.5, 0.5) },
        content = ui.content {
            padded({
                type = ui.TYPE.Flex,
                props = { arrange = ui.ALIGNMENT.Center },
                content = ui.content {
                    { template = I.MWUI.templates.textHeader, props = { text = 'Handy Stylish Quick Access Wheels' } },
                    gap(),
                    paragraph(string.format('Hold %s for the spell wheel, %s for the weapon wheel. Point the arrow '
                        .. 'with the mouse and let go to equip what it points at.', magic, weapon)),
                    gap(),
                    paragraph(string.format('To add your current spell or weapon to its wheel, press %s while '
                        .. 'holding %s or %s. Do it again to take it off.', menu, magic, weapon)),
                    gap(),
                    paragraph('On the wheel, hold the right mouse button and steer to move the pointed slot; '
                        .. 'double right click removes it.'),
                    gap(),
                    {
                        template = I.MWUI.templates.boxTransparent,
                        events = { mouseClick = async:callback(closeTutorial) },
                        content = ui.content {
                            padded({ template = I.MWUI.templates.textHeader, props = { text = core.getGMST('sOK') } }, 4),
                        },
                    },
                },
            }, 12),
        },
    }
end

-- The wheel ----------------------------------------------------------------------

local function focusDepth()
    local distance = 0
    if camera.getMode() ~= camera.MODE.FirstPerson then distance = camera.getThirdPersonDistance() end
    return distance + lookSettings:get('DofFocus') * GU_PER_METRE
end

-- `armed`: whether letting go equips the pointed slot. Not right after a Quick Menu combo (the slot
-- just added is the one already equipped, so a quick combo shouldn't also ready it), until the arrow moves
-- on to another slot.
local function openWheel(kindName, armed)
    wheel = {
        kind = kindName,
        armed = armed,
        opened = core.getRealTime(),
        stick = v2(0, 0),
        alpha = 0,
        sensitivity = settings:get('MouseSensitivity'),
        sounds = settings:get('Sounds'),
        posePending = true,
        tutorialDue = settings:get('TutorialAlways') or not tutorialSeen,
    }
    if kindName == 'spell' and handSettings:get('FingertipMagic') then
        wheel.fingertipBones = fingertipBones()
    end
    if kindName == 'weapon' and handSettings:get('WeaponPreview') then
        local right = Actor.getEquipment(self, SLOT.CarriedRight)
        local left = Actor.getEquipment(self, SLOT.CarriedLeft)
        wheel.original = {
            right = right and right.recordId,
            left = left and left.recordId,
            stance = Actor.getStance(self),
        }
    end
    local dynamicCamera = I.DynamicCamera
    if lookSettings:get('Dof') and dynamicCamera and dynamicCamera.shaders then
        wheel.dof = dynamicCamera.shaders.hexDoFProgrammable
        wheel.dofDepth = focusDepth()
        wheel.dofAperture = lookSettings:get('DofAperture')
    end
    if dynamicCamera and dynamicCamera.setLookSpeedMult then
        dynamicCamera.setLookSpeedMult(LOOK_SCALE, MOD_ID)
        wheel.dynamicCamera = dynamicCamera
    end
    local timeScale = settings:get('TimeScale')
    if timeScale < 1 then
        core.sendGlobalEvent('QuickAccessWheel_TimeScale', { scale = timeScale })
        wheel.slowedTime = timeScale
    end
    removeMissing(kindName)
    refreshSlots(currentEntry(kindName))
    render()
end

local function closeWheel(commit)
    local closing = wheel
    wheel = nil
    closing.element:destroy()
    if closing.slowedTime then core.sendGlobalEvent('QuickAccessWheel_TimeScale', {}) end
    if closing.dynamicCamera then closing.dynamicCamera.setLookSpeedMult(nil, MOD_ID) end
    -- The depth of field is simply left alone now: Dynamic Camera eases it back out.
    if closing.pose then animation.cancel(self, closing.pose) end
    clearFingertips(closing)
    if closing.boostUntil then setEquipSpeed(1) end
    if commit and closing.armed and closing.selected then
        local slot = closing.slots[closing.selected]
        useSlot(closing.kind, slot)
        -- Chosen after its preview: now it gets the equip sounds the preview kept quiet.
        local preview = closing.preview
        if preview and preview.entry == slot.entry then
            -- Its sounds yet to come play as they come, the ones heard play now.
            stopKeepingQuiet(preview)
            if next(preview.heard) then pendingSounds = { ids = preview.heard, deadline = core.getRealTime() + 1 } end
        end
    elseif closing.loadoutChanged then
        restoreLoadout(closing)
    end
end

local function steer()
    local g = wheel.geo
    local stick = wheel.stick + v2(g.side * input.getMouseMoveX(), -input.getMouseMoveY()) * wheel.sensitivity
    local padX = input.getAxisValue(input.CONTROLLER_AXIS.RightX)
    local padY = input.getAxisValue(input.CONTROLLER_AXIS.RightY)
    if padX * padX + padY * padY > PAD_DEADZONE * PAD_DEADZONE then
        stick = v2(g.side * padX, -padY) * STICK_RADIUS
    end

    local length = stick:length()
    if length > STICK_RADIUS then
        stick = stick * (STICK_RADIUS / length)
        length = STICK_RADIUS
    end
    if length > 0 then
        local angle = math.atan2(stick.y, stick.x)
        if math.abs(util.normalizeAngle(angle - (g.a0 + g.a1) / 2)) > math.pi / 2 then
            -- Pushed back into the corner: let go of the selection, so releasing changes nothing.
            stick = v2(0, 0)
        else
            -- Clamped right away, so pushing past the last slot doesn't build up travel to undo.
            local clamped = clampToSlots(g, #wheel.slots, angle)
            if clamped ~= angle then stick = v2(math.cos(clamped), math.sin(clamped)) * length end
        end
    end
    wheel.stick = stick
end

local function updateWheel()
    if I.UI.getMode() or core.isWorldPaused() then
        closeWheel(false)
        return
    end
    if not input.isActionPressed(KINDS[wheel.kind].action) then
        closeWheel(true)
        return
    end
    if wheel.tutorialDue and core.getRealTime() - wheel.opened >= TUTORIAL_DELAY then
        closeWheel(false)
        showTutorial()
        return
    end

    -- The mouse steers the arrow now, and turns the view only LOOK_SCALE as much. Where Dynamic
    -- Camera drives the camera (first person) it scales the look itself, see openWheel. Elsewhere
    -- the engine turns it: mouse and stick look add to the player's pending rotation, and these
    -- controls hold last frame's, which the engine replaces with whatever a script writes this
    -- frame. (Not the Looking control switch: turning it off snaps the character to face north
    -- for a frame, which swings the first-person rig about.)
    local dynamicCamera = wheel.dynamicCamera
    if not (dynamicCamera and camera.getMode() == camera.MODE.FirstPerson
            and not dynamicCamera.isCameraControlSuspended()) then
        self.controls.yawChange = self.controls.yawChange * LOOK_SCALE
        self.controls.pitchChange = self.controls.pitchChange * LOOK_SCALE
    end

    steer()
    local selected = selectionFromStick()
    -- Right mouse held on a slot: it moves to wherever the arrow points, reordering the wheel.
    local drag = wheel.drag
    if drag and not indexOf(favourites[wheel.kind], drag.entry) then
        -- Taken off the wheel meanwhile (Quick Menu combo).
        drag, wheel.drag = nil, nil
    end
    if drag and selected and wheel.slots[selected].entry ~= drag.entry then
        local list = favourites[wheel.kind]
        local from = indexOf(list, drag.entry)
        table.insert(list, selected, table.remove(list, from))
        table.insert(wheel.slots, selected, table.remove(wheel.slots, from))
        drag.moved = true
        wheel.dirty = true
    end
    if selected ~= wheel.selected then
        wheel.selected = selected
        wheel.dirty = true
        if selected and not drag then wheel.armed = true end
        if selected and wheel.sounds then ambient.playSound('Menu Click', { scale = false }) end
    end
    if selected then
        local frame = arrowFrame(wheel.geo, stickAngle())
        if frame ~= wheel.frame then
            wheel.frame = frame
            wheel.dirty = true
        end
    end

    local now = core.getRealTime()
    if wheel.selected ~= wheel.hovered then
        wheel.hovered = wheel.selected
        wheel.hoverSince = now
        if wheel.fingertipBones then updateFingertips() end
    end

    -- Started once the slow-down is in, so that all of its blend runs slowed (see its .yaml).
    if wheel.posePending
        and (not wheel.slowedTime or math.abs(core.getSimulationTimeScale() - wheel.slowedTime) < 1e-3) then
        startPose()
    elseif wheel.posing then
        updatePose()
    end

    local slot = wheel.selected and wheel.slots[wheel.selected]
    if wheel.original and wheel.armed and slot and slot.available and wheel.previewed ~= slot.entry
        and now - wheel.hoverSince >= PREVIEW_DELAY then
        wheel.previewed = slot.entry
        previewWeapon(slot)
    end
    if wheel.boostUntil then
        if now > wheel.boostUntil then
            setEquipSpeed(1)
            wheel.boostUntil = nil
        else
            setEquipSpeed(1 / math.max(core.getSimulationTimeScale(), 0.01))
        end
    end

    local elapsed = now - wheel.opened
    if wheel.alpha < 1 then
        wheel.alpha = math.min(1, elapsed / FADE_TIME)
        wheel.dirty = true
    end
    if wheel.dirty then
        wheel.dirty = false
        render()
    end

    -- Written every frame after Dynamic Camera's own update, which eases the aperture toward its
    -- target lock (or toward 0) on each frame.
    if wheel.dof then
        wheel.dof.u.uDepth = wheel.dofDepth
        wheel.dof.u.uAperture = wheel.dofAperture * math.min(1, elapsed / DOF_FADE_TIME)
    end
end

-- Input ----------------------------------------------------------------------------

local function wheelAllowed(kind)
    return not core.isWorldPaused()
        and I.UI.getMode() == nil
        and Player.getControlSwitch(self, SWITCH.Controls)
        and Player.getControlSwitch(self, kind.switch)
        and Player.isCharGenFinished(self)
        and not Player.isWerewolf(self)
end

local function toggleCurrent(kindName)
    local kind = KINDS[kindName]
    local list = favourites[kindName]
    local entry = currentEntry(kindName)
    if not entry then
        ui.showMessage(kind.nothingCurrent)
        return
    end
    local index = indexOf(list, entry)
    if index then
        table.remove(list, index)
        if wheel then refreshSlots(nil) end
    elseif #list >= MAX_SLOTS then
        ui.showMessage(string.format('The %s wheel is full (%d slots)', kind.noun, MAX_SLOTS))
    else
        list[#list + 1] = entry
        if wheel then refreshSlots(entry) end
    end
end

local function onTogglePressed(kindName)
    local kind = KINDS[kindName]
    local before, after = lastStance, Actor.getStance(self)
    if press or wheel then
        -- Busy with the other key: this one does nothing meanwhile.
        if before ~= after then Actor.setStance(self, before) end
        return
    end
    -- QuickLoot takes R and F for itself while it shows a container, but it also turns the Magic
    -- and Fighting switches off, so wheelAllowed already says no then.
    if not wheelAllowed(kind) then return end
    -- The builtin toggle may also have done nothing (an animation that can't be interrupted,
    -- nothing to cast); a tap then does nothing either, but holding still opens the wheel.
    if before ~= after then Actor.setStance(self, before) end
    press = {
        kind = kindName,
        start = core.getRealTime(),
        holdDelay = settings:get('HoldDelay'),
        tapStance = before ~= after and after or nil,
    }
    if menuPress then
        -- Quick Menu first, then this key: the same combo the other way round.
        menuPress.combo = true
        press.combo = true
        toggleCurrent(kindName)
    end
end

local function updatePress()
    if I.UI.getMode() then
        press = nil
        return
    end
    if not input.isActionPressed(KINDS[press.kind].action) then
        -- A tap: what the builtin toggle wanted, at release. Not after a Quick Menu combo though.
        if press.tapStance and not press.combo then Actor.setStance(self, press.tapStance) end
        press = nil
    elseif core.getRealTime() - press.start >= press.holdDelay then
        local kindName, combo = press.kind, press.combo
        press = nil
        openWheel(kindName, not combo)
    end
end

local function learnKey(actionName, code)
    local name = input.getKeyName(code)
    if name ~= '' and name ~= keyNames:get(actionName) then keyNames:set(actionName, name) end
end

local function noteAction(actionName)
    if lastKey and frame - lastKey.frame <= 1 then
        learnKey(actionName, lastKey.code)
        lastKey = nil
    else
        pendingKeyAction = { name = actionName, frame = frame }
    end
end

local function onQuickKeysMenu()
    -- If the builtin controls have just opened the quick keys menu for this press, it only opens at
    -- the end of the frame, so closing it now means it never shows. When it was open already, this
    -- press closed it and is left alone.
    local opened = I.UI.getMode() == I.UI.MODE.QuickKeysMenu
    if opened then I.UI.removeMode(I.UI.MODE.QuickKeysMenu) end
    local kindName = (press and press.kind) or (wheel and wheel.kind)
    if kindName then
        if press then press.combo = true end
        if wheel then wheel.armed = false end
        toggleCurrent(kindName)
    elseif opened then
        -- Opened at release instead, unless R or F comes in while it is held.
        menuPress = { combo = false }
    end
end

local function updateMenuPress()
    if input.isActionPressed(input.ACTION.QuickKeysMenu) then return end
    local combo = menuPress.combo
    menuPress = nil
    if not combo and I.UI.getMode() == nil then I.UI.addMode(I.UI.MODE.QuickKeysMenu) end
end

local function onKeyPress(key)
    if pendingKeyAction and frame - pendingKeyAction.frame <= 1 then
        learnKey(pendingKeyAction.name, key.code)
        pendingKeyAction = nil
    else
        lastKey = { code = key.code, frame = frame }
    end
end

local function onInputAction(action)
    local kindName = KIND_BY_ACTION[action]
    if kindName then
        noteAction(KINDS[kindName].actionName)
        onTogglePressed(kindName)
    elseif action == input.ACTION.QuickKeysMenu then
        noteAction('QuickKeysMenu')
        onQuickKeysMenu()
    end
end

-- Right mouse on a slot: held and steered, the slot travels with the arrow (see updateWheel); a
-- double click that leaves it in place removes it. Either way letting go of the wheel's key
-- afterwards doesn't equip, until the arrow moves on to another slot.
local function onMouseButtonPress(button)
    if not (wheel and button == 3 and wheel.selected) then return end
    wheel.drag = { entry = wheel.slots[wheel.selected].entry, start = core.getRealTime(), moved = false }
    wheel.armed = false
end

local function onMouseButtonRelease(button)
    if not (wheel and button == 3 and wheel.drag) then return end
    local drag = wheel.drag
    wheel.drag = nil
    local list = favourites[wheel.kind]
    local index = indexOf(list, drag.entry)
    local now = core.getRealTime()
    if drag.moved or not index or now - drag.start > CLICK_TIME then return end
    local last = wheel.lastClick
    if not (last and last.entry == drag.entry and now - last.time <= DOUBLE_CLICK_TIME) then
        wheel.lastClick = { entry = drag.entry, time = now }
        return
    end
    wheel.lastClick = nil
    table.remove(list, index)
    -- The arrow lets go too, so a second click doesn't take out the neighbour.
    pointStickAt(nil)
    refreshSlots(nil)
end

-- Runs after every input handler of the frame, so the stance read here is the one the next press
-- started from.
local function onFrame()
    if press then updatePress() end
    if wheel then updateWheel() end
    if pendingStance then updatePendingStance() end
    -- Closed some other way (Escape) counts as seen too.
    if tutorial and I.UI.getMode() ~= I.UI.MODE.Interface then closeTutorial() end
    if #quietWindows > 0 then updateQuiet(core.getRealTime()) end
    -- Sounds are slowed with the game, so a chosen preview's wait for full speed.
    if pendingSounds and (math.abs(core.getSimulationTimeScale() - 1) < 1e-3 or core.getRealTime() > pendingSounds.deadline) then
        for id in pairs(pendingSounds.ids) do core.sound.playSound3d(id, self) end
        pendingSounds = nil
    end
    if menuPress then updateMenuPress() end
    frame = frame + 1
    lastStance = Actor.getStance(self)
end

local function onSave()
    return { version = 1, favourites = favourites, tutorialSeen = tutorialSeen }
end

local function onLoad(data)
    if not data then return end
    tutorialSeen = data.tutorialSeen or false
    if not data.favourites then return end
    favourites = {
        spell = data.favourites.spell or {},
        weapon = data.favourites.weapon or {},
    }
end

return {
    engineHandlers = {
        onInputAction = onInputAction,
        onKeyPress = onKeyPress,
        onMouseButtonPress = onMouseButtonPress,
        onMouseButtonRelease = onMouseButtonRelease,
        onFrame = onFrame,
        onSave = onSave,
        onLoad = onLoad,
    },
}
