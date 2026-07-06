local StringUtils = {}

function StringUtils.Commas(n: number): string
    local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

function StringUtils.FormatShort(n: number, floorRound: boolean?, precision: number?): string
    precision = precision or 2
    local SCI_AT = 1e15
    local FACTORS_ORD = {1e12, 1e9, 1e6, 1e3}
    local FACTORS = {
        [1e15] = "Q",
        [1e12] = "T",
        [1e9]  = "B",
        [1e6]  = "M",
        [1e3]  = "K",
    }

    local sciFactor = 0
    local factor = ""

    if n >= SCI_AT then
        sciFactor = math.floor(math.log10(n))
        n /= 10 ^ sciFactor
        if floorRound then
            n = math.floor(n * 10 ^ precision) / (10 ^ precision)
        end
    end 

    for _, f in ipairs(FACTORS_ORD) do
        local l = FACTORS[f]
        if n < f then continue end
        n /= f

        factor = l
    end

    if floorRound then
        n = math.floor(n * 10 ^ precision) / (10 ^ precision)
    end

    if sciFactor > 0 then
        return string.format("%."..precision.."fe%d", n, sciFactor)
    elseif factor ~= "" then
        return string.format("%."..precision.."f%s", n, factor)
    end

    -- No suffix or scientific notation to justify padded decimals: drop a purely-.00 tail
    -- (a x2 multiplier reads as "2", not "2.00"), but keep a genuine fraction (x1.35 stays as-is).
    local plain = string.format("%."..precision.."f", n)
    local whole, frac = plain:match("^(%-?%d+)%.(%d+)$")
    if frac and tonumber(frac) == 0 then
        return whole
    end
    return plain
end

-- Money string: comma-grouped below 1K (so small balances read exactly), short
-- suffixed (K/M/B/T/Q) above. Always prefixed with "$".
function StringUtils.FormatMoney(n: number, floorRound: boolean?, precision: number?): string
    return "$" .. StringUtils.FormatShort(n, floorRound, precision)
end

-- Like FormatMoney but for non-currency counts (PP, costs, ...): comma-grouped below
-- 1K, short-suffixed (K/M/B/T) above, no "$".
function StringUtils.FormatCompact(n: number, floorRound: boolean?, precision: number?): string
    if n < 1000 then
        return StringUtils.Commas(n)
    end
    return StringUtils.FormatShort(n, floorRound, precision)
end

return StringUtils