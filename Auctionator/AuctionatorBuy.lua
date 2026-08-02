
local addonName, addonTable = ...; 
local zc = addonTable.zc;


local ATR_BUY_NULL						= 0;
local ATR_BUY_QUERY_SENT				= 1;
local ATR_BUY_JUST_BOUGHT				= 2;
local ATR_BUY_PROCESSING_QUERY_RESULTS	= 3;
local ATR_BUY_WAITING_FOR_AH_CAN_SEND	= 4;

local Atr_BuyState = ATR_BUY_NULL;
local ATR_BUY_POST_BUY_DELAY			= 1;

-----------------------------------------

local gAtr_Buy_BuyoutPrice;
local gAtr_Buy_ItemName;
local gAtr_Buy_StackSize;
local gAtr_Buy_NumBought;
local gAtr_Buy_NumUserWants;
local gAtr_Buy_MaxCanBuy;
local gAtr_Buy_CurPage;
local gAtr_Buy_Waiting_Start;
local gAtr_Buy_Query;
local gAtr_Buy_Pass;
local gAtr_Buy_Session_NumBought		= 0;
local gAtr_Buy_Session_TotalSpent		= 0;
local gAtr_Buy_PendingBuy				= nil;

-- chain-buy sweep state (added: full auto-sweep by quantity)
local gAtr_Buy_Chain_Auto				= false;	-- a one-click sweep is in progress
local gAtr_Buy_Chain_Remaining			= 0;		-- auctions still wanted across the whole sweep
local ATR_BUY_CHAIN_ALL					= 1e12;		-- sentinel target meaning "buy everything"

-----------------------------------------

local function Atr_Buy_IsChainChecked()

	return (Atr_Buy_Chain_CB and Atr_Buy_Chain_CB:GetChecked());

end

-----------------------------------------

local function Atr_Buy_IsBuyableData(data)

	return (data and data.type == "n" and not data.yours and not data.altname and data.buyoutPrice > 0);

end

-----------------------------------------

local function Atr_Buy_CountAllBuyable()

	local currentPane = Atr_GetCurrentPane();

	if (not currentPane or not currentPane.activeScan) then
		return 0;
	end

	local total = 0;

	for _, data in ipairs (currentPane.activeScan.sortedData) do
		if (Atr_Buy_IsBuyableData(data) and data.count) then
			total = total + data.count;
		end
	end

	return total;

end

-----------------------------------------

local function Atr_Buy_CoinString(val)

	local gold, silver, copper = zc.val2gsc(val);
	local goldIcon		= "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t";
	local silverIcon	= "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t";
	local copperIcon	= "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t";
	local st = "";

	if (gold > 0) then
		st = gold..goldIcon.." "..format("%02i", silver)..silverIcon.." "..format("%02i", copper)..copperIcon;
	elseif (silver > 0) then
		st = silver..silverIcon.." "..format("%02i", copper)..copperIcon;
	else
		st = copper..copperIcon;
	end

	return st;

end

-----------------------------------------

local function Atr_Buy_UpdateSessionText()

	if (not Atr_Buy_Session_Text) then
		return;
	end

	if (gAtr_Buy_Session_NumBought > 0) then
		Atr_Buy_Session_Text:SetText ("Bought x"..gAtr_Buy_Session_NumBought.." for "..Atr_Buy_CoinString(gAtr_Buy_Session_TotalSpent));
	else
		Atr_Buy_Session_Text:SetText ("");
	end

end

-----------------------------------------

local function Atr_Buy_AddBackToScan(itemName, stackSize, buyoutPrice, howMany)

	if (howMany == nil) then
		howMany = 1;
	end

	local scan = Atr_FindScan (itemName);

	scan:AddScanItem (itemName, stackSize, buyoutPrice, nil, howMany);
	scan:CondenseAndSort ();

	local currentPane = Atr_GetCurrentPane();
	if (currentPane) then
		currentPane.UINeedsUpdate = true;
	end

end

-----------------------------------------

local function Atr_Buy_ClearPendingBuy()

	gAtr_Buy_PendingBuy = nil;

end

-----------------------------------------

