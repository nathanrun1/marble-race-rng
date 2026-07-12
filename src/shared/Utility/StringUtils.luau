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

    -- Only as many digits as the value needs: "2.00" -> "2", "1.50" -> "1.5", "1.35"
    -- stays — applied to plain, suffixed ("1.5K") and scientific ("1.2e16") forms alike.
    local function trimZeros(s: string): string
        if not s:find(".", 1, true) then
            return s
        end
        s = s:gsub("0+$", ""):gsub("%.$", "")
        return s
    end

    local body = trimZeros(string.format("%."..precision.."f", n))
    if sciFactor > 0 then
        return body .. "e" .. tostring(sciFactor)
    end
    return body .. factor
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