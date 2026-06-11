--[[
  ShopPanelLayout.lua
  -------------------
  Generates the ShopFrame hierarchy with all transforms.
  Drop into StarterGui as a LocalScript, or run once from the command bar.

  The panel is designed at 560×478px (1920×1080 reference).
  A UIScale on the root frame keeps it device-agnostic — it shrinks cleanly
  on phones and tablets the same way the web prototype does.

  Layout only: no colours, no text content, no game logic.
  Wire those yourself after this creates the structure.
]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")

local player  = Players.LocalPlayer
local gui     = player:WaitForChild("PlayerGui")
local camera  = workspace.CurrentCamera

-- ─── helpers ────────────────────────────────────────────────────────────────

local function f(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local function corner(r, parent)
    f("UICorner", { CornerRadius = UDim.new(0, r) }, parent)
end

local function pad(top, right, bot, left, parent)
    f("UIPadding", {
        PaddingTop    = UDim.new(0, top),
        PaddingRight  = UDim.new(0, right),
        PaddingBottom = UDim.new(0, bot),
        PaddingLeft   = UDim.new(0, left),
    }, parent)
end

local function listH(gap, parent)
    f("UIListLayout", {
        FillDirection       = Enum.FillDirection.Horizontal,
        VerticalAlignment   = Enum.VerticalAlignment.Center,
        SortOrder           = Enum.SortOrder.LayoutOrder,
        Padding             = UDim.new(0, gap),
    }, parent)
end

local function listV(gap, parent)
    f("UIListLayout", {
        FillDirection       = Enum.FillDirection.Vertical,
        HorizontalAlignment = Enum.HorizontalAlignment.Left,
        SortOrder           = Enum.SortOrder.LayoutOrder,
        Padding             = UDim.new(0, gap),
    }, parent)
end

-- ─── root ScreenGui ─────────────────────────────────────────────────────────

local screenGui = f("ScreenGui", {
    Name             = "ShopGui",
    IgnoreGuiInset   = true,
    ResetOnSpawn     = false,
    ZIndexBehavior   = Enum.ZIndexBehavior.Sibling,
    Enabled          = true,
}, gui)

-- ─── ShopFrame (design size: 560 × 478) ─────────────────────────────────────
-- Centred via scale position + AnchorPoint.
-- UIScale handles all device sizing — never resize this frame manually.

local shopFrame = f("Frame", {
    Name         = "ShopFrame",
    Size         = UDim2.fromOffset(560, 478),
    Position     = UDim2.fromScale(0.5, 0.5),
    AnchorPoint  = Vector2.new(0.5, 0.5),
    BackgroundTransparency = 0,
    BorderSizePixel = 0,
}, screenGui)

corner(18, shopFrame)

-- UIScale: mirrors the web stage's transform:scale(min(vw/1920, vh/1080))
local uiScale = f("UIScale", { Scale = 1 }, shopFrame)
local function refreshScale()
    local vp = camera.ViewportSize
    if vp.X == 0 or vp.Y == 0 then return end
    uiScale.Scale = math.min(vp.X / 1920, vp.Y / 1080)
end
camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshScale)
refreshScale()

-- outer padding: 30 top, 34 sides, 34 bottom
pad(30, 34, 34, 34, shopFrame)

-- inner vertical stack
listV(0, shopFrame)    -- children: Head, TrackRow, EffectRow, Note, BuyButton

-- ─── 1 · HEAD (icon 64, name+desc, tier badge) ──────────────────────────────
-- Height is driven by the 64px icon; auto-sizes via AutomaticSize.

local head = f("Frame", {
    Name              = "Head",
    Size              = UDim2.new(1, 0, 0, 0),  -- width=fill, height=auto
    AutomaticSize     = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    LayoutOrder       = 1,
    BorderSizePixel   = 0,
}, shopFrame)

listH(16, head)

-- Icon square (64×64)
local icon = f("Frame", {
    Name           = "Icon",
    Size           = UDim2.fromOffset(64, 64),
    BackgroundTransparency = 0,
    BorderSizePixel = 0,
    LayoutOrder    = 1,
}, head)
corner(18, icon)

-- Name + Desc stacked inside a sub-frame (fills remaining space)
local nameStack = f("Frame", {
    Name               = "NameStack",
    Size               = UDim2.new(1, -(64 + 16 + 90 + 16), 0, 64), -- shrink-wrap siblings
    AutomaticSize      = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    BorderSizePixel    = 0,
    LayoutOrder        = 2,
}, head)

listV(4, nameStack)

f("TextLabel", {
    Name              = "ShopName",
    Size              = UDim2.new(1, 0, 0, 36),
    BackgroundTransparency = 1,
    TextSize          = 32,
    TextXAlignment    = Enum.TextXAlignment.Left,
    TextYAlignment    = Enum.TextYAlignment.Center,
    LayoutOrder       = 1,
    Text              = "Shop Name",       -- replace
}, nameStack)

f("TextLabel", {
    Name              = "ShopDesc",
    Size              = UDim2.new(1, 0, 0, 22),
    BackgroundTransparency = 1,
    TextSize          = 16,
    TextXAlignment    = Enum.TextXAlignment.Left,
    TextYAlignment    = Enum.TextYAlignment.Center,
    LayoutOrder       = 2,
    Text              = "Short description",  -- replace
    TextWrapped       = true,
}, nameStack)

-- Tier badge (90×64, right-most)
local tierBadge = f("Frame", {
    Name           = "TierBadge",
    Size           = UDim2.fromOffset(90, 64),
    BackgroundTransparency = 0,
    BorderSizePixel = 0,
    LayoutOrder    = 3,
}, head)

corner(12, tierBadge)

-- badge label stack (centred inside badge)
local badgeStack = f("Frame", {
    Name = "BadgeStack",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
}, tierBadge)
f("UIListLayout", {
    FillDirection        = Enum.FillDirection.Vertical,
    HorizontalAlignment  = Enum.HorizontalAlignment.Center,
    VerticalAlignment    = Enum.VerticalAlignment.Center,
    SortOrder            = Enum.SortOrder.LayoutOrder,
    Padding              = UDim.new(0, 2),
}, badgeStack)

f("TextLabel", {
    Name              = "TierNumber",
    Size              = UDim2.new(1, 0, 0, 30),
    BackgroundTransparency = 1,
    TextSize          = 24,
    TextXAlignment    = Enum.TextXAlignment.Center,
    LayoutOrder       = 1,
    Text              = "0 / 8",   -- replace at runtime
}, badgeStack)

f("TextLabel", {
    Name              = "TierLabel",
    Size              = UDim2.new(1, 0, 0, 14),
    BackgroundTransparency = 1,
    TextSize          = 11,
    TextXAlignment    = Enum.TextXAlignment.Center,
    LayoutOrder       = 2,
    Text              = "TIER",
    TextScaled        = false,
}, badgeStack)

-- spacer below head
f("Frame", {
    Name = "HeadSpacer", Size = UDim2.new(1, 0, 0, 20),
    BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = 2,
}, shopFrame)

-- ─── 2 · TIER TRACK ─────────────────────────────────────────────────────────
-- A horizontal row of N pips. Pips are created at runtime via renderShop().
-- The container is a fixed 14 tall so the pip height is always 14px regardless
-- of how many pips there are.

local track = f("Frame", {
    Name              = "Track",
    Size              = UDim2.new(1, 0, 0, 14),
    BackgroundTransparency = 1,
    BorderSizePixel   = 0,
    LayoutOrder       = 3,
    ClipsDescendants  = false,
}, shopFrame)

f("UIListLayout", {
    FillDirection       = Enum.FillDirection.Horizontal,
    VerticalAlignment   = Enum.VerticalAlignment.Center,
    FillEmptySpaceColumns = true,    -- pips stretch to fill width evenly
    SortOrder           = Enum.SortOrder.LayoutOrder,
    Padding             = UDim.new(0, 6),
}, track)

-- spacer below track
f("Frame", {
    Name = "TrackSpacer", Size = UDim2.new(1, 0, 0, 24),
    BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = 4,
}, shopFrame)

-- ─── 3 · EFFECT ROW (current → next) ────────────────────────────────────────
-- Three-column layout via a UIListLayout + explicit widths.
-- Cells size themselves; the arrow column is a fixed 44px.

local effect = f("Frame", {
    Name              = "Effect",
    Size              = UDim2.new(1, 0, 0, 110),
    BackgroundTransparency = 1,
    BorderSizePixel   = 0,
    LayoutOrder       = 5,
}, shopFrame)

listH(0, effect)

-- helper: one effect cell
local function effectCell(name, isNext, parent)
    -- width: fill the remaining space after the 44px arrow
    -- We use UDim2.new(0.5, -22, 1, 0) so both cells each take half minus half-arrow
    local cell = f("Frame", {
        Name              = name,
        Size              = UDim2.new(0.5, -22, 1, 0),
        BackgroundTransparency = 0,
        BorderSizePixel   = 0,
        LayoutOrder       = isNext and 3 or 1,
    }, parent)
    corner(16, cell)

    local stack = f("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
    }, cell)
    f("UIListLayout", {
        FillDirection        = Enum.FillDirection.Vertical,
        HorizontalAlignment  = Enum.HorizontalAlignment.Center,
        VerticalAlignment    = Enum.VerticalAlignment.Center,
        SortOrder            = Enum.SortOrder.LayoutOrder,
        Padding              = UDim.new(0, 6),
    }, stack)

    f("TextLabel", {
        Name = "Cap", Text = isNext and "NEXT TIER" or "CURRENT",
        Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
        TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center,
        LayoutOrder = 1,
    }, stack)

    f("TextLabel", {
        Name = "Value", Text = "—",
        Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1,
        TextSize = 36, TextXAlignment = Enum.TextXAlignment.Center,
        LayoutOrder = 2,
    }, stack)

    return cell
