--[[
	AuctionatorQuickBuy.lua  (Ascension Quick Buy)

	One-click buyout that replaces the flaky chain-buy "sweep".

	Flow: search an item -> click a price row that holds MULTIPLE stacks at the
	same price -> it expands into a small panel listing those stacks, each with a
	[Buy] button (and Shift+click on the row does the same). One click buys ONE
	auction, read fresh off the LIVE auction list at the instant you click, then
	the list re-queries. Click the row again (or the X) to collapse.

	Why this is robust where the sweep wasn't: Auctionator stores no per-auction
	index, and the client's cached scan goes stale the moment you act on it. So
	instead of an addon loop bidding through a stale list (bidding at ghosts and
	miscounting), every buy is a single hardware-event click that re-reads the
	live list and bids exactly one match. If a stack was sniped a second earlier,
	that one click just finds no match and the list refreshes -- no cascade, no
	phantom "bought all".

	Isolated on purpose: this file never touches the legacy chain-buy code.
]]

-- Zirco's utils (zc) -- coin formatting (priceToString), string compare -- live
-- on the addon's PRIVATE table, not a global, so grab them the way the other
-- files do. Without this, QB_Price fell back to the raw copper number.
local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc;

local ATR_QUICKBUY_VER = "v16 quick-buy-panel";   -- bump every build so we can confirm it loaded
local NUM_QB_ROWS = 12;                 -- visible rows in the expand panel
local gQB_Frame, gQB_Rows;
local gQB_Group;                        -- { itemName=, stackSize=, buyout= } or nil

-- Ascension completes ONE buyout per server round-trip. gQB_Pending throttles the
-- Buy button: after a buy we wait for the "You won an auction..." confirmation (or
-- an error, or a timeout) before allowing the next, so mashing the button can't
-- fire bids at auctions that are still mid-purchase.
local gQB_Pending = false;
local gQB_PendingAt = 0;
local gQB_Loading = false;              -- a "load next page" query is in flight; block Buy until it lands
local gQB_LoadingAt = 0;
local QB_PENDING_TIMEOUT = 3.0;         -- seconds; fallback if no confirm/error/page arrives
local QB_WON_PREFIX = ((ERR_AUCTION_WON_S or "You won an auction for %s"):gsub ("%%s.*$", "")):gsub ("%s+$", "");
local function QB_Now () return (GetTime and GetTime ()) or 0; end

-- Self-contained debug (so this file drops onto any Auctionator, incl. stock).
-- Off by default; toggle with /qbdebug.
local gQB_Debug = false;
local function QB_Dbg (msg)
	if (gQB_Debug and DEFAULT_CHAT_FRAME) then
		DEFAULT_CHAT_FRAME:AddMessage ("|cff88aaffQuickBuy|r "..tostring (msg));
	end
end
SLASH_QUICKBUYDEBUG1 = "/qbdebug";
SlashCmdList["QUICKBUYDEBUG"] = function ()
	gQB_Debug = not gQB_Debug;
	if (DEFAULT_CHAT_FRAME) then
		DEFAULT_CHAT_FRAME:AddMessage ("|cff88aaffQuickBuy debug|r "..(gQB_Debug and "ON" or "OFF"));
	end
end

local function QB_Same (a, b)
	if (zc and zc.StringSame) then return zc.StringSame (a, b); end
	return a == b;
end

local function QB_Price (c)
	if (zc and zc.priceToString) then return zc.priceToString (c); end
	return tostring (c);
end

-----------------------------------------------------------------------------
-- Live-list helpers
-----------------------------------------------------------------------------

-- How many auctions on the current query list still match this group.
local function Atr_QuickBuy_CountLive (itemName, stackSize, buyout)
	local n = GetNumAuctionItems ("list") or 0;
	local c = 0;
	for i = 1, n do
		local name, _, count, _, _, _, _, _, bp = GetAuctionItemInfo ("list", i);
		if (name and bp and bp == buyout and count == stackSize and QB_Same (name, itemName)) then
			c = c + 1;
		end
	end
	return c;
end

-- Buy exactly ONE auction from this group, read fresh off the LIVE list.
-- MUST be called from a hardware event (a click) -- PlaceAuctionBid is protected.
-- Returns true if a bid was placed. Global so the offline harness can drive it.
function Atr_QuickBuy_BuyOne (itemName, stackSize, buyout)
	if (not itemName or not buyout or buyout <= 0) then
		return false;
	end
	local n = GetNumAuctionItems ("list") or 0;
	for i = 1, n do
		local name, _, count, _, _, _, _, _, bp = GetAuctionItemInfo ("list", i);
		if (name and bp and bp == buyout and count == stackSize and QB_Same (name, itemName)) then
			QB_Dbg ("QuickBuy: buyout idx "..i.." for "..bp);
			PlaceAuctionBid ("list", i, bp);   -- bid == buyout => instant buyout, no confirm popup
			return true;
		end
	end
	QB_Dbg ("QuickBuy: no live match (stale/sniped) for "..tostring (itemName).." x"..tostring (stackSize));
	return false;
