local I = require('openmw.interfaces')

local function number(key, name, default, min, max, description)
    return {
        key = key,
        renderer = 'number',
        default = default,
        argument = { min = min, max = max },
        name = name,
        description = description,
    }
end

local function checkbox(key, name, default, description)
    return { key = key, renderer = 'checkbox', default = default, name = name, description = description }
end

-- The items are the stored values too, shown as they are when there is no translation for them.
local function choice(key, name, default, items, description)
    return {
        key = key,
        renderer = 'select',
        default = default,
        argument = { l10n = 'QuickAccessWheel', items = items },
        name = name,
        description = description,
    }
end

I.Settings.registerPage {
    key = 'QuickAccessWheelPage',
    l10n = 'QuickAccessWheel',
    name = 'Stylish Quick Access Wheels',
    description = "Hold Ready Magic (R by default) for the spell wheel, Ready Weapon (F) for the weapon " ..
        "wheel, point with the mouse and let go to equip. Ready Magic or Ready Weapon together with Quick " ..
        "Menu (F1), in either order, adds the current spell or weapon to that wheel, or removes it if it " ..
        "is already there. Quick Menu alone opens the quick keys menu as you let go of it.",
}

I.Settings.registerGroup {
    key = 'SettingsQuickAccessWheel',
    page = 'QuickAccessWheelPage',
    l10n = 'QuickAccessWheel',
    name = 'Wheel',
    permanentStorage = true,
    settings = {
        number('HoldDelay', 'Hold Time', 0.2, 0.05, 1,
            "Seconds Ready Magic or Ready Weapon must be held before the wheel opens. A shorter press " ..
            "readies or puts away as usual, just at release instead of at press."),
        number('TimeScale', 'Time Scale While Open', 0.1, 0.01, 1, "1 leaves time running at full speed."),
        choice('Navigation', 'Point The Arrow With', 'Mouse', { 'Mouse', 'Movement Controls' },
            "Mouse: the mouse (or a controller's right stick) points the arrow, and the view only turns " ..
            "a little while a wheel is open. Movement Controls: the movement controls point it, and the " ..
            "character stands still while a wheel is open. Only useful as a controller option, for " ..
            "pointing with the left stick: the movement keys point in just eight directions."),
        number('MouseSensitivity', 'Mouse Sensitivity', 1, 0.1, 5),
        checkbox('Sounds', 'Click On Pointing At A Slot', true),
        checkbox('RemoveMissingItems', 'Auto-Remove Items No Longer Carried', true,
            "As a wheel opens, items that are gone from the inventory are taken off it. Otherwise they " ..
            "stay on it, greyed out."),
        checkbox('RemoveMissingSpells', 'Auto-Remove Spells No Longer Known', true,
            "As the spell wheel opens, spells that are gone from the spell list are taken off it. " ..
            "Otherwise they stay on it, greyed out."),
        checkbox('TutorialAlways', 'Show The Tutorial Every Time', false,
            "For trying it out: the tutorial shows every time a wheel has been open for a second. " ..
            "Otherwise it shows only the first time, once per character."),
    },
}

I.Settings.registerGroup {
    key = 'SettingsQuickAccessWheelLook',
    page = 'QuickAccessWheelPage',
    l10n = 'QuickAccessWheel',
    name = 'Look',
    permanentStorage = true,
    settings = {
        number('WheelRadius', 'Wheel Radius', 24, 10, 45,
            "Percent of the screen height. Grows on its own when the slots don't fit."),
        number('CornerOffset', 'Distance From The Corner', 10, 0, 30,
            "Percent of the screen height, from the bottom corner to the wheel's centre."),
        number('SlotSize', 'Slot Size', 42, 30, 96, "In UI pixels. 42 is the vanilla inventory slot."),
        checkbox('Dof', 'Blur The Background', true,
            "Uses Dynamic Camera's depth of field, so it needs Dynamic Camera with its depth of field " ..
            "effects enabled."),
        number('DofFocus', 'Focus Distance', 1, 0, 20, "Metres in front of the character."),
        number('DofAperture', 'Blur Strength', 0.2, 0, 1, "Dynamic Camera's aperture. Its target lock uses 0.2."),
    },
}

I.Settings.registerGroup {
    key = 'SettingsQuickAccessWheelHands',
    page = 'QuickAccessWheelPage',
    l10n = 'QuickAccessWheel',
    name = 'Hands',
    description = "First person: the arm on the wheel's side is raised while it is open.",
    permanentStorage = true,
    settings = {
        checkbox('FingertipMagic', 'Magic On The Fingertips', true,
            "On the spell wheel, the fingertips glow with the magic of the pointed spell."),
        checkbox('WeaponPreview', 'Draw The Pointed Weapon', true,
            "On the weapon wheel, the weapon the arrow rests on is drawn for a look. Letting go " ..
            "with nothing pointed puts back what you had."),
    },
}