end

effectCell("CurrentCell", false, effect)

-- arrow (44px wide, full height)
local arrowFrame = f("Frame", {
    Name = "ArrowFrame", Size = UDim2.new(0, 44, 1, 0),
    BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = 2,
}, effect)
f("TextLabel", {
    Name = "Arrow", Text = "→",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    TextSize = 26,
    TextXAlignment = Enum.TextXAlignment.Center,
    TextYAlignment = Enum.TextYAlignment.Center,
}, arrowFrame)

effectCell("NextCell", true, effect)

-- spacer below effect
f("Frame", {
    Name = "EffectSpacer", Size = UDim2.new(1, 0, 0, 14),
    BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = 6,
}, shopFrame)

-- ─── 4 · NOTE ────────────────────────────────────────────────────────────────

f("TextLabel", {
    Name              = "Note",
    Size              = UDim2.new(1, 0, 0, 36),
    BackgroundTransparency = 1,
    BorderSizePixel   = 0,
    TextSize          = 15,
    TextXAlignment    = Enum.TextXAlignment.Center,
    TextYAlignment    = Enum.TextYAlignment.Center,
    TextWrapped       = true,
    LayoutOrder       = 7,
    Text              = "Effect note",  -- replace
}, shopFrame)

-- spacer below note
f("Frame", {
    Name = "NoteSpacer", Size = UDim2.new(1, 0, 0, 14),
    BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = 8,
}, shopFrame)

