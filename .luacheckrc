-- luacheck configuration (CI runs `luacheck .`). Lua 5.1, like the game.
std = "lua51"
max_line_length = 160
codes = true

exclude_files = {
	"tests/vendor/",
	".venv/",
	"work/",
	"out/",
}

ignore = {
	"212/self", -- unused self in methods
	"212/_.*", -- unused arguments starting with _
	"432/self", -- shadowing self in closures
}

-- The mock defines the client's API as globals on purpose.
files["lua/wowui/mock.lua"] = { allow_defined_top = true, globals = { "_G" } }
files["lua/wowui/"] = { read_globals = { "UIParent", "C_Texture" }, globals = { "_G" } }

-- The in-game library: the client API it reads, and LibStub.
files["lib/"] = {
	read_globals = {
		"_G", "LibStub", "CreateFrame", "UIParent", "C_Timer", "GetTime", "GetLocale", "InCombatLockdown", "Screenshot",
		"GameTooltip", "DEFAULT_CHAT_FRAME", "time", "date",
	},
}

files["tests/"] = {
	globals = { "_G", "LibStub", "Screenshot" },
	read_globals = {
		"arg", "CreateFrame", "UIParent", "C_Timer", "GetFileIDFromPath", "C_Item", "GetItemInfoInstant", "MenuUtil",
		"MenuResponse", "GetCursorPosition", "IsMouseButtonDown", "IsShiftKeyDown", "IsLeftShiftKeyDown",
		"IsControlKeyDown", "IsAltKeyDown", "IsModifierKeyDown", "IsKeyDown",
	},
}
files["examples/"] = { read_globals = { "arg", "CreateFrame", "UIParent" } }
