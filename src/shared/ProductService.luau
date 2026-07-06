--!strict
-- Robux developer-product purchases. Shared, like SoundService/BallEffects:
--
--   Server: owns MarketplaceService.ProcessReceipt. Other services register a grant
--           handler per product id (ProductService.RegisterProduct); ProcessReceipt
--           dispatches to it, with cross-session idempotency via a receipt DataStore
--           and a durable save of the grant before the receipt is confirmed.
--   Client: ProductService.Prompt(productId) opens the Roblox purchase dialog, and
--           PromptFinished fires (productId, wasPurchased) when it closes. The UI
--           decides *when* to prompt (e.g. "can't afford this upgrade") — this module
--           only carries out and fulfils the purchase.
--
-- Product ids live in Config.Products (shared) so client and server agree on them.

local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local ProductService = {}

----------------------------------------------------------------------------------
-- Server-only: ProcessReceipt + grant-handler registry
----------------------------------------------------------------------------------
if RunService:IsServer() then
	local Players = game:GetService("Players")
	local SSS = game:GetService("ServerScriptService")
	-- DataService owns all DataStore access (player data + receipt dedup) and the
	-- Studio/persistence gating, so receipt persistence goes through it rather than
	-- this module touching DataStoreService directly.
	local DataService = require(SSS.Scripts.Modules.DataService)

	-- Apply a product's reward to the buyer and return whether it was granted. Return
	-- false to make Roblox retry later (the service only ever calls a handler for a
	-- receipt it has confirmed un-processed, so handlers don't dedupe themselves).
	export type ProductHandler = (player: Player, receiptInfo: any) -> boolean

	local handlers: { [number]: ProductHandler } = {}

	-- Game passes are permanent (no ProcessReceipt). The handler grants the pass's
	-- reward; it must be idempotent (it can fire on purchase AND on an ownership check),
	-- so callers guard with their own "already granted" flag.
	export type GamePassHandler = (player: Player) -> ()
	local gamePassHandlers: { [number]: GamePassHandler } = {}

	-- Register the grant handler for a developer product id. One handler per product.
	function ProductService.RegisterProduct(productId: number, handler: ProductHandler)
		assert(type(productId) == "number", "ProductService.RegisterProduct: productId must be a number")
		if handlers[productId] then
			warn(("ProductService: product %d already has a handler; overwriting."):format(productId))
		end
		handlers[productId] = handler
	end

	-- Register the grant handler for a game pass id. Fired when the pass is purchased.
	function ProductService.RegisterGamePass(gamePassId: number, handler: GamePassHandler)
		assert(type(gamePassId) == "number", "ProductService.RegisterGamePass: gamePassId must be a number")
		if gamePassHandlers[gamePassId] then
			warn(("ProductService: game pass %d already has a handler; overwriting."):format(gamePassId))
		end
		gamePassHandlers[gamePassId] = handler
	end

	-- Whether the player owns a game pass (pcall'd; false on API error).
	function ProductService.PlayerOwnsGamePass(player: Player, gamePassId: number): boolean
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
		end)
		return ok and owns == true
	end

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local RETRY = Enum.ProductPurchaseDecision.NotProcessedYet

	local function processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then
			return RETRY -- buyer left mid-purchase; grant when they're back
		end

		local handler = handlers[receiptInfo.ProductId]
		if not handler then
			-- No handler this server version — don't consume the receipt; a server that
			-- knows the product can grant it on a retry.
			warn(("ProductService: no handler for product %d."):format(receiptInfo.ProductId))
			return RETRY
		end

		-- Their saved data must be loaded before we mutate + persist it, or the grant
		-- could be lost or clobbered by the loader. Retry until it's ready.
		if not DataService.IsLoaded(player) then
			return RETRY
		end

		local key = ("%d_%s"):format(receiptInfo.PlayerId, tostring(receiptInfo.PurchaseId))

		local ok, processed = DataService.IsReceiptProcessed(key)
		if not ok then
			return RETRY -- store errored; try later
		end
		if processed then
			return GRANTED -- idempotent: granted on an earlier (retried) call
		end

		-- Grant, then make it durable BEFORE recording the receipt, so a crash can't
		-- leave a recorded-but-ungranted purchase (player paid, got nothing). The
		-- alternative ordering risks exactly that, so we accept the rarer opposite
		-- (a re-grant if recording fails) in the player's favour.
		if not handler(player, receiptInfo) then
			return RETRY
		end
		if not DataService.SaveNow(player) then
			return RETRY -- couldn't persist the grant; retry (idempotency guards re-grant)
		end
		if not DataService.MarkReceiptProcessed(key) then
			return RETRY
		end
		return GRANTED
	end

	function ProductService.Init()
		MarketplaceService.ProcessReceipt = processReceipt
		-- Game pass purchases completed this session: dispatch to the registered grant.
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(
			function(player: Player, gamePassId: number, wasPurchased: boolean)
				if not wasPurchased then
					return
				end
				local handler = gamePassHandlers[gamePassId]
				if handler then
					handler(player)
				end
			end
		)
	end
end

----------------------------------------------------------------------------------
-- Client-only: prompt a purchase + report the outcome
----------------------------------------------------------------------------------
if RunService:IsClient() then
	local Players = game:GetService("Players")
	local Signal = require(RS.Shared.Signal)

	local localPlayer = Players.LocalPlayer

	-- Fires when a prompt this client opened closes: (productId, wasPurchased).
	ProductService.PromptFinished = Signal.new()

	-- Open the Roblox purchase dialog for a developer product. Fulfilment happens
	-- server-side in ProcessReceipt; listen to PromptFinished (or CurrencyService) to
	-- react once it completes.
	function ProductService.Prompt(productId: number)
		MarketplaceService:PromptProductPurchase(localPlayer, productId)
	end

	-- lastPromptAt[productId] = os.clock() of the last PromptThrottled call that actually
	-- opened the dialog for it (keyed per product, so e.g. the shared UpgradeBoost product
	-- gets ONE cooldown no matter which track/UI triggered it).
	local lastPromptAt: { [number]: number } = {}

	-- Like Prompt, but skips (and returns false) if this productId was already prompted
	-- within `interval` seconds — for "offer a purchase" flows that can otherwise re-fire on
	-- every click (e.g. clicking Buy repeatedly while unable to afford an upgrade). Returns
	-- whether it actually opened the dialog.
	function ProductService.PromptThrottled(productId: number, interval: number): boolean
		local now = os.clock()
		local last = lastPromptAt[productId]
		if last and (now - last) < interval then
			return false
		end
		lastPromptAt[productId] = now
		ProductService.Prompt(productId)
		return true
	end

	-- Open the Roblox purchase dialog for a game pass. Fulfilment is server-side via
	-- the registered game-pass handler (and an ownership check on load).
	function ProductService.PromptGamePass(gamePassId: number)
		MarketplaceService:PromptGamePassPurchase(localPlayer, gamePassId)
	end

	-- Parts carrying a numeric PromptPass attribute open that game pass's purchase dialog
	-- when the local player touches them. Per-part debounce so standing on one doesn't
	-- reopen the prompt every contact.
	local PROMPT_PASS_ATTR = "PromptPass"
	local PROMPT_DEBOUNCE = 1.5
	local promptBusy: { [BasePart]: boolean } = {}

	local function wirePromptPart(inst: Instance)
		if not inst:IsA("BasePart") then return end
		if inst:GetAttribute(PROMPT_PASS_ATTR) == nil then return end
		inst.Touched:Connect(function(obj: Instance)
			if not obj:IsDescendantOf(localPlayer.Character) then return end
			local passId = inst:GetAttribute(PROMPT_PASS_ATTR)
			if type(passId) ~= "number" then return end
			if promptBusy[inst] then return end
			promptBusy[inst] = true
			task.delay(PROMPT_DEBOUNCE, function()
				promptBusy[inst] = nil
			end)
			ProductService.PromptGamePass(passId)
		end)
	end

	function ProductService.Init()
		MarketplaceService.PromptProductPurchaseFinished:Connect(
			function(userId: number, productId: number, wasPurchased: boolean)
				if userId == localPlayer.UserId then
					ProductService.PromptFinished:Fire(productId, wasPurchased)
				end
			end
		)

		-- Wire existing PromptPass parts and any added later.
		for _, inst in workspace:GetDescendants() do
			wirePromptPart(inst)
		end
		workspace.DescendantAdded:Connect(wirePromptPart)
	end
end

return ProductService