end

-----------------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------------

-- Load the clicked group's AH page into the live "list" so we can read real
-- auction indices for it (Auctionator's condensed scan doesn't keep them, and
-- "list" otherwise holds whatever page the last scan happened to end on).
local function Atr_QuickBuy_Requery ()
	local g = gQB_Group;
	if (g and g.itemName and CanSendAuctionQuery and CanSendAuctionQuery ()) then
		QueryAuctionItems (g.itemName, "", "", nil, 0, 0, g.page or 0, nil, nil);
	end
end

local function Atr_QuickBuy_DoBuy ()
	local g = gQB_Group;
	if (not g) then return; end
	-- one buyout per round-trip: ignore spam clicks until the last buy confirms
	if (gQB_Pending and (QB_Now () - gQB_PendingAt) < QB_PENDING_TIMEOUT) then
		QB_Dbg ("QuickBuy: waiting for last buy to confirm - click ignored");
		return;
	end
	-- a "load next page" query is in flight: ignore clicks so mashing Buy can't
	-- skip past pages (or disturb the panel) before the page actually lands
	if (gQB_Loading and (QB_Now () - gQB_LoadingAt) < QB_PENDING_TIMEOUT) then
		QB_Dbg ("QuickBuy: loading next page - click ignored");
		return;
	end
	gQB_Pending = false;
	gQB_Loading = false;
	if (Atr_QuickBuy_BuyOne (g.itemName, g.stackSize, g.buyout)) then
		gQB_Pending = true;                      -- wait for "You won..." before the next buy
		gQB_PendingAt = QB_Now ();
		Atr_QuickBuy_Refresh ();                 -- shows "buying..."; bought++ happens on confirm
	elseif (Atr_QuickBuy_CountLive (g.itemName, g.stackSize, g.buyout) == 0 and (g.page or 0) < (g.maxpage or 0)) then
		g.page = (g.page or 0) + 1;              -- this page is used up; pull the group's next page
		gQB_Loading = true;                      -- block Buy until the new page lands
		gQB_LoadingAt = QB_Now ();
		QB_Dbg ("QuickBuy: page exhausted, loading page "..g.page);
		Atr_QuickBuy_Requery ();
		Atr_QuickBuy_Refresh ();                 -- shows "loading more..."
	end
end

function Atr_QuickBuy_Collapse ()
	gQB_Group = nil;
	gQB_Pending = false;
	gQB_Loading = false;
	if (gQB_Frame) then gQB_Frame:Hide (); end
end

local function QB_CreateFrame ()
	if (gQB_Frame) then return; end

	local f = CreateFrame ("Frame", "Atr_QuickBuy_Frame", Atr_Main_Panel or AuctionFrame);
	f:SetWidth (156);
	f:SetHeight (44 + NUM_QB_ROWS * 18);
	local anchorTo = AuctionFrame or AuctionatorScrollFrame;
	if (anchorTo) then
		f:SetPoint ("TOPLEFT", anchorTo, "TOPRIGHT", 6, -80);   -- sit OUTSIDE the AH window, no overlap
	else
		f:SetPoint ("CENTER");
	end
	f:SetClampedToScreen (true);
	f:SetBackdrop ({
		bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	});
	f:SetBackdropColor (0.05, 0.05, 0.06, 1);          -- solid dark, no world showing through
	f:SetBackdropBorderColor (0.7, 0.6, 0.35, 1);
	f:SetFrameStrata ("DIALOG");

	f.title = f:CreateFontString (nil, "OVERLAY", "GameFontNormalSmall");
	f.title:SetPoint ("TOPLEFT", 12, -10);

	f.hint = f:CreateFontString (nil, "OVERLAY", "GameFontDisableSmall");
	f.hint:SetPoint ("TOPLEFT", 12, -24);
	f.hint:SetText ("|cff33ff99Buy|r or Shift+click a row");

	local close = CreateFrame ("Button", nil, f, "UIPanelCloseButton");
	close:SetPoint ("TOPRIGHT", 2, 2);
	close:SetScript ("OnClick", function () Atr_QuickBuy_Collapse (); end);

	gQB_Rows = {};
	for i = 1, NUM_QB_ROWS do
		local r = CreateFrame ("Button", nil, f);
		r:SetWidth (134);
		r:SetHeight (16);
		r:SetPoint ("TOPLEFT", 11, -42 - (i - 1) * 18);
		r:RegisterForClicks ("LeftButtonUp");

		local hl = r:CreateTexture (nil, "HIGHLIGHT");
		hl:SetAllPoints ();
		hl:SetTexture (1, 1, 1, 0.15);

		r.lbl = r:CreateFontString (nil, "OVERLAY", "GameFontHighlightSmall");
		r.lbl:SetPoint ("LEFT", 2, 0);

		r.buy = CreateFrame ("Button", nil, r, "UIPanelButtonTemplate");
		r.buy:SetWidth (42);
		r.buy:SetHeight (16);
		r.buy:SetPoint ("RIGHT", 0, 0);
		r.buy:SetText ("Buy");
		r.buy:SetScript ("OnClick", function () Atr_QuickBuy_DoBuy (); end);

		-- Shift + click anywhere on the row = buy (power-user shortcut)
		r:SetScript ("OnClick", function ()
			if (IsShiftKeyDown ()) then Atr_QuickBuy_DoBuy (); end
		end);

		gQB_Rows[i] = r;
	end

	gQB_Frame = f;