local function Atr_Buy_TrackPendingBuy(numAuctions)

	gAtr_Buy_PendingBuy = {
		itemName	= gAtr_Buy_ItemName;
		stackSize	= gAtr_Buy_StackSize;
		buyoutPrice	= gAtr_Buy_BuyoutPrice;
		numAuctions	= numAuctions;
		itemsPerAuction	= gAtr_Buy_StackSize;
		spentPerAuction	= gAtr_Buy_BuyoutPrice;
		when		= time();
	};

end

-----------------------------------------

function Atr_Buy_OnErrorMessage(msg)

	if (not gAtr_Buy_PendingBuy or not msg) then
		return false;
	end

	local msgLC = string.lower(msg);

	if (time() - gAtr_Buy_PendingBuy.when > 5) then
		Atr_Buy_ClearPendingBuy();
		return false;
	end

	if (not (string.find(msgLC, "item was not found", 1, true) or string.find(msgLC, "item not found", 1, true))) then
		return false;
	end

	gAtr_Buy_Session_NumBought = math.max(0, gAtr_Buy_Session_NumBought - gAtr_Buy_PendingBuy.itemsPerAuction);
	gAtr_Buy_Session_TotalSpent = math.max(0, gAtr_Buy_Session_TotalSpent - gAtr_Buy_PendingBuy.spentPerAuction);
	gAtr_Buy_NumBought = math.max(0, gAtr_Buy_NumBought - 1);
	gAtr_Buy_PendingBuy.numAuctions = gAtr_Buy_PendingBuy.numAuctions - 1;

	Atr_Buy_AddBackToScan(gAtr_Buy_PendingBuy.itemName, gAtr_Buy_PendingBuy.stackSize, gAtr_Buy_PendingBuy.buyoutPrice, 1);
	Atr_Buy_UpdateSessionText();

	if (gAtr_Buy_PendingBuy.numAuctions <= 0) then
		Atr_Buy_ClearPendingBuy();
	end

	return true;

end

-----------------------------------------

local function Atr_Buy_ResetSession()

	gAtr_Buy_Session_NumBought = 0;
	gAtr_Buy_Session_TotalSpent = 0;
	gAtr_Buy_Chain_Auto = false;
	gAtr_Buy_Chain_Remaining = 0;
	Atr_Buy_ClearPendingBuy();
	Atr_Buy_UpdateSessionText();

end

-----------------------------------------

local function Atr_Buy_ShowLoadingState()

	Atr_Buy_Confirm_OKBut:SetText (ZT("Buy"))
	Atr_Buy_Confirm_OKBut:Disable();
	Atr_Buy_UpdateSessionText();

	if (Atr_Buy_IsChainChecked()) then
		Atr_Buy_Continue_Text:SetText ("Refreshing auctions...");
		Atr_Buy_Part1:Hide();
		Atr_Buy_Part2:Show();
	end

end

-----------------------------------------

local function Atr_Buy_ShowCurrentSelection()

	local currentPane = Atr_GetCurrentPane();
	local scan = currentPane.activeScan;
	local data = scan.sortedData[currentPane.currIndex];

	gAtr_Buy_Query			= Atr_NewQuery();
	gAtr_Buy_NumUserWants	= -1;
	gAtr_Buy_NumBought		= 0;
	
	gAtr_Buy_BuyoutPrice	= data.buyoutPrice;
	gAtr_Buy_ItemName		= scan.itemName;
	gAtr_Buy_StackSize		= data.stackSize;
	gAtr_Buy_MaxCanBuy		= data.count;
	gAtr_Buy_Pass			= 1;		-- - first pass
	
	Atr_Buy_Confirm_ItemName:SetText (gAtr_Buy_ItemName.." x"..gAtr_Buy_StackSize);

	if (Atr_Buy_IsChainChecked()) then
		-- sweep mode: "max" is everything buyable for this item, and a blank box means "all"
		Atr_Buy_Confirm_Max_Text:SetText (ZT("max")..": "..Atr_Buy_CountAllBuyable());
		if (not gAtr_Buy_Chain_Auto) then
			Atr_Buy_Confirm_Numstacks:SetText ("");		-- blank = buy all (or type a limit)
		end
	else
		Atr_Buy_Confirm_Numstacks:SetNumber (1);
		Atr_Buy_Confirm_Max_Text:SetText (ZT("max")..": "..gAtr_Buy_MaxCanBuy);
	end

	Atr_Buy_UpdateSessionText();
	
	Atr_Buy_Part1:Show();
	Atr_Buy_Part2:Hide();
	
	Atr_Buy_Confirm_OKBut:SetText (ZT("Buy"))
	Atr_Buy_Confirm_OKBut:Disable();
	Atr_Buy_Confirm_Frame:Show();

	Atr_HighlightEntry(currentPane.currIndex);

	if (scan.searchWasExact and data.minpage ~= nil) then
		Atr_Buy_QueueQuery(data.minpage);
	else
		Atr_Buy_QueueQuery(0);
	end

