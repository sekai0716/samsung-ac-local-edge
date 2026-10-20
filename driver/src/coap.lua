-- RFC 7252/8323의 GET·POST·CSM·ACK를 처리합니다. POST는 자동 재전송하지 않습니다.
local M = { MAX_FRAME = 65536 }
local sequence = os.time() & 0xffffffff

function M.token()
  sequence = (sequence + 1) & 0xffffffff
  return string.pack(">I4", sequence)
end

local function nibble(value)
  assert(value >= 0 and value <= M.MAX_FRAME, "CoAP length limit")
  if value < 13 then return value, "" end
  if value < 269 then return 13, string.char(value - 13) end
  return 14, string.pack(">I2", value - 269)
end

function M.options(path, query, content_format)
  assert(type(path) == "string" and path:sub(1, 1) == "/", "invalid CoAP path")
  local result, previous = {}, 0
  local function add(number, value)
    local d, de = nibble(number - previous)
    local l, le = nibble(#value)
    result[#result + 1] = string.char((d << 4) | l) .. de .. le .. value
    previous = number
  end
  for segment in path:gmatch("[^/]+") do add(11, segment) end
  if content_format then add(12, "\60") end -- application/cbor, 공개 구현과 같은 Content-Format 60
  if query then add(15, query) end
  if content_format then add(17, "\60") end
  return table.concat(result)
end

function M.tcp_post(path, token, payload)
  assert(#token > 0 and #token <= 8, "invalid CoAP token")
  assert(type(payload) == "string" and #payload > 0 and #payload <= 1024, "CoAP command payload limit")
  local body = M.options(path, nil, true) .. "\255" .. payload
  local n, extension = nibble(#body)
  return string.char((n << 4) | #token) .. extension .. "\2" .. token .. body
end

function M.parse_options(data)
  local offset, number, options = 1, 0, {}
  local function extend(value)
    if value < 13 then return value end
    assert(value ~= 15, "reserved CoAP option")
    local count = value == 13 and 1 or 2
    assert(offset + count - 1 <= #data, "truncated CoAP option extension")
    local n = count == 1 and data:byte(offset) or string.unpack(">I2", data, offset)
    offset = offset + count
    return n + (count == 1 and 13 or 269)
  end
  while offset <= #data do
    local head = data:byte(offset)
    offset = offset + 1
    if head == 255 then
      assert(offset <= #data, "empty CoAP payload marker")
      return options, data:sub(offset)
    end
    number = number + extend(head >> 4)
    local size = extend(head & 15)
    assert(offset + size - 1 <= #data, "truncated CoAP option")
    options[#options + 1] = { number = number, value = data:sub(offset, offset + size - 1) }
    offset = offset + size
  end
  return options, ""
end

function M.tcp_get(path, token, query)
  assert(#token > 0 and #token <= 8, "invalid CoAP token")
  local options = M.options(path, query)
  local n, extension = nibble(#options)
  return string.char((n << 4) | #token) .. extension .. "\1" .. token .. options
end

function M.udp_get(path, token, query)
  assert(#token == 4, "invalid UDP token")
  return "\68\1" .. token:sub(3, 4) .. token .. M.options(path, query)
end

-- 멀티캐스트 요청은 RFC 7252에 따라 NON 메시지로 보냅니다. 일반 GET의 형식은 유지합니다.
function M.udp_discovery(token)
  local packet = M.udp_get("/oic/res", token, "rt=oic.d.airconditioner")
  return "\84" .. packet:sub(2)
end

function M.udp_reply(data, token)
  assert(#data >= 4 and data:byte(1) >> 6 == 1, "invalid CoAP datagram")
  local head, code, length = data:byte(1), data:byte(2), data:byte(1) & 15
  assert(length <= 8 and #data >= 4 + length, "invalid UDP token length")
  if code == 0 or data:sub(5, 4 + length) ~= token then return nil end
  local options, payload = M.parse_options(data:sub(5 + length))
  for _, option in ipairs(options) do
    if option.number == 23 then
      local value = 0
      for i = 1, #option.value do value = (value << 8) | option.value:byte(i) end
      assert(value & 8 == 0, "public directory requires filtered discovery")
    end
  end
  local ack = (head >> 4) & 3 == 0 and ("\96\0" .. data:sub(3, 4)) or nil
  return { code = code, payload = payload, ack = ack }
end

-- TCP 부분 수신과 송신 모두 요청 전체의 기한을 공유합니다.
local function exact(stream, count, now, deadline)
  local parts, received = {}, 0
  while received < count do
    local left = deadline - now()
    assert(left > 0, "CoAP request deadline")
    local _, timeout_error = stream:settimeout(left)
    assert(not timeout_error, "socket timeout configuration failed")
    local data, err, partial = stream:receive(count - received)
    local chunk = data or partial or ""
    parts[#parts + 1], received = chunk, received + #chunk
    if not data and received < count then error("CoAP receive: " .. tostring(err)) end
  end
  return table.concat(parts)
end

function M.send(stream, data, now, deadline)
  local offset = 1
  while offset <= #data do
    assert(deadline > now(), "CoAP send deadline")
    local _, timeout_error = stream:settimeout(deadline - now())
    assert(not timeout_error, "socket timeout configuration failed")
    local last, err, partial = stream:send(data, offset)
    last = last or partial
    assert(last and last >= offset, "CoAP send: " .. tostring(err))
    offset = last + 1
  end
end

function M.read_frame(stream, now, deadline)
  local head = exact(stream, 1, now, deadline):byte(1)
  local length, tkl = head >> 4, head & 15
  assert(tkl <= 8, "invalid CoAP token length")
  if length >= 13 then
    local count = ({ [13] = 1, [14] = 2, [15] = 4 })[length]
    local base = ({ [13] = 13, [14] = 269, [15] = 65805 })[length]
    local raw = exact(stream, count, now, deadline)
    local value = 0
    for i = 1, #raw do value = (value << 8) | raw:byte(i) end
    length = value + base
  end
  assert(length <= M.MAX_FRAME, "CoAP frame limit")
  local body = exact(stream, 1 + tkl + length, now, deadline)
  return body:byte(1), body:sub(2, 1 + tkl), body:sub(2 + tkl)
end

-- 이미 전송한 POST는 응답 유실 시에도 여기서 다시 보내지 않습니다.
local function exchange(stream, packet, token, now, timeout)
  local deadline = now() + timeout
  M.send(stream, packet, now, deadline)
  for _ = 1, 8 do
    local code, response_token, body = M.read_frame(stream, now, deadline)
    if code ~= 225 and response_token == token then
      local _, payload = M.parse_options(body)
      return code, payload
    end
  end
  error("no correlated CoAP response")
end

function M.get(stream, path, query, now, timeout)
  local token = M.token()
  local code, payload = exchange(stream, M.tcp_get(path, token, query), token, now, timeout)
  assert(code == 69, string.format("CoAP GET rejected %d.%02d", code >> 5, code & 31))
  return payload
end

function M.post(stream, path, payload, now, timeout)
  local token = M.token()
  return exchange(stream, M.tcp_post(path, token, payload), token, now, timeout)
end

return M
