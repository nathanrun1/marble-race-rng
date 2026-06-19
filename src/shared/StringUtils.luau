local StringUtils = {}

function StringUtils.Commas(n: number): string
    local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

function StringUtils.FormatShort(n: number, floorRound: boolean?, precision: number): string
    precision = precision or 2
    local FACTORS = {
        [1e15] = "Q",
        [1e12] = "T",
        [1e9]  = "B",
        [1e6]  = "M",
        [1e3]  = "K",
    }

    for f, l in FACTORS do
        if n < f then continue end
        n /= f
        if floorRound then
            n = math.floor(n * 10 ^ precision) / (10 ^ precision)
        end
        return ("%.2f"..l):format(n)
    end
    return string.format("%.2f", n)
end

-- Money string: comma-grouped below 1K (so small balances read exactly), short
-- suffixed (K/M/B/T/Q) above. Always prefixed with "$".
function StringUtils.FormatMoney(n: number): string
    if n < 1000 then
        return "$" .. StringUtils.Commas(n)
    end
    return "$" .. StringUtils.FormatShort(n)
end

return StringUtils