end

-----------------------------------------

function Atr_Buy_ChainAdvance()

	if (not Atr_Buy_IsChainChecked()) then
		return false;
	end

	local currentPane = Atr_GetCurrentPane();
	local scan = currentPane.activeScan;
	local startIndex = currentPane.currIndex or 0;
	local x;

	for x = startIndex, #scan.sortedData do
		local data = scan.sortedData[x];

		if (Atr_Buy_IsBuyableData(data) and (data.stackSize ~= gAtr_Buy_StackSize or data.buyoutPrice ~= gAtr_Buy_BuyoutPrice)) then
			currentPane.currIndex = x;
			Atr_Buy_ShowCurrentSelection();

			-- auto-sweep: buy this next listing without another click, up to what's still wanted
			if (gAtr_Buy_Chain_Auto) then
				gAtr_Buy_NumUserWants = math.min (gAtr_Buy_Chain_Remaining, gAtr_Buy_MaxCanBuy);
			end

			return true;
		end
	end

	return false;

end

-----------------------------------------

function Atr_Buy_ChainContinue()

	if (not Atr_Buy_IsChainChecked()) then
		return false;
	end

	-- auto-sweep: subtract what the finished listing bought, stop when the target is met, else move on
	if (gAtr_Buy_Chain_Auto) then

		if (gAtr_Buy_NumBought and gAtr_Buy_NumBought > 0) then
			gAtr_Buy_Chain_Remaining = gAtr_Buy_Chain_Remaining - gAtr_Buy_NumBought;
		end

		if (gAtr_Buy_Chain_Remaining <= 0) then
			return false;		-- bought everything the user asked for
		end

		return Atr_Buy_ChainAdvance();
	end

	local currentPane = Atr_GetCurrentPane();
	local scan = currentPane.activeScan;
	local data = scan.sortedData[currentPane.currIndex];
	local boughtRequestedQty = (gAtr_Buy_NumUserWants ~= -1 and gAtr_Buy_NumBought > 0 and gAtr_Buy_NumUserWants <= gAtr_Buy_NumBought);

	if (boughtRequestedQty and gAtr_Buy_NumBought < gAtr_Buy_MaxCanBuy and Atr_Buy_IsBuyableData(data) and data.stackSize == gAtr_Buy_StackSize and data.buyoutPrice == gAtr_Buy_BuyoutPrice and data.count > 0) then
		Atr_Buy_ShowCurrentSelection();
		return true;
	end

	return Atr_Buy_ChainAdvance();

end

-----------------------------------------

function Atr_Buy_Debug1 (yellow)

	if (Atr_BuyState == ATR_BUY_NULL)										then asstr = "ATR_BUY_NULL"; end;
	if (Atr_BuyState == ATR_BUY_QUERY_SENT)								then asstr = "ATR_BUY_QUERY_SENT"; end;
	if (Atr_BuyState == ATR_BUY_PROCESSING_QUERY_RESULTS)					then asstr = "ATR_BUY_PROCESSING_QUERY_RESULTS"; end;
	if (Atr_BuyState == ATR_BUY_JUST_BOUGHT)								then asstr = "ATR_BUY_JUST_BOUGHT"; end;
	if (Atr_BuyState == ATR_BUY_WAITING_FOR_AH_CAN_SEND)					then asstr = "ATR_BUY_WAITING_FOR_AH_CAN_SEND"; end;

	if (Atr_BuyState ~= ATR_BUY_NULL) then
		if (yellow) then
			zc.msg (asstr, "curpage: ", gAtr_Buy_CurPage, "   gAtr_Buy_NumBought: ", gAtr_Buy_NumBought);
		else
			zc.msg_pink (asstr, "curpage: ", gAtr_Buy_CurPage, "   gAtr_Buy_NumBought: ", gAtr_Buy_NumBought);
		end
	end
	
