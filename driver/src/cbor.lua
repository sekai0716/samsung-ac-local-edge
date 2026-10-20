-- OCF 응답과 설정 명령에 사용하는 CBOR입니다. 크기·깊이를 제한합니다.
local M = { null = {} }

-- 명령에 필요한 문자열 키의 map, 연속 배열, 유한 숫자와 불리언만 인코딩합니다.
function M.encode(value)
  local function head(major, count)
    if count < 24 then return string.char((major << 5) | count) end
    if count <= 255 then return string.char((major << 5) | 24, count) end
    if count <= 65535 then return string.char((major << 5) | 25) .. string.pack(">I2", count) end
    error("CBOR encode size limit")
  end
  local item
  item = function(child, depth)
    assert(depth <= 32, "CBOR nesting limit")
    if child == M.null then return "\246" end
    if child == false then return "\244" end
    if child == true then return "\245" end
    if type(child) == "string" then return head(3, #child) .. child end
    if type(child) == "number" then
      assert(child == child and child ~= math.huge and child ~= -math.huge, "nonfinite CBOR number")
      if child % 1 == 0 and math.abs(child) <= 65535 then
        return child >= 0 and head(0, child) or head(1, -1 - child)
      end
      return "\251" .. string.pack(">d", child)
    end
    assert(type(child) == "table", "unsupported CBOR value")
    local keys, parts = {}, {}
    for key in pairs(child) do keys[#keys + 1] = key end
    if #child > 0 then
      assert(#keys == #child, "CBOR array must be contiguous")
      for _, key in ipairs(keys) do
        assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= #child, "invalid CBOR array key")
      end
      parts[1] = head(4, #child)
      for _, entry in ipairs(child) do parts[#parts + 1] = item(entry, depth + 1) end
    else
      for _, key in ipairs(keys) do assert(type(key) == "string", "CBOR map keys must be strings") end
      table.sort(keys)
      parts[1] = head(5, #keys)
      for _, key in ipairs(keys) do parts[#parts + 1] = item(key, depth + 1) .. item(child[key], depth + 1) end
    end
    local result = table.concat(parts)
    assert(#result <= 65536, "CBOR encode size limit")
    return result
  end
  local result = item(value, 0)
  assert(#result <= 65536, "CBOR encode size limit")
  return result
end

function M.decode(data)
  assert(type(data) == "string" and #data <= 65536, "CBOR input limit")
  local offset, stop = 1, {}
  local function take(count)
    assert(count >= 0 and offset + count - 1 <= #data, "truncated CBOR")
    local part = data:sub(offset, offset + count - 1)
    offset = offset + count
    return part
  end
  local function argument(ai)
    if ai < 24 then return ai end
    if ai == 24 then return string.byte(take(1)) end
    if ai == 25 then return (string.unpack(">I2", take(2))) end
    if ai == 26 then return (string.unpack(">I4", take(4))) end
    if ai == 27 then
      local raw = take(8)
      assert(raw:byte(1) < 128, "CBOR unsigned integer outside Lua range")
      return (string.unpack(">I8", raw))
    end
    if ai == 31 then return nil end
    error("reserved CBOR argument")
  end
  local item
  item = function(depth, allow_break)
    assert(depth <= 32, "CBOR nesting limit")
    local head = string.byte(take(1))
    local major, ai = head >> 5, head & 31
    if head == 255 then
      assert(allow_break, "unexpected CBOR break")
      return stop
    end
    if major == 7 then
      if ai == 20 then return false end
      if ai == 21 then return true end
      if ai == 22 or ai == 23 then return M.null end
      if ai == 24 then take(1); error("unsupported CBOR simple value") end
      if ai == 25 then
        local raw = string.unpack(">I2", take(2))
        local sign, exponent, fraction = raw >> 15, (raw >> 10) & 31, raw & 1023
        local value
        if exponent == 0 then value = fraction * 2 ^ -24
        elseif exponent == 31 then value = fraction == 0 and math.huge or (0 / 0)
        else value = (1 + fraction / 1024) * 2 ^ (exponent - 15) end
        return sign == 0 and value or -value
      end
      if ai == 26 then return (string.unpack(">f", take(4))) end
      if ai == 27 then return (string.unpack(">d", take(8))) end
      error("unsupported CBOR simple value")
    end
    local count = argument(ai)
    if major == 0 or major == 1 then
      assert(count ~= nil, "indefinite CBOR integer")
      return major == 0 and count or (-1 - count)
    end
    if major == 2 or major == 3 then
      if count then return take(count) end
      local chunks = {}
      while true do
        local next_head = data:byte(offset)
        assert(next_head, "truncated CBOR string")
        if next_head == 255 then offset = offset + 1; break end
        assert(next_head >> 5 == major and next_head & 31 ~= 31, "invalid CBOR string chunk")
        chunks[#chunks + 1] = item(depth + 1, false)
      end
      return table.concat(chunks)
    end
    if major == 4 or major == 5 then
      assert(not count or count <= #data, "CBOR container length limit")
      local result, index = {}, 1
      while not count or index <= count do
        local first = item(depth + 1, not count)
        if first == stop then break end
        if major == 4 then result[index] = first
        else
          assert(type(first) ~= "table", "unsupported CBOR map key")
          result[first] = item(depth + 1, false)
        end
        index = index + 1
      end
      return result
    end
    if major == 6 then
      assert(count ~= nil, "indefinite CBOR tag")
      return item(depth + 1, false)
    end
    error("unsupported CBOR major type")
  end
  local value = item(0, false)
  assert(offset == #data + 1, "trailing CBOR bytes")
  return value
end

return M