end

function Atr_QuickBuy_Refresh ()
	if (not gQB_Frame or not gQB_Frame:IsShown () or not gQB_Group) then return; end

	local g = gQB_Group;
	-- Render from REMAINING (scan count - bought), so buying #1 shrinks the list
	-- and the top Buy button stays put for chain-clicking. Rows are NOT gated on a
	-- live re-count (that transiently reads 0 during a buyout and would hide the
	-- buttons); each Buy click reads the live list itself and bids one.
	local remaining = (g.count or 1) - (g.bought or 0);
	if (remaining < 0) then remaining = 0; end
	local boughtTxt = (g.bought and g.bought > 0) and ("   |cff20ff20"..g.bought.." bought|r") or "";
	local statusTxt = gQB_Loading and "  |cffffff00loading more...|r"
	               or (gQB_Pending and "  |cffffff00buying...|r") or "";
	gQB_Frame.title:SetText (g.stackSize.."x @ "..QB_Price (g.buyout)..boughtTxt..statusTxt);

	if (remaining == 0) then
		for i = 2, NUM_QB_ROWS do gQB_Rows[i]:Hide (); end
		gQB_Rows[1].lbl:SetText ("|cff808080all bought|r");
		gQB_Rows[1].buy:Hide ();
		gQB_Rows[1]:Show ();
		return;
	end

	local shown = math.min (remaining, NUM_QB_ROWS);
	for i = 1, NUM_QB_ROWS do
		local r = gQB_Rows[i];
		if (i <= shown) then
			local extra = (i == shown and remaining > NUM_QB_ROWS) and ("  |cff808080(+"..(remaining - NUM_QB_ROWS)..")|r") or "";
			r.lbl:SetText ("#"..i.."   "..QB_Price (g.buyout)..extra);
			r.buy:Show ();
			r:Show ();
		else
			r:Hide ();
		end
	end
end

-- Expand the price group at sortedData[dataIndex] of the active scan.
function Atr_QuickBuy_Expand (dataIndex)
	QB_CreateFrame ();

	local pane = Atr_GetCurrentPane and Atr_GetCurrentPane ();
	local scan = pane and pane.activeScan;
	local data = scan and scan.sortedData and scan.sortedData[dataIndex];
	if (not data or data.type ~= "n" or (data.buyoutPrice or 0) == 0 or data.yours) then
		Atr_QuickBuy_Collapse ();
		return;
	end

	gQB_Group = { itemName = scan.itemName, stackSize = data.stackSize, buyout = data.buyoutPrice,
	              page = data.minpage or 0, maxpage = data.maxpage or (data.minpage or 0),
	              count = data.count or 1, bought = 0 };
	gQB_Frame:Show ();
	Atr_QuickBuy_Requery ();     -- load the group's page so each Buy can read live auction indices
	Atr_QuickBuy_Refresh ();     -- render the Buy rows now (from the scan count; always clickable)
end

-----------------------------------------------------------------------------
-- Hook: clicking a multi-stack price row toggles the expand panel
-----------------------------------------------------------------------------