end

-----------------------------------------

function Atr_ClearBuyState()

	Atr_BuyState = ATR_BUY_NULL;
	Atr_Buy_ClearPendingBuy();

end

-----------------------------------------

function Atr_Buy_Chain_OnToggle ()

	if (not Atr_Buy_Confirm_Numstacks) then
		return;
	end

	-- ticking "Chain buy" clears the amount box so a blank field means "buy all";
	-- un-ticking restores the normal single-selection default of 1
	if (Atr_Buy_IsChainChecked()) then
		Atr_Buy_Confirm_Numstacks:SetText ("");
	else
		Atr_Buy_Confirm_Numstacks:SetNumber (1);
	end

end


-----------------------------------------

function Atr_Buy1_Onclick ()

	if (not Atr_ShowingCurrentAuctions()) then
		return;
	end
	
	Atr_Buy_ResetSession();
	Atr_Buy_ShowCurrentSelection();

end

-----------------------------------------

function Atr_Buy_QueueQuery (page)

	gAtr_Buy_CurPage = page;

--zc.msg_pink ("Queuing query for page ", page);

	Atr_BuyState = ATR_BUY_WAITING_FOR_AH_CAN_SEND;
	gAtr_Buy_Waiting_Start = time();
	
	Atr_Buy_SendQuery();		-- give it a shot
end

-----------------------------------------

function Atr_Buy_SendQuery ()

	if (CanSendAuctionQuery()) then

		Atr_BuyState = ATR_BUY_QUERY_SENT;

		local queryString = zc.UTF8_Truncate (gAtr_Buy_ItemName,63);	-- attempting to reduce number of disconnects

		QueryAuctionItems (queryString, "", "", nil, 0, 0, gAtr_Buy_CurPage, nil, nil);
	end
		
end

-----------------------------------------
local prevBuyState;

-----------------------------------------

function Atr_Buy_Idle ()

	if (gAtr_Buy_PendingBuy and time() - gAtr_Buy_PendingBuy.when > 5) then
		Atr_Buy_ClearPendingBuy();
	end

	if (Atr_BuyState ~= prevBuyState) then
		prevBuyState = Atr_BuyState;
--		Atr_Buy_Debug1 (true);
	end
	
	if (Atr_BuyState == ATR_BUY_WAITING_FOR_AH_CAN_SEND) then
	
--		zc.md ("WAITING_FOR_AH_CAN_SEND: ", time() - gAtr_Buy_Waiting_Start);
		
		if (GetMoney() < gAtr_Buy_BuyoutPrice) then
			Atr_Buy_Cancel (ZT("You do not have enough gold\n\nto make any more purchases."));
		elseif (time() - gAtr_Buy_Waiting_Start > 10) then
			Atr_Buy_Cancel (ZT("Auction House timed out"));
		else	
			Atr_Buy_SendQuery ();
		end
		
	elseif (Atr_BuyState == ATR_BUY_JUST_BOUGHT) then

--		zc.msg_pink ("ATR_BUY_JUST_BOUGHT: ",  time() - gAtr_Buy_Waiting_Start);

		local queueIf = (time() - gAtr_Buy_Waiting_Start > ATR_BUY_POST_BUY_DELAY);		-- wait a few seconds for Auction List to Update after buys
		
		if (queueIf) then
			if (Atr_Buy_IsComplete()) then
				if (not Atr_Buy_ChainContinue()) then
					Atr_Buy_Cancel();
				end
			else
				Atr_Buy_QueueQuery(gAtr_Buy_CurPage);
			end
		end
		
	end

