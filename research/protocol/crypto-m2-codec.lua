-- Research-only codec. This module does not collect a valid browser report.
local alphabet = "ZBCDe0WGH1IJ9Kl3MNo2PQRstuVF+/=XY5Aab4cdEfghij6kLmnOpq7rSTU8vwxyz"

return function(serialized_report)
    assert(type(serialized_report) == "string", "serialized report is required")
    local output = {}
    for offset = 1, #serialized_report, 3 do
        local a, b, c = serialized_report:byte(offset, offset + 2)
        local word = a * 65536 + (b or 0) * 256 + (c or 0)
        local first = math.floor(word / 262144) % 64 + 1
        local second = math.floor(word / 4096) % 64 + 1
        local third = b and math.floor(word / 64) % 64 + 1 or 65
        local fourth = c and word % 64 + 1 or 65
        output[#output + 1] = alphabet:sub(first, first) .. alphabet:sub(second, second)
            .. alphabet:sub(third, third) .. alphabet:sub(fourth, fourth)
    end
    return table.concat(output)
end