local function Atr_QuickBuy_OnRowClick ()
	-- only react in the price-list "Current" view (not Past/Other)
	if (not (Atr_ShowingCurrentAuctions and Atr_ShowingCurrentAuctions ())) then
		Atr_QuickBuy_Collapse ();
		return;
	end
	local pane = Atr_GetCurrentPane and Atr_GetCurrentPane ();   -- gCurrentPane is file-local; use the global accessor
	local idx  = pane and pane.currIndex;
	local scan = pane and pane.activeScan;
	local data = idx and scan and scan.sortedData and scan.sortedData[idx];

	QB_Dbg ("QuickBuy click: idx="..tostring (idx)
		.." count="..tostring (data and data.count)
		.." buyout="..tostring (data and data.buyoutPrice));

	if (data and data.type == "n" and (data.buyoutPrice or 0) > 0 and not data.yours and (data.count or 0) >= 2) then
		-- re-clicking the same expanded group collapses it
		if (gQB_Group and gQB_Frame and gQB_Frame:IsShown ()
		    and gQB_Group.stackSize == data.stackSize and gQB_Group.buyout == data.buyoutPrice) then
			Atr_QuickBuy_Collapse ();
		else
			Atr_QuickBuy_Expand (idx);
		end
	else
		Atr_QuickBuy_Collapse ();
	end
end

-- Wrap Atr_EntryOnClick (rather than hooksecurefunc) so we can capture whether
-- the click happened in the search-summary item list -- a "drill into an item"
-- click flips the view to current-auctions, and we must NOT treat that as a
-- price-row click. Reassigning the global is safe: XML calls it by name, and the
-- actual buyout happens later on the panel's own button (a fresh hardware event).
if (type (Atr_EntryOnClick) == "function") then
	local orig_Atr_EntryOnClick = Atr_EntryOnClick;
	Atr_EntryOnClick = function (...)
		local wasSummary = Atr_ShowingSearchSummary and Atr_ShowingSearchSummary ();
		orig_Atr_EntryOnClick (...);
		if (not wasSummary) then
			Atr_QuickBuy_OnRowClick ();
		end
	end
end

-- Keep the panel in sync with the live list; close it when the AH closes.
local qbEvt = CreateFrame ("Frame");
qbEvt:RegisterEvent ("AUCTION_ITEM_LIST_UPDATE");
qbEvt:RegisterEvent ("AUCTION_HOUSE_CLOSED");
qbEvt:RegisterEvent ("CHAT_MSG_SYSTEM");      -- "You won an auction for X" = buy confirmed
qbEvt:RegisterEvent ("UI_ERROR_MESSAGE");     -- buy failed (item gone / no money / ...)
qbEvt:SetScript ("OnEvent", function (self, event, arg1)
	if (event == "AUCTION_HOUSE_CLOSED") then
		Atr_QuickBuy_Collapse ();
	elseif (event == "CHAT_MSG_SYSTEM") then
		-- buyout confirmed: count it, drop the throttle, shrink the list by one
		if (gQB_Pending and gQB_Group and type (arg1) == "string"
		    and QB_WON_PREFIX ~= "" and arg1:find (QB_WON_PREFIX, 1, true)
		    and arg1:find (gQB_Group.itemName, 1, true)) then
			gQB_Pending = false;
			gQB_Group.bought = (gQB_Group.bought or 0) + 1;
			if (AuctionatorSubtractFromScan) then    -- same call the built-in chain-buy uses -> updates Auctionator's own list
				pcall (AuctionatorSubtractFromScan, gQB_Group.itemName, gQB_Group.stackSize, gQB_Group.buyout, 1);
			end
			QB_Dbg ("QuickBuy: confirmed");
			Atr_QuickBuy_Refresh ();
		end
	elseif (event == "UI_ERROR_MESSAGE") then
		-- a buy failed: drop the throttle so the next click works (don't count it)
		if (gQB_Pending) then
			gQB_Pending = false;
			local m = tostring (arg1 or "");
			if (DEFAULT_CHAT_FRAME and (m:lower ():find ("not found", 1, true) or m:lower ():find ("no longer", 1, true))) then
				DEFAULT_CHAT_FRAME:AddMessage ("|cff33ff99Auctionator QuickBuy:|r |cffffcc00Auction no longer available|r - it was likely bought by another player. Try another listing, or re-Search to refresh your Auctionator results.");
			end
			QB_Dbg ("QuickBuy: buy failed (\""..m.."\") - ready for next");
			Atr_QuickBuy_Refresh ();
		end
	elseif (event == "AUCTION_ITEM_LIST_UPDATE") then
		gQB_Loading = false;      -- the requeried page has landed
		if (gQB_Group) then Atr_QuickBuy_Refresh (); end
	end
end);
