local StringUtils = {}

function StringUtils.Commas(n: number): string
    local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

function StringUtils.FormatShort(n: number, floorRound: boolean?, precision: number): string
    precision = precision or 2
    local SCI_AT = 1e15
    local FACTORS_ORD = {1e12, 1e9, 1e6, 1e3}
    local FACTORS = {
        [1e12] = "T",
        [1e9]  = "B",
        [1e6]  = "M",
        [1e3]  = "K",
    }
    print("format for number: " .. n)

    if n >= SCI_AT then
        local factor = math.floor(math.log10(n))
        n /= 10 ^ factor
        print("factor: "..factor)
        if floorRound then
            n = math.floor(n * 10 ^ precision) / (10 ^ precision)
        end
        return string.format("%."..precision.."fe%d", n, factor) 
    end 

    for _, f in ipairs(FACTORS_ORD) do
        local l = FACTORS[f]
        if n < f then continue end
        n /= f
        if floorRound then
            n = math.floor(n * 10 ^ precision) / (10 ^ precision)
        end
        return ("%."..precision.."f"..l):format(n)
    end
    return string.format("%."..precision.."f", n)
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