-- ─── 5 · BUY BUTTON ──────────────────────────────────────────────────────────
-- ImageButton (swap to pressed image on MouseButton1Down).
-- Word + Price are separate children so Word can shift independently on press.

local buyButton = f("ImageButton", {
    Name              = "BuyButton",
    Size              = UDim2.new(1, 0, 0, 92),
    BackgroundTransparency = 1,
    BorderSizePixel   = 0,
    AutoButtonColor   = false,
    LayoutOrder       = 9,
    -- Image = ASSETS.button  ← set from your asset ID
    ScaleType         = Enum.ScaleType.Slice,
    SliceCenter       = Rect.new(110, 120, 1010, 200),  -- matches the 2x button-launch.png
    SliceScale        = 0.5,
}, shopFrame)

-- inner frame keeps children anchored to the centre of the face
-- (the face sits slightly above the bottom of the button due to the 3D lip)
local buyInner = f("Frame", {
    Name = "BuyInner",
    -- face region: top 76px of the 92px button; lip is bottom 16px
    Size              = UDim2.new(1, 0, 0, 76),
    Position          = UDim2.fromOffset(0, 0),
    BackgroundTransparency = 1,
    BorderSizePixel   = 0,
}, buyButton)

f("UIListLayout", {
    FillDirection       = Enum.FillDirection.Horizontal,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment   = Enum.VerticalAlignment.Center,
    SortOrder           = Enum.SortOrder.LayoutOrder,
    Padding             = UDim.new(0, 14),
}, buyInner)

