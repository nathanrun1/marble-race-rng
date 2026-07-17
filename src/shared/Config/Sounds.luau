--!strict
-- Sound assets + the default UI click + the background-music playlist.

local SWITCH2 = "rbxassetid://138551870543599"

local Sounds = {
	Upgrade = "rbxassetid://106356556379520",
	Collect1 = "rbxassetid://104023881731125",
	Collect2 = "rbxassetid://83285744063515",
	Collect3 = "rbxassetid://100610043368485",
	Jackpot = "rbxassetid://84581872132549",
	Launch = "rbxassetid://87587182495338",
	Combo = "rbxassetid://112485190367588",
	Combo2 = "rbxassetid://123849658867902",
	Bounce = "rbxassetid://107174499116544",
	Hot = "rbxassetid://115023474688736",
	Fire = "rbxassetid://105137237689649",
	Cold = "rbxassetid://116320134099218",
	Prestige = "rbxassetid://84051226507785",
	Music = "rbxassetid://9043887120",
	Confirmation3 = "rbxassetid://87535825628082",
	Confirmation2 = "rbxassetid://124879887650269",
	Confirmation4 = "rbxassetid://80527877392020",
	Toggle2 = "rbxassetid://120678299885068",
	Switch2 = SWITCH2,

	-- The game's default UI click, played by SoundService.PlayClick(): every UIButton
	-- without its own clickSound, plus the hand-wired shop/panel buttons. A full
	-- SoundService.Play spec, so volume/pitch/jitter all tune here globally.
	-- ("" soundId = silent, same placeholder convention as before.)
	DefaultClick = {
		soundId = SWITCH2,
		pitch = 2.2, -- PlaybackSpeed
		volume = 0.125, -- half the SoundService default (0.5)
	},

	BackgroundPlaylist = {
		"rbxassetid://80978440935539", --  De Chill, Mami
		"rbxassetid://1837347090", -- Push me Slow
		"rbxassetid://71174590381361", -- Electronics Heart
		"rbxassetid://102039057339088", -- Zero Gravity
		"rbxassetid://98191313530605", -- Orbital Drift
		"rbxassetid://106258110802472", -- Docking Sequence
		"rbxassetid://71057809016365", -- Re-Entry
		"rbxassetid://135680753939150", -- Digital Detox
		"rbxassetid://121501933641667", -- Flow State
	},
}

table.freeze(Sounds)

return Sounds