end

-----------------------------------------

function Atr_Buy_OnAuctionUpdate()

--	Atr_Buy_Debug1();

	if (Atr_BuyState == ATR_BUY_QUERY_SENT) then
		Atr_Buy_CheckForMatches ();
	end

	return (Atr_BuyState ~= ATR_BUY_NULL);
end

-----------------------------------------

function Atr_Buy_CheckForMatches ()

	Atr_BuyState = ATR_BUY_PROCESSING_QUERY_RESULTS;
	Atr_Buy_ClearPendingBuy();
	
	if (gAtr_Buy_Query:CheckForDuplicatePage(gAtr_Buy_CurPage)) then
		Atr_Buy_QueueQuery (gAtr_Buy_CurPage);
		return;
	end

	local isLastPage = gAtr_Buy_Query:IsLastPage(gAtr_Buy_CurPage);
	
	local numMatches = Atr_Buy_CountMatches();
	
	if (numMatches > 0) then		-- update the confirmation screen
	
		if (gAtr_Buy_NumUserWants ~= -1) then		
			Atr_Buy_Continue_Text:SetText (string.format (ZT("%d of %d bought so far"), gAtr_Buy_NumBought, gAtr_Buy_NumUserWants));
			Atr_Buy_Part1:Hide();
			Atr_Buy_Part2:Show();
			Atr_Buy_Confirm_OKBut:SetText (ZT("Continue"))
			Atr_Buy_Confirm_OKBut:Disable();
			Atr_Buy_BuyNextMatch();
		else
			Atr_Buy_Confirm_OKBut:Enable();
		end

	else
		Atr_Buy_NextPage_Or_Cancel();
	end

end


-----------------------------------------

function Atr_Buy_BuyMatches ()
	return Atr_Buy_CountMatches (true);
end

-----------------------------------------

function Atr_Buy_BuyNextMatch ()

	if (GetMoney() < gAtr_Buy_BuyoutPrice) then
		Atr_Buy_Cancel (ZT("You do not have enough gold\n\nto make any more purchases."));
		return;
	end

	local _, numJustBought = Atr_Buy_BuyMatches ();

	if (numJustBought > 0) then

--zc.msg (numJustBought, " from page ", gAtr_Buy_CurPage);
	
		Atr_Buy_TrackPendingBuy(numJustBought);
		gAtr_Buy_Session_NumBought = gAtr_Buy_Session_NumBought + (numJustBought * gAtr_Buy_PendingBuy.itemsPerAuction);
		gAtr_Buy_Session_TotalSpent = gAtr_Buy_Session_TotalSpent + (numJustBought * gAtr_Buy_PendingBuy.spentPerAuction);
		AuctionatorSubtractFromScan (gAtr_Buy_ItemName, gAtr_Buy_StackSize, gAtr_Buy_BuyoutPrice, numJustBought);
		Atr_BuyState = ATR_BUY_JUST_BOUGHT;
		gAtr_Buy_Waiting_Start = time();
		Atr_Buy_ShowLoadingState();
	else
		Atr_Buy_NextPage_Or_Cancel();
	end
	
end

-----------------------------------------

function Atr_Buy_CountMatches (andBuy)

	local numMatches		= 0;
	local numBoughtThisPage	= 0;
	local i = 1;

	while (true) do
	
		local name, _, count, _, _, _, _, _, buyoutPrice, _ = GetAuctionItemInfo ("list", i);

		if (name == nil) then
			break;
		end

		if (zc.StringSame (name, gAtr_Buy_ItemName) and buyoutPrice == gAtr_Buy_BuyoutPrice and count == gAtr_Buy_StackSize) then

			numMatches = numMatches + 1;

			if (andBuy and gAtr_Buy_NumUserWants > gAtr_Buy_NumBought) then
				PlaceAuctionBid("list", i, gAtr_Buy_BuyoutPrice);

				numBoughtThisPage  = numBoughtThisPage + 1;
				gAtr_Buy_NumBought = gAtr_Buy_NumBought + 1;

				-- Buy ONE auction per refresh. The server only completes the first buyout
				-- in a batch; firing several PlaceAuctionBid in one frame makes the rest
				-- fail with "item not found". The wait/re-query loop drives the next one.
				break;
			end
		end

		i = i + 1;
	end

	return numMatches, numBoughtThisPage;
