-- Global half of the Quick Access Wheel: only global scripts can change the time scale.

local world = require('openmw.world')

-- The time scale the open wheel asked for, nil while no wheel is open.
local heldScale = nil

local function onTimeScale(data)
    if data.scale then
        heldScale = data.scale
        world.setSimulationTimeScale(heldScale)
    elseif heldScale then
        heldScale = nil
        world.setSimulationTimeScale(1)
    end
end

local function onUpdate()
    -- Another mod's slow motion (Combat Juice's on a kill) may set the time scale while the wheel
    -- is open. The wheel's holds until it closes.
    if heldScale and math.abs(world.getSimulationTimeScale() - heldScale) > 1e-3 then
        world.setSimulationTimeScale(heldScale)
    end
end

return {
    engineHandlers = { onUpdate = onUpdate },
    eventHandlers = { QuickAccessWheel_TimeScale = onTimeScale },
}