f("TextLabel", {
    Name          = "Word",
    Text          = "UPGRADE",
    Size          = UDim2.fromOffset(220, 56),
    BackgroundTransparency = 1,
    TextSize      = 36,
    TextXAlignment = Enum.TextXAlignment.Center,
    LayoutOrder   = 1,
}, buyInner)

local priceChip = f("Frame", {
    Name          = "PriceChip",
    Size          = UDim2.fromOffset(180, 46),
    BackgroundTransparency = 0,
    BorderSizePixel = 0,
    LayoutOrder   = 2,
}, buyInner)
corner(12, priceChip)

f("TextLabel", {
    Name          = "PriceLabel",
    Text          = "$10,000",    -- replace at runtime
    Size          = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    TextSize      = 26,
    TextXAlignment = Enum.TextXAlignment.Center,
}, priceChip)

-- press: shift Word + PriceChip down to match the button image pressing in
local WORD_REST  = buyInner.Word.Position         -- UDim2.fromOffset(0, 0) relative to inner
local PRICE_REST = priceChip.Position

buyButton.MouseButton1Down:Connect(function()
    -- swap to pressed image:   buyButton.Image = ASSETS.buttonDown
    buyInner.Word.Position  = WORD_REST  + UDim2.fromOffset(0, 5)
    priceChip.Position      = PRICE_REST + UDim2.fromOffset(0, 5)
end)
local function release()
    -- buyButton.Image = ASSETS.button
    buyInner.Word.Position  = WORD_REST
    priceChip.Position      = PRICE_REST
end
buyButton.MouseButton1Up:Connect(release)
buyButton.MouseLeave:Connect(release)

-- ─── FLARE (floats above panel, shown on successful upgrade) ─────────────────
-- Parented to the ScreenGui (not ShopFrame) so it isn't clipped.
-- Position it above the ShopFrame at runtime using ShopFrame.AbsolutePosition.

f("TextLabel", {
    Name              = "UpgradeFlare",
    Size              = UDim2.fromOffset(300, 60),
    AnchorPoint       = Vector2.new(0.5, 1),
    -- Position at runtime: UDim2.fromOffset(ShopFrame.AbsolutePosition.X + 280, ShopFrame.AbsolutePosition.Y - 10)
    Position          = UDim2.new(0.5, 0, 0.5, -260),  -- rough default; set dynamically
    BackgroundTransparency = 1,
    TextSize          = 38,
    TextXAlignment    = Enum.TextXAlignment.Center,
    Text              = "TIER 1!",   -- replace at runtime
    Visible           = false,
    ZIndex            = 10,
}, screenGui)

-- ─── done ────────────────────────────────────────────────────────────────────
print("[ShopPanel] Layout generated. Wire colours, text, UIStroke, and game logic.")
