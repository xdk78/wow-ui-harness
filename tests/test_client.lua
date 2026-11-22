-- Client behaviour the mock reproduces: size and visibility scripts, script hooks, input driving, menus, items,
-- timers.
local T = ...

T.case("OnSizeChanged fires when SetSize really changes the size, with hooks, not re-entered", function()
	T.fresh()
	local f = CreateFrame("Frame", nil, UIParent)
	local calls = {}
	f:SetScript("OnSizeChanged", function(self, w, h)
		calls[#calls + 1] = w .. "x" .. h
		self:SetWidth(w) -- same size: nothing
		self:SetHeight(h + 1) -- from its own handler: not re-entered
	end)
	local hooked = 0
	f:HookScript("OnSizeChanged", function()
		hooked = hooked + 1
	end)
	f:SetSize(10, 20)
	T.eq(table.concat(calls, ","), "10x20")
	T.eq(hooked, 1, "the hook ran after the handler")
	T.eq(f:GetHeight(), 21, "the handler's own change stays")
	f:SetSize(10, 21)
	T.eq(#calls, 1, "the same size again: no call")
	f:SetWidth(30)
	T.eq(calls[2], "30x21", "SetWidth")
end)

T.case("OnSizeChanged with layout: the resolved size; SettleSizes does not repeat it", function()
	local mock = T.fresh({})
	local Layout = require("wowui.layout")
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetPoint("TOPLEFT")
	local n, last = 0, nil
	f:SetScript("OnSizeChanged", function(_, w, h)
		n, last = n + 1, w .. "x" .. h
	end)
	f:SetSize(100, 50)
	T.eq(n, 1)
	T.eq(last, "100x50")
	T.eq(Layout.SettleSizes(mock), 0, "already told")
	-- Two-sided anchors fix the width: SetWidth changes nothing that shows.
	f:SetPoint("TOPRIGHT", UIParent, "TOP", 0, 0)
	T.eq(Layout.SettleSizes(mock), 1, "the anchors changed the width")
	T.eq(last, "960x50")
	f:SetWidth(5)
	T.eq(n, 2, "a width the anchors override: no call")
end)

T.case("OnShow / OnHide follow visibility: descendants, parent first, no repeats", function()
	T.fresh()
	local log = {}
	local function track(f, name)
		f:SetScript("OnShow", function()
			log[#log + 1] = "show " .. name
		end)
		f:SetScript("OnHide", function()
			log[#log + 1] = "hide " .. name
		end)
	end
	local parent = CreateFrame("Frame", nil, UIParent)
	local child = CreateFrame("Frame", nil, parent)
	local grandchild = CreateFrame("Frame", nil, child)
	local hiddenChild = CreateFrame("Frame", nil, parent)
	hiddenChild:Hide()
	track(parent, "p")
	track(child, "c")
	track(grandchild, "g")
	track(hiddenChild, "h")
	parent:Show()
	T.eq(#log, 0, "Show on a shown frame does nothing")
	parent:Hide()
	T.eq(table.concat(log, ","), "hide p,hide c,hide g", "shown descendants hide with it, parent first")
	log = {}
	child:Hide()
	T.eq(#log, 0, "already invisible: no OnHide")
	child:Show()
	T.eq(#log, 0, "its parent is hidden: not visible, no OnShow")
	parent:Show()
	T.eq(table.concat(log, ","), "show p,show c,show g")
	log = {}
	local other = CreateFrame("Frame", nil, UIParent)
	other:Hide()
	child:SetParent(other)
	T.eq(table.concat(log, ","), "hide c,hide g", "reparented under a hidden frame")
	log = {}
	child:SetParent(parent)
	T.eq(table.concat(log, ","), "show c,show g")
end)

T.case("scripts: GetScript is the handler; HookScript and SetScript as in the client", function()
	local mock = T.fresh()
	local f = CreateFrame("Frame")
	local order = {}
	local function hook(name)
		return function(_, arg)
			order[#order + 1] = name .. ":" .. tostring(arg)
		end
	end
	local first = hook("first")
	f:HookScript("OnEvent", first)
	T.eq(f:GetScript("OnEvent"), first, "HookScript on an empty script sets the handler")
	f:HookScript("OnEvent", hook("second"))
	f:HookScript("OnEvent", hook("third"))
	T.eq(f:GetScript("OnEvent"), first, "hooks are not the handler")
	f:RegisterEvent("PING")
	mock.FireEvent("PING")
	T.eq(table.concat(order, ","), "first:PING,second:PING,third:PING", "events run the handler, then hooks in order")
	order = {}
	f:SetScript("OnEvent", hook("new"))
	mock.FireScript(f, "OnEvent", "x")
	T.eq(table.concat(order, ","), "new:x", "SetScript dropped the hooks")
	f:SetScript("OnEvent", nil)
	T.eq(f:GetScript("OnEvent"), nil)
end)

T.case("IsTruncated without layout: set width, wrap, MaxLines, height", function()
	T.fresh()
	local fs = UIParent:CreateFontString()
	fs:SetText("abcdefghij") -- 60 units at the mock's 6 a character
	T.eq(fs:IsTruncated(), false, "no width: the text grows")
	fs:SetWidth(30)
	T.eq(fs:IsTruncated(), false, "wraps onto more lines")
	fs:SetMaxLines(2)
	T.eq(fs:IsTruncated(), false, "two lines of 30 hold 60")
	fs:SetMaxLines(1)
	T.eq(fs:IsTruncated(), true, "one line does not")
	fs:SetMaxLines(0)
	fs:SetHeight(14)
	T.eq(fs:IsTruncated(), true, "a height of one line")
	fs:SetHeight(0)
	fs:SetWordWrap(false)
	T.eq(fs:IsTruncated(), true, "no wrapping")
	fs:SetWidth(60)
	T.eq(fs:IsTruncated(), false, "fits")
end)

T.case("IsMouseEnabled reflects EnableMouse", function()
	T.fresh()
	local f = CreateFrame("Frame")
	T.eq(f:IsMouseEnabled(), true, "until set (the mock's default)")
	f:EnableMouse(false)
	T.eq(f:IsMouseEnabled(), false)
	f:EnableMouse(true)
	T.eq(f:IsMouseEnabled(), true)
end)

T.case("input: cursor, keys, buttons; WithInput restores even on error", function()
	local mock = T.fresh()
	mock.SetCursor(120, 340)
	local x, y = GetCursorPosition()
	T.eq(x, 120)
	T.eq(y, 340)
	T.eq(IsShiftKeyDown(), false)
	mock.SetKeyDown("RSHIFT", true)
	T.eq(IsShiftKeyDown(), true)
	T.eq(IsLeftShiftKeyDown(), false)
	T.eq(IsModifierKeyDown(), true)
	T.eq(IsKeyDown("SHIFT"), true, "either side")
	mock.SetKeyDown("RSHIFT", false)
	local inside = mock.WithInput({ cursor = { 5, 6 }, keys = { "CTRL", "ALT" }, buttons = { "RightButton" } }, function()
		return IsControlKeyDown() and IsAltKeyDown() and IsMouseButtonDown("RightButton") and IsMouseButtonDown(2)
			and not IsMouseButtonDown("LeftButton") and IsMouseButtonDown() and (GetCursorPosition()) == 5
	end)
	T.eq(inside, true)
	T.eq(IsControlKeyDown(), false, "restored")
	T.eq((GetCursorPosition()), 120)
	T.ok(not pcall(mock.WithInput, { keys = { "SHIFT" } }, function()
		error("boom")
	end), "the error passes through")
	T.eq(IsShiftKeyDown(), false, "restored after the error")
	mock.shiftDown = true
	T.eq(IsShiftKeyDown(), true, "mock.shiftDown still works")
end)

T.case("Click: mouse down / up, then PreClick, OnClick, PostClick for registered, enabled buttons", function()
	local mock = T.fresh()
	local b = CreateFrame("Button", nil, UIParent)
	local log = {}
	for _, s in ipairs({ "OnMouseDown", "OnMouseUp", "PreClick", "OnClick", "PostClick" }) do
		b:SetScript(s, function(_, button, down)
			log[#log + 1] = s .. "(" .. tostring(button) .. "," .. tostring(down) .. "," .. tostring(IsMouseButtonDown()) .. ")"
		end)
	end
	T.eq(mock.Click(b), true)
	T.eq(table.concat(log, " "), "OnMouseDown(LeftButton,nil,true) OnMouseUp(LeftButton,true,false) "
		.. "PreClick(LeftButton,false,false) OnClick(LeftButton,false,false) PostClick(LeftButton,false,false)")
	log = {}
	T.eq(mock.Click(b, "RightButton"), false, "not registered for right clicks (default LeftButtonUp)")
	T.eq(#log, 2, "the mouse scripts still run")
	b:RegisterForClicks("AnyDown")
	log = {}
	T.eq(mock.Click(b, "RightButton"), true)
	T.eq(log[3], "OnClick(RightButton,true,true)", "on the down stroke")
	b:Disable()
	T.eq(mock.Click(b, "RightButton"), false, "disabled")
	local check = CreateFrame("CheckButton", nil, UIParent)
	local seen
	check:SetScript("OnClick", function(self)
		seen = self:GetChecked()
	end)
	mock.Click(check)
	T.eq(seen, true, "a check button toggles before OnClick")
end)

T.case("Drag: OnMouseDown, OnDragStart after the first move, OnUpdate frames, OnDragStop, OnMouseUp", function()
	local mock = T.fresh()
	local f = CreateFrame("Frame", nil, UIParent)
	local log = {}
	local function rec(name)
		return function(_, a)
			local x, y = GetCursorPosition()
			log[#log + 1] = string.format("%s(%s)@%g,%g", name, tostring(a), x, y)
		end
	end
	for _, s in ipairs({ "OnMouseDown", "OnDragStart", "OnUpdate", "OnDragStop", "OnMouseUp" }) do
		f:SetScript(s, rec(s))
	end
	mock.Drag(f, { from = { 0, 0 }, to = { 20, 10 }, steps = 2, elapsed = 0.5 })
	T.eq(table.concat(log, " "), "OnMouseDown(LeftButton)@0,0 OnUpdate(0.5)@10,5 OnUpdate(0.5)@20,10 OnMouseUp(LeftButton)@20,10",
		"no drag events without RegisterForDrag")
	log = {}
	f:RegisterForDrag("LeftButton")
	mock.Drag(f, { from = { 0, 0 }, to = { 20, 10 }, steps = 2, elapsed = 0.5 })
	T.eq(table.concat(log, " "), "OnMouseDown(LeftButton)@0,0 OnDragStart(LeftButton)@10,5 OnUpdate(0.5)@10,5 "
		.. "OnUpdate(0.5)@20,10 OnDragStop(nil)@20,10 OnMouseUp(LeftButton)@20,10")
	T.eq(IsMouseButtonDown(), false, "released")
	mock.Hover(f)
	T.eq(f:IsMouseOver(), true)
	mock.Leave(f)
	T.eq(f:IsMouseOver(), false)
end)

T.case("errors in handlers and timers leave the mock usable", function()
	local mock = T.fresh()
	local b = CreateFrame("Button", nil, UIParent)
	b:SetScript("OnClick", function()
		error("click failed")
	end)
	T.ok(not pcall(mock.Click, b), "the error reaches the test")
	T.eq(IsMouseButtonDown(), false, "the button was released")
	b:Hide()
	T.eq(mock.Click(b), false, "a hidden button takes no click")
	b:Show()
	b:EnableMouse(false)
	T.eq(mock.Click(b), false, "nor one with the mouse disabled")
	local ran = {}
	C_Timer.After(0.1, function()
		error("timer failed")
	end)
	C_Timer.After(0.2, function()
		ran[#ran + 1] = "later"
	end)
	T.ok(not pcall(mock.Advance, 1))
	mock.Advance(0)
	T.eq(ran[1], "later", "the other due timer still runs")
	local f = CreateFrame("Frame")
	f:SetScript("OnEvent", function()
		return 1, nil, 3
	end)
	f:HookScript("OnEvent", function() end)
	T.eq(select("#", mock.FireScript(f, "OnEvent", "X")), 3, "results with a nil inside survive the hooks")
	-- An OnShow handler that hides a child: the child gets no OnShow.
	local parent = CreateFrame("Frame", nil, UIParent)
	local child = CreateFrame("Frame", nil, parent)
	parent:Hide()
	local childShows = 0
	parent:SetScript("OnShow", function()
		child:Hide()
	end)
	child:SetScript("OnShow", function()
		childShows = childShows + 1
	end)
	parent:Show()
	T.eq(childShows, 0)
	local menu = MenuUtil.CreateContextMenu(nil, function() end)
	menu:CreateButton("Late")
	T.eq(menu:Lines()[1], "button Late", "the root's Create methods on the menu")
end)

T.case("MenuUtil: element descriptions, SetEnabled with a predicate, Pick and responses", function()
	local mock = T.fresh()
	local owner = CreateFrame("Frame", nil, UIParent)
	local picked, size, show = {}, "small", false
	local menu = MenuUtil.CreateContextMenu(owner, function(region, root, extra)
		T.eq(region, owner)
		T.eq(extra, "extra", "extra arguments reach the generator")
		root:CreateTitle("Options")
		root:CreateButton("Rename", function(data, input, m)
			picked[#picked + 1] = data .. ":" .. input.buttonName
			T.eq(m, mock.lastMenu, "the menu")
		end, "plan-1")
		local delete = root:CreateButton("Delete", function()
			picked[#picked + 1] = "deleted"
		end)
		delete:SetEnabled(function(desc)
			T.eq(desc, delete, "the predicate gets the description")
			return false
		end)
		root:QueueDivider()
		root:CreateCheckbox("Show", function()
			return show
		end, function()
			show = not show
		end)
		local sub = root:CreateButton("Size")
		for _, s in ipairs({ "small", "large" }) do
			sub:CreateRadio(s, function(v)
				return size == v
			end, function(v)
				size = v
				return MenuResponse.Close
			end, s)
		end
	end, "extra")
	T.eq(mock.lastMenu, menu)
	T.eq(table.concat(menu:Lines(), "|"), "title Options|button Rename|button Delete (disabled)|divider|checkbox [ ] Show"
		.. "|button Size|  radio [x] small|  radio [ ] large")
	T.eq(menu:Click("Delete"), false, "disabled: the responder does not run")
	T.eq(#picked, 0)
	T.eq(menu:Click("Show"), true)
	T.eq(show, true)
	T.eq(menu:IsOpen(), true, "a checkbox refreshes the menu, it stays open")
	T.eq(menu.refreshes, 1)
	menu:Click("Size", "large")
	T.eq(size, "large")
	T.eq(menu:IsOpen(), true, "Close in a submenu closes the submenu only")
	T.eq(menu:Click("Size"), false, "a submenu root without a responder does nothing")
	menu:Click("Rename")
	T.eq(picked[1], "plan-1:LeftButton")
	T.eq(menu:IsOpen(), false, "a button without a response closes the menu")
	T.ok(not pcall(menu.Click, menu, "Rename"), "a closed menu cannot be clicked")
	T.ok(not pcall(menu.Click, menu, "Nope"), "an unknown element is an error")
	T.eq(menu.items[2].text, "Rename", "the older shape: items with text and fn")
	T.eq(type(menu.items[2].fn), "function")
	local selections = MenuUtil.GetSelections(menu.root)
	T.eq(#selections, 2, "the checkbox and the large radio")
	local quick = MenuUtil.CreateButtonContextMenu(owner, { "A", function() end }, { "B", function() end })
	T.eq(table.concat(quick:Lines(), "|"), "button A|button B")
end)

T.case("GetItemInfoInstant: the client's seven values from test data", function()
	T.fresh()
	local mock = require("wowui.mock")
	mock.items[19019] = { name = "Thunderfury", itemType = "Weapon", itemSubType = "One-Handed Swords",
		itemEquipLoc = "INVTYPE_WEAPON", icon = 135349, classID = 2, subClassID = 7 }
	T.eq(select("#", GetItemInfoInstant(19019)), 7)
	local id, itemType, sub, loc, icon, class, subclass = C_Item.GetItemInfoInstant("|cffff8000|Hitem:19019::::::::|h[x]|h|r")
	T.eq(id, 19019)
	T.eq(itemType .. "/" .. sub .. "/" .. loc .. "/" .. icon .. "/" .. class .. "/" .. subclass,
		"Weapon/One-Handed Swords/INVTYPE_WEAPON/135349/2/7")
	T.eq((GetItemInfoInstant("Thunderfury")), 19019, "by name")
	T.eq((GetItemInfoInstant("item:19019")), 19019)
	T.eq(GetItemInfoInstant(1), nil, "unknown")
	T.eq(C_Item.GetItemNameByID(19019), "Thunderfury")
	T.eq(C_Item.GetItemIconByID(19019), 135349)
end)

T.case("C_Timer and OnUpdate driven by Advance: order, tickers, iterations, frames", function()
	local mock = T.fresh()
	local log = {}
	C_Timer.After(0.3, function()
		log[#log + 1] = "b"
	end)
	C_Timer.After(0.1, function()
		log[#log + 1] = "a"
		C_Timer.After(0, function()
			log[#log + 1] = "next frame"
		end)
	end)
	local ticks = 0
	local ticker = C_Timer.NewTicker(0.1, function(t)
		ticks = ticks + 1
		T.ok(t.Cancel, "the callback gets the ticker")
	end, 3)
	local timer = C_Timer.NewTimer(0.2, function()
		log[#log + 1] = "cancelled"
	end)
	timer:Cancel()
	T.eq(timer:IsCancelled(), true)
	mock.Advance(1)
	T.eq(table.concat(log, ","), "a,b", "earliest first; one frame")
	T.eq(ticks, 1, "a ticker fires at most once a frame")
	mock.Advance(1, 0.1)
	T.eq(log[3], "next frame")
	T.eq(ticks, 3, "three iterations")
	T.eq(ticker:IsCancelled(), true)
	local parent = CreateFrame("Frame", nil, UIParent)
	local child = CreateFrame("Frame", nil, parent)
	local updates = 0
	child:SetScript("OnUpdate", function()
		updates = updates + 1
	end)
	mock.Advance(0.5, 0.25)
	T.eq(updates, 2, "two frames")
	parent:Hide()
	mock.Advance(0.1)
	T.eq(updates, 2, "no OnUpdate for a frame that is not visible")
end)