end




-----------------------------------------

function Atr_Buy_Confirm_Update ()

	local num = Atr_Buy_Confirm_Numstacks:GetNumber();

	if (num == 1) then
		Atr_Buy_Confirm_Text2:SetText (ZT("stack for"));
	else
		Atr_Buy_Confirm_Text2:SetText (ZT("stacks for"));
	end

	MoneyFrame_Update ("Atr_Buy_Confirm_TotalPrice",  gAtr_Buy_BuyoutPrice * num);

end

-----------------------------------------

function Atr_Buy_NextPage_Or_Cancel ( queueIf )

	if (Atr_Buy_IsComplete()) then

		if (not Atr_Buy_ChainContinue()) then
			Atr_Buy_Cancel();
		end
		
	elseif (queueIf == nil or queueIf == true) then
	
		if (Atr_Buy_IsFirstPassComplete()) then
			gAtr_Buy_Pass = 2;
			Atr_Buy_QueueQuery(0);
		else
			Atr_Buy_QueueQuery(gAtr_Buy_CurPage + 1);
		end
	end
end

-----------------------------------------

function Atr_Buy_IsComplete ()

	if (gAtr_Buy_NumUserWants ~= -1 and gAtr_Buy_NumUserWants <= gAtr_Buy_NumBought) then
		return true;
	end

	if (gAtr_Buy_Query:IsLastPage(gAtr_Buy_CurPage) and gAtr_Buy_Pass == 2) then
		return true;
	end

	return false;

end

-----------------------------------------

function Atr_Buy_IsFirstPassComplete ()

	if (gAtr_Buy_Query:IsLastPage(gAtr_Buy_CurPage) and gAtr_Buy_Pass == 1) then
		return true;
	end

	return false;

end

-----------------------------------------

function Atr_Buy_Confirm_OK ()

	if (gAtr_Buy_NumUserWants == -1) then

		if (Atr_Buy_IsChainChecked()) then

			-- one-click sweep: blank/0 means buy everything; otherwise that many auctions total
			local entered = Atr_Buy_Confirm_Numstacks:GetNumber();

			gAtr_Buy_Chain_Auto			= true;
			gAtr_Buy_Chain_Remaining	= (entered and entered > 0) and entered or ATR_BUY_CHAIN_ALL;
			gAtr_Buy_NumUserWants		= math.min (gAtr_Buy_Chain_Remaining, gAtr_Buy_MaxCanBuy);

		else

			local numToBuy = Atr_Buy_Confirm_Numstacks:GetNumber();

			if (numToBuy > gAtr_Buy_MaxCanBuy) then
				Atr_Error_Text:SetText (string.format (ZT("You can buy at most %d auctions"), gAtr_Buy_MaxCanBuy));
				Atr_Error_Frame:Show ();
				return;
			end

			gAtr_Buy_NumUserWants = numToBuy;
		end
	end

	Atr_Buy_BuyNextMatch();
	
end

-----------------------------------------

function Atr_Buy_Wait_For_Bought_To_Clear ()

	zc.md ("Atr_Buy_Wait_For_Bought_To_Clear: ", time() - gAtr_Buy_Waiting_Start);
	
end

-----------------------------------------

function Atr_Buy_Cancel (msg)

	-- when a one-click sweep ends (target met / out of gold / nothing left), report the tally
	if (gAtr_Buy_Chain_Auto and gAtr_Buy_Session_NumBought > 0) then
		zc.msg ("Auctionator chain buy \150 bought x"..gAtr_Buy_Session_NumBought.." for "..Atr_Buy_CoinString(gAtr_Buy_Session_TotalSpent));
	end

	gAtr_Buy_Chain_Auto = false;
	gAtr_Buy_Chain_Remaining = 0;

	Atr_BuyState = ATR_BUY_NULL;

	Atr_Buy_Confirm_Frame:Hide();

	Atr_Error_Display(msg);
end


