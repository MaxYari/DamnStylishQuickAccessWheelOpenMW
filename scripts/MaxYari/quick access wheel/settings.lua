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

I.Settings.registerPage {
    key = 'QuickAccessWheelPage',
    l10n = 'QuickAccessWheel',
    name = 'Quick Access Wheel',
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
        number('MouseSensitivity', 'Mouse Sensitivity', 1, 0.1, 5),
        checkbox('Sounds', 'Click On Pointing At A Slot', true),
        checkbox('TutorialAlways', 'Show The Tutorial Every Time', false,
            "For trying it out: the tutorial shows instead of the wheel every time. Otherwise it shows " ..
            "only the first time."),
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
