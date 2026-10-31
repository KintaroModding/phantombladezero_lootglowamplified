-- Settings of Loot Glow Amplified. Change a value and save the file: the mod reads it again every 5 seconds, so the
-- change shows in the game without a restart. A file it cannot read (for example while it is saved) keeps the last
-- settings. A setting that this file does not have keeps its default, so an older copy of the file still works after
-- an update.
return {
    Enable = true,     -- false: the mod puts every glow back as the game has it and does nothing
    Brightness = 2,    -- how bright the beam, the sparkles and the light around the loot are: 1 = as in the game, up to 5
    Size = 2,          -- how big the glow over the loot is: 1 = as in the game, 2 = twice as tall and wide, up to 5
    Chests = true,     -- false: chests keep the game's glow
    Items = true,      -- false: loot piles (also notes, pages and other pickups) keep the game's glow
    LogDetail = false, -- true: ue4ss\UE4SS.log lists every change and a status line (for tests)
}
