local root, fixture_path = arg[1], arg[2]
assert(_VERSION == "Lua 5.3", "Lua 5.3 runtime is required")
package.path = root .. "/driver/src/?.lua;" .. package.path
local cbor, coap, ac, network = require "cbor", require "coap", require "ac", require "network"
local passed = 0
local function test(name, fn)
  local ok, failure = pcall(fn)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("ok " .. passed .. " " .. name)
end
local function fails(fn)
  local ok = pcall(fn)
  assert(not ok, "expected failure")
end
local function hex(value)
  return (value:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end
-- 응답을 모사하는 테스트 전용 인코더이며 허브 패키지에는 포함되지 않습니다.
local function encode(value)
  local function head(major, count)
    if count < 24 then return string.char((major << 5) | count) end
    if count < 256 then return string.char((major << 5) | 24, count) end
    return string.char((major << 5) | 25) .. string.pack(">I2", count)
  end
  if value == false then return "\244" end
  if value == true then return "\245" end
  if type(value) == "number" then return head(0, value) end
  if type(value) == "string" then return head(3, #value) .. value end
  local output = {}
  if #value > 0 then
    output[1] = head(4, #value)
    for _, child in ipairs(value) do output[#output + 1] = encode(child) end
  else
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    output[1] = head(5, count)
    for key, child in pairs(value) do output[#output + 1] = encode(key) .. encode(child) end
  end
  return table.concat(output)
end
local function frame(code, token, body)
  body = body or ""
  local size, extension = #body, ""
  if size >= 269 then extension = string.pack(">I2", size - 269); size = 14
  elseif size >= 13 then extension = string.char(size - 13); size = 13 end
  return string.char((size << 4) | #token) .. extension .. string.char(code) .. token .. body
end
local function stream(data)
  return {
    data = data or "", closed = false,
    settimeout = function() return 1 end,
    receive = function(self, count)
      if #self.data == 0 then return nil, "closed", "" end
      local part = self.data:sub(1, math.min(count, 3))
      self.data = self.data:sub(#part + 1)
      return part
    end,
    send = function(_, text) return #text end,
    close = function(self) self.closed = true end,
  }
end
local now = function() return 0 end
local P = "x.com.samsung.da."
local file = assert(io.open(fixture_path, "rb"))
local observed = cbor.decode(file:read("*a")); file:close()
local captured_events = {}

-- stock capability 이벤트 모양은 공식 API JSON 스키마로도 검사합니다.
local function capabilities()
  local result = {}
  local definitions = {
    switch = { { "switch" }, { "on", "off" } },
    doorControl = { { "door" }, { "open", "close" } },
    airConditionerMode = { { "airConditionerMode", "supportedAcModes", "availableAcModes" }, { "setAirConditionerMode" } },
    airConditionerFanMode = { { "fanMode", "supportedAcFanModes", "availableAcFanModes" }, { "setFanMode" } },
    thermostatCoolingSetpoint = { { "coolingSetpoint", "coolingSetpointRange" }, { "setCoolingSetpoint" } },
    temperatureMeasurement = { { "temperature" }, {} }, relativeHumidityMeasurement = { { "humidity" }, {} },
    refresh = { {}, { "refresh" } },
    dustSensor = { { "dustLevel", "fineDustLevel" }, {} },
    veryFineDustSensor = { { "veryFineDustLevel" }, {} },
    odorSensor = { { "odorLevel" }, {} },
    airQualityHealthConcern = { { "airQualityHealthConcern", "supportedAirQualityValues" }, {} },
    ["instantcommon43059.samsungAcLocalTimer"] = { { "onDelay", "offDelay" }, { "setOnDelay", "setOffDelay", "cancelOn", "cancelOff" } },
    ["instantcommon43059.samsungAcLocalNativeTimer"] = { { "onDelay", "offDelay" }, { "setOnDelay", "setOffDelay" } },
    ["instantcommon43059.samsungAcLocalSettings"] = { { "lighting", "voice" }, { "setLighting", "setVoice" } },
    ["instantcommon43059.samsungAcLocalComfort"] = { { "preset", "windfree", "purify", "outlet", "presetEnabled", "windfreeEnabled", "purifyEnabled", "setpointEnabled", "fanEnabled" },
      { "setPreset", "setWindfree", "setPurify", "setOutlet" } },
    ["instantcommon43059.samsungAcLocalDeviceSettings"] = { { "lighting", "voice", "display" }, { "setLighting", "setVoice", "setDisplay" } },
    ["instantcommon43059.samsungAcLocalCare"] = { { "autoclean", "panel", "panelEnabled" }, { "setAutoclean", "setPanel" } },
    ["instantcommon43059.samsungAcLocalOperation"] = { { "mode", "setpoint", "fan" }, { "setMode", "setTemperature", "setFan" } },
    ["instantcommon43059.samsungAcLocalOperating"] = { { "mode", "fan", "fanEnabled" }, { "setMode", "setFan" } },
    ["instantcommon43059.samsungAcLocalTemperature"] = { { "setpoint", "setpointEnabled" }, { "setTemperature" } },
    ["instantcommon43059.samsungAcLocalAirFeatures"] = { { "windfree", "purify", "windfreeEnabled", "purifyEnabled" }, { "setWindfree", "setPurify" } },
    ["instantcommon43059.samsungAcLocalDisplay"] = { { "display" }, { "setDisplay" } },
    ["instantcommon43059.samsungAcLocalPanel"] = { { "panel", "panelEnabled" }, { "setPanel" } },
    ["instantcommon43059.samsungAcLocalSensors"] = { { "monitoring", "temperature", "humidity", "airQuality", "dustLevel", "fineDustLevel", "veryFineDustLevel", "gas" }, {} },
  }
  for id, definition in pairs(definitions) do
    local capability = { ID = id, commands = {} }; result[id] = capability
    for _, attribute in ipairs(definition[1]) do
      capability[attribute] = function(value)
        local event = { capability = { ID = id }, attribute = { NAME = attribute }, value = { value = value } }
        if type(value) == "table" and value.value ~= nil then event.value = value end
        return event
      end
    end
    for _, command in ipairs(definition[2]) do capability.commands[command] = { NAME = command } end
  end
  return result
end

test("CBOR indefinite map, array, text and false/null", function()
  local value = cbor.decode(hex("bf61619ff4f601ff61627f61616162ffff"))
  assert(value.a[1] == false and value.a[2] == cbor.null and value.a[3] == 1)
  assert(value.b == "ab")
end)
test("CBOR float widths and negative integer", function()
  local value = cbor.decode(hex("84f93e00fa3fc00000fb3ff800000000000020"))
  assert(value[1] == 1.5 and value[2] == 1.5 and value[3] == 1.5 and value[4] == -1)
end)
test("CBOR malformed and excessive nesting fail", function()
  for _, value in ipairs({ "", hex("a16161"), hex("ffff"), hex("0101"), string.rep("\129", 34) .. "\0" }) do
    fails(function() cbor.decode(value) end)
  end
end)
test("Command CBOR matches independent wire vectors and rejects invalid inputs", function()
  assert(cbor.encode({ a = false }) == hex("a16161f4"))
  assert(cbor.encode({ a = { "Cool" } }) == hex("a161618164436f6f6c"))
  assert(cbor.encode(-1) == hex("20") and cbor.encode(24.5) == hex("fb4038800000000000"))
  for _, value in ipairs({ math.huge, 0 / 0, { [2] = "gap" }, { a = function() end } }) do
    fails(function() cbor.encode(value) end)
  end
end)
test("RFC8323 figure with Len zero and one byte token", function()
  local code, token, body = coap.read_frame(stream(hex("01437f")), now, 1)
  assert(code == 67 and token == "\127" and body == "")
end)
test("TCP extended lengths survive fragmented reads", function()
  for _, length in ipairs({ 13, 269, 4096 }) do
    local code, token, body = coap.read_frame(stream(frame(69, "abcd", string.rep("a", length))), now, 1)
    assert(code == 69 and token == "abcd" and #body == length)
  end
end)
test("GET method and separate URI query", function()
  local code, _, body = coap.read_frame(stream(coap.tcp_get("/device/0", "abcd", "if=oic.if.b")), now, 1)
  local options, payload = coap.parse_options(body)
  assert(code == 1 and #options == 3 and payload == "")
  assert(options[1].number == 11 and options[1].value == "device")
  assert(options[3].number == 15 and options[3].value == "if=oic.if.b")
end)
test("POST contains CBOR content format and correctly sized payload", function()
  local code, token, body = coap.read_frame(stream(coap.tcp_post("/power/vs/0", "abcd", hex("a16161f4"))), now, 1)
  local options, payload = coap.parse_options(body)
  assert(code == 2 and token == "abcd" and payload == hex("a16161f4"))
  assert(options[4].number == 12 and options[4].value == "\60")
  assert(options[5].number == 17 and options[5].value == "\60")
  fails(function() coap.tcp_post("/power/vs/0", "abcd", string.rep("x", 1025)) end)
end)
test("Malformed options, invalid token and oversized frames fail", function()
  for _, raw in ipairs({ hex("f0"), hex("01"), hex("0d"), hex("ff") }) do fails(function() coap.parse_options(raw) end) end
  fails(function() coap.read_frame(stream(hex("f0ffffffff")), now, 1) end)
  fails(function() coap.read_frame(stream(hex("0945")), now, 1) end)
end)
test("CSM and unrelated tokens do not become state", function()
  local original = coap.token
  coap.token = function() return "good" end
  local reply = frame(225, "") .. frame(69, "nope", "\255\244") .. frame(69, "good", "\255\244")
  local value = coap.get(stream(reply), "/power/0", nil, now, 1)
  coap.token = original
  assert(cbor.decode(value) == false)
end)
test("Forbidden is an error rather than power Off", function()
  local original = coap.token
  coap.token = function() return "good" end
  fails(function() coap.get(stream(frame(131, "good")), "/power/0", nil, now, 1) end)
  coap.token = original
end)
test("UDP CON response receives an empty ACK", function()
  local reply = coap.udp_reply("\68\69\18\52abcd\255\244", "abcd")
  assert(reply.code == 69 and reply.ack == "\96\0\18\52")
  assert(coap.udp_reply("\100\69\18\52nope\255\244", "abcd") == nil)
end)
test("Multicast discovery uses NON GET and the air-conditioner filter", function()
  local packet = coap.udp_discovery("abcd")
  assert(packet:byte(1) == 84 and packet:byte(2) == 1 and packet:sub(5, 8) == "abcd")
  local options = coap.parse_options(packet:sub(9))
  assert(#options == 3 and options[1].value == "oic" and options[2].value == "res")
  assert(options[3].number == 15 and options[3].value == "rt=oic.d.airconditioner")
end)
test("TLS endpoint comes from TCP advertisement", function()
  assert(network.endpoint({ { links = { { href = "/oic/sec/doxm", p = { sec = true, port = 37034, ["x.org.iotivity.tls"] = 43834 } } } } }) == 43834)
  fails(function() network.endpoint({ href = "/oic/sec/doxm", p = { sec = true, port = 37034 } }) end)
end)
test("Only specific private IPv4 targets are accepted", function()
  assert(network.valid_host("192.168.1.170") and network.valid_host("172.16.1.1"))
  for _, host in ipairs({ "127.0.0.1", "0.0.0.0", "192.168.1.999", "example.com", "8.8.8.8", "192.168.1.1/0" }) do assert(not network.valid_host(host)) end
end)

-- 검색 응답과 후속 공개 조회를 모사합니다. 시간은 timeout만큼 진행하므로 대기 없이 기한을 검사합니다.
local function scanner_fixture(peers, behavior)
  behavior = behavior or {}
  local tick, sockets, sent = 0, {}, {}
  local api = { gettime = function() return tick end }
  local peers_by_host = {}
  for _, peer in ipairs(peers) do peers_by_host[peer.host] = peer end
  api.udp = function()
    local udp = stream(); sockets[#sockets + 1] = udp
    local multicast = #sockets == 1
    udp.queue = {}
    udp.setsockname = function(_, host, port)
      assert(host == "*" and port == 0)
      if behavior.bind_error then return nil, "test bind failure" end
      return 1
    end
    udp.setoption = function(_, name, value)
      -- V3 허브가 허용한 옵션만 모사해 PC LuaSocket 전용 호출의 회귀를 잡습니다.
      assert(({ timeout = true, broadcast = true, ["ip-add-membership"] = true,
        reuseaddr = true, reuseport = true, ["ip-multicast-loop"] = true })[name],
        "unsupported hub UDP socket option: " .. tostring(name))
      return 1
    end
    udp.settimeout = function(self, seconds) self.timeout = seconds; return 1 end
    udp.sendto = function(self, packet, host, port)
      sent[#sent + 1] = { packet = packet, host = host, port = port }
      if packet:byte(2) == 0 then return #packet end
      assert(packet:byte(2) == 1, "discovery must never write")
      local token = packet:sub(5, 8)
      if multicast then
        assert(host == "224.0.1.187" and port == 5683 and packet:byte(1) == 84)
        for _, peer in ipairs(peers) do
          local payload = peer.malformed and "\255" or encode({ links = {
            { href = "/oic/d", rt = { peer.advertised_kind or "oic.d.airconditioner" } } } })
          local reply = string.char(peer.confirmable and 68 or 84, 69) .. "\18\52" .. (peer.wrong_token and "nope" or token) .. "\255" .. payload
          self.queue[#self.queue + 1] = { reply, peer.host, peer.port or 39954 }
        end
      else
        local peer = assert(peers_by_host[host])
        if peer.unreachable then return #packet end
        local path = ""
        for _, option in ipairs(coap.parse_options(packet:sub(9))) do
          if option.number == 11 then path = path .. "/" .. option.value end
        end
        local value
        if path == "/oic/d" then value = { di = peer.identity or peer.host, rt = { peer.actual_kind or "oic.d.airconditioner" } }
        elseif path == "/oic/p" then value = { mnmn = peer.manufacturer or "Samsung Electronics", mnmo = peer.model or "A20_FAC_BORA_18K|private|private" }
        else value = { { links = { { href = "/oic/sec/doxm", p = { sec = true, ["x.org.iotivity.tls"] = 43834 } } } } } end
        self.queue[1] = { "\100\69\18\52" .. token .. "\255" .. encode(value), host, 39954 }
      end
      return #packet
    end
    udp.receivefrom = function(self)
      if behavior.receive_error then return nil, "test receive failure" end
      if #self.queue > 0 then return table.unpack(table.remove(self.queue, 1)) end
      tick = tick + (self.timeout or 0.25)
      return nil, "timeout"
    end
    return udp
  end
  return api, sockets, sent
end
test("Discovery verifies Samsung model, deduplicates identities and ignores unrelated packets", function()
  local api, sockets, sent = scanner_fixture({
    { host = "192.168.1.170", identity = "ac-a", confirmable = true },
    { host = "192.168.1.170", identity = "ac-a" },
    { host = "192.168.1.171", identity = "ac-a" },
    { host = "192.168.1.172", identity = "ac-b" },
    { host = "192.168.1.81", advertised_kind = "oic.d.tv" },
    { host = "192.168.1.82", actual_kind = "oic.d.tv" },
    { host = "192.168.1.83", manufacturer = "Other" },
    { host = "192.168.1.84", model = "UNKNOWN_AC" },
    { host = "192.168.1.85", malformed = true }, { host = "192.168.1.86", wrong_token = true },
    { host = "8.8.8.8" },
  })
  local context = {}
  local found = network.scan(api, context)
  assert(#found == 2 and found[1].identity == "ac-a" and found[2].identity == "ac-b")
  assert(found[1].host == "192.168.1.170" and found[1].model == "A20_FAC_BORA_18K")
  assert(context.udp == nil)
  local ack = false
  for _, request in ipairs(sent) do
    if request.packet:byte(2) == 0 then ack = request.host == "192.168.1.170" and request.port == 39954 end
    assert(request.host ~= "8.8.8.8")
  end
  assert(ack)
  for _, udp in ipairs(sockets) do assert(udp.closed) end
end)
test("Discovery tolerates one unreachable candidate and can find only the bound identity", function()
  local api, sockets = scanner_fixture({ { host = "192.168.1.160", unreachable = true },
    { host = "192.168.1.170", identity = "other" }, { host = "192.168.1.171", identity = "bound" } })
  local result = network.scan(api, {}, nil, "bound")
  assert(#result == 1 and result[1].host == "192.168.1.171" and result[1].identity == "bound")
  for _, udp in ipairs(sockets) do assert(udp.closed) end
end)
test("An optional known address is verified as a search candidate without disabling multicast", function()
  local api, _, sent = scanner_fixture({ { host = "192.168.1.170", wrong_token = true } })
  local found = network.scan(api, {}, nil, nil, "192.168.1.170")
  assert(#found == 1 and found[1].host == "192.168.1.170" and sent[1].host == "224.0.1.187")
  api, _, sent = scanner_fixture({})
  fails(function() network.scan(api, {}, nil, nil, "8.8.8.8") end)
  assert(#sent == 0)
end)
test("Discovery cancellation and socket failures close the search socket", function()
  for _, behavior in ipairs({ { bind_error = true }, { receive_error = true } }) do
    local api, sockets = scanner_fixture({}, behavior)
    fails(function() network.scan(api, {}) end)
    assert(sockets[1].closed)
  end
  local api, sockets, sent = scanner_fixture({ { host = "192.168.1.170" } })
  assert(#network.scan(api, {}, function() return false end) == 0 and #sent == 0 and sockets[1].closed)
  api, sockets, sent = scanner_fixture({ { host = "192.168.1.170" } })
  assert(#network.scan(api, { cancelled = true }) == 0 and #sent == 0 and sockets[1].closed)
end)
test("Observed state fixture keeps humidity and unscaled energy", function()
  local summary = ac.summary(observed)
  assert(summary.temperature == 25 and summary.desired == 24 and summary.unit == "C")
  assert(summary.humidity == 63 and summary.power == false and summary.mode == "Auto")
  assert(summary.dustRaw == 5 and summary.cleanLevelRaw == 1)
  assert(summary.energyCounterRaw == "275852400")
  assert(summary.acMode == "auto" and #summary.supportedModes == 7 and summary.fanMode == "auto")
  assert(summary.minimum == 18 and summary.maximum == 30 and summary.step == 1)
  assert(summary.windfree == false and summary.autoclean == false and summary.sleepRaw == "0")
  assert(summary.purify == false and summary.autocleanProgress == 1 and summary.autocleanStopRaw == "Idle")
  assert(summary.pm10 == 5 and summary.pm25 == 5 and summary.pm1 == 5 and summary.gasLevel == 1)
  assert(summary.airQualityConcern == "good" and summary.ai == false and summary.aiAvailable)
end)
local function state_with_mode(raw)
  local batch = cbor.decode(cbor.encode(observed))
  ac.resources(batch)["/mode/vs/0"][P .. "modes"] = { raw }
  return ac.summary(batch)
end
test("FAC AI command uses the verified comfort option and never sends Gear", function()
  local state = state_with_mode("Gear")
  assert(state.acMode == nil and state.purify == nil)
  local plan = ac.plan({ kind = "mode", value = "aIComfort" }, state_with_mode("Auto"))
  assert(plan.path == "/mode/vs/0" and plan.body[P .. "options"][1] == "ComfortAICooling_On" and plan.body[P .. "modes"] == nil)
  state.supportedModes = { "auto", "cool" }
  fails(function() ac.plan({ kind = "mode", value = "aIComfort" }, state) end)
end)
local function ai_state(raw)
  local batch = cbor.decode(cbor.encode(observed))
  local mode = ac.resources(batch)["/mode/vs/0"]
  mode[P .. "modes"] = { raw }
  mode[P .. "options"] = { "AI_Enable", "ComfortAICooling_On", "ArtificialWorking_Ing",
    "Comode_NanoSleep", "Sleep_14", "Autoclean_On" }
  return ac.summary(batch)
end
test("AI remains selected while its underlying mode changes and manual controls are rejected", function()
  for _, raw in ipairs({ "Auto", "Cool", "Dry" }) do
    local state = ai_state(raw)
    assert(state.acMode == "aIComfort" and state.aiWorkingRaw == "Ing" and state.purify == false)
    assert(ac.plan({ kind = "mode", value = "aIComfort" }, state) == nil)
    for _, command in ipairs({ { kind = "setpoint", value = 23 }, { kind = "fan", value = "low" },
      { kind = "windfree", value = false }, { kind = "purify", value = true } }) do
      fails(function() ac.plan(command, state) end)
    end
  end
end)
test("Leaving AI changes only its enable option and the requested basic mode", function()
  for _, value in ipairs({ "auto", "cool", "dry", "wind" }) do
    local state = ai_state("Cool")
    local plan = ac.plan({ kind = "mode", value = value }, state)
    assert(plan.path == "/mode/vs/0" and plan.body[P .. "options"][1] == "ComfortAICooling_Off")
    assert(#plan.body[P .. "options"] == 1 and #plan.body[P .. "modes"] == 1)
    assert(not ac.matches({ kind = "mode", value = value }, state))
    assert(plan.body[P .. "power"] == nil and state.sleepRaw == "14" and state.autoclean)
  end
end)
test("Purification switch changes only the cleaning variant of Cool and Dry", function()
  for _, pair in ipairs({ { "Cool", "CoolClean" }, { "Dry", "DryClean" } }) do
    for _, enabled in ipairs({ false, true }) do
      local state = state_with_mode(enabled and pair[1] or pair[2])
      local plan = ac.plan({ kind = "purify", value = enabled }, state)
      assert(plan.path == "/mode/vs/0" and plan.body[P .. "modes"][1] == (enabled and pair[2] or pair[1]))
      assert(plan.body[P .. "options"] == nil and plan.body[P .. "power"] == nil)
      assert(state.purify == not enabled)
    end
  end
  local state = state_with_mode("Cool")
  state.supportedModes = { "cool" }
  fails(function() ac.plan({ kind = "purify", value = true }, state) end)
end)
test("Standalone purification and Smart Comfort do not turn on the optional purification switch", function()
  for _, raw in ipairs({ "Auto", "Wind" }) do
    local state = state_with_mode(raw)
    assert(state.purify == false and ac.plan({ kind = "purify", value = false }, state) == nil)
    fails(function() ac.plan({ kind = "purify", value = true }, state) end)
  end
end)
test("Changing Cool and Dry preserves an explicit purification selection", function()
  local state = state_with_mode("CoolClean")
  assert(ac.plan({ kind = "mode", value = "cool" }, state) == nil)
  assert(ac.plan({ kind = "mode", value = "dry" }, state).body[P .. "modes"][1] == "DryClean")
  state = state_with_mode("DryClean")
  assert(ac.plan({ kind = "mode", value = "cool" }, state).body[P .. "modes"][1] == "CoolClean")
  local running = state_with_mode("CoolClean")
  running.power = true
  local windfree = ac.plan({ kind = "windfree", value = true }, running)
  assert(windfree.body[P .. "options"][1] == "Comode_Nano")
end)
test("Air outlet switches preserve the other outlet and unrelated options", function()
  local batch = cbor.decode(cbor.encode(observed))
  local mode = ac.resources(batch)["/mode/vs/0"]
  mode[P .. "options"] = { "Blooming_1", "Autoclean_On" }
  local state = ac.summary(batch)
  assert(state.doorUpper and not state.doorLower)
  local plan = ac.plan({ kind = "doorLower", value = true }, state)
  assert(plan.body[P .. "options"][1] == "Blooming_3" and #plan.body[P .. "options"] == 1)
  assert(plan.body[P .. "modes"] == nil and plan.body[P .. "power"] == nil)
  assert(ac.plan({ kind = "doorUpper", value = false }, state).body[P .. "options"][1] == "Blooming_0")
  assert(ac.plan({ kind = "doorUpper", value = true }, state) == nil)
  fails(function() ac.plan({ kind = "doorLower", value = true }, { bloomingRaw = "invalid" }) end)
end)
test("Autoclean setting is independent of idle progress and missing is not Off", function()
  local batch = cbor.decode(cbor.encode(observed))
  local mode = ac.resources(batch)["/mode/vs/0"]
  mode[P .. "options"] = { "Autoclean_On", "AutocleanProgress_1", "StopAutoClean_Idle" }
  local state = ac.summary(batch)
  assert(state.autoclean == true and state.autocleanProgress == 1 and state.autocleanStopRaw == "Idle")
  assert(ac.plan({ kind = "autoclean", value = true }, state) == nil)
  mode[P .. "options"] = { "AutocleanProgress_1", "StopAutoClean_Idle" }
  assert(ac.summary(batch).autoclean == nil)
end)
test("Cleaning panel state is independent of operating outlet selection and missing is not closed", function()
  local batch = cbor.decode(cbor.encode(observed))
  local mode = ac.resources(batch)["/mode/vs/0"]
  for _, pair in ipairs({ { "Close", "closed" }, { "Open", "open" } }) do
    mode[P .. "options"] = { "Panel_" .. pair[1], "Blooming_1" }
    local state = ac.summary(batch)
    assert(state.panel == pair[2] and state.panelRaw == pair[1] and state.doorUpper and not state.doorLower)
  end
  mode[P .. "options"] = { "Panel_Unexpected", "Blooming_3" }
  assert(ac.summary(batch).panel == nil and ac.summary(batch).doorLower == true)
  mode[P .. "options"] = { "Blooming_3" }
  assert(ac.summary(batch).panel == nil)
end)
test("Cleaning panel commands require observed power off and send one option without changing power or outlets", function()
  local state = ac.summary(observed)
  assert(state.panel == "closed" and state.power == false)
  local plan = ac.plan({ kind = "panel", value = "open" }, state)
  assert(plan.path == "/mode/vs/0" and #plan.body[P .. "options"] == 1 and plan.body[P .. "options"][1] == "Panel_Open")
  for key in pairs(plan.body) do assert(key == P .. "options") end
  assert(ac.plan({ kind = "panel", value = "closed" }, state) == nil)
  state.panel, state.panelRaw = "open", "Open"
  assert(ac.plan({ kind = "panel", value = "closed" }, state).body[P .. "options"][1] == "Panel_Close")
  for _, command in ipairs({ "open", "closed" }) do
    state.power = true; fails(function() ac.plan({ kind = "panel", value = command }, state) end)
    state.power = nil; fails(function() ac.plan({ kind = "panel", value = command }, state) end)
  end
  state.power, state.panel = false, nil
  fails(function() ac.plan({ kind = "panel", value = "open" }, state) end)
  for _, value in ipairs({ true, false, "opening", "close", "unexpected" }) do
    fails(function() ac.validate({ kind = "panel", value = value }) end)
  end
end)
test("Native reservation values remain readable but legacy timer commands cannot reach native writes", function()
  local batch = cbor.decode(cbor.encode(observed))
  for _, entry in ipairs(batch) do
    if entry.href == "/mode/vs/0" then entry.rep[P .. "options"] = { "OnTimer_0", "OffTimer_4" } end
  end
  local state = ac.summary(batch)
  assert(state.onTimer == 0 and state.offTimer == 4)
  for _, kind in ipairs({ "onTimer", "offTimer" }) do
    for _, value in ipairs({ 0, 2, 4, -1, 0.5, 49, math.huge, "2" }) do
      fails(function() ac.plan({ kind = kind, value = value }, state) end)
    end
  end
  fails(function() ac.plan({ kind = "offTimer", value = 0 }, {}) end)
  for _, entry in ipairs(batch) do if entry.href == "/mode/vs/0" then entry.rep[P .. "options"] = {} end end
  assert(ac.summary(batch).offTimer == nil)
end)
test("Native timers accept positive half-hours only and rearm an identical setting with one option", function()
  local state = ac.summary(observed)
  state.onTimer, state.offTimer = 0, 0
  for kind, prefix in pairs({nativeOnTimer="OnTimer_", nativeOffTimer="OffTimer_"}) do
    for _, value in ipairs({1, 2, 4, 48, 1.0}) do
      local command = {kind=kind, value=value}
      local key = kind == "nativeOnTimer" and "onTimer" or "offTimer"
      state[key] = value
      assert(ac.matches(command, state))
      local plan = ac.plan(command, state)
      assert(plan and plan.path == "/mode/vs/0")
      assert(#plan.body[P .. "options"] == 1 and plan.body[P .. "options"][1] == prefix .. string.format("%d", value))
      local fields = 0; for _ in pairs(plan.body) do fields = fields + 1 end
      assert(fields == 1)
    end
    for _, value in ipairs({0, -1, 0.5, 49, math.huge, 0/0, "1", "none", false}) do
      fails(function() ac.plan({kind=kind, value=value}, state) end)
    end
    fails(function() ac.plan({kind=kind, value=1}, {}) end)
  end
end)
test("WindFree is available in Cool, Dry and purification, including their optional clean modes", function()
  local state = ac.summary(observed)
  state.power = true
  state.sleepRaw, state.windfree, state.windfreeRaw = "0", false, "Off"
  for _, mode in ipairs({ "cool", "dry", "wind", "coolClean", "dryClean" }) do
    state.acMode = mode
    assert(ac.plan({ kind = "windfree", value = true }, state).body[P .. "options"][1] == "Comode_Nano")
  end
  state.acMode = "auto"
  fails(function() ac.plan({ kind = "windfree", value = true }, state) end)
  state.acMode, state.ai = "aIComfort", true
  fails(function() ac.plan({ kind = "windfree", value = true }, state) end)
end)
test("Lighting, voice selection and display-off use the compared FAC values without touching power", function()
  local state = ac.summary(observed)
  assert(state.lighting == "off" and state.voice == "melody" and state.displayOff == false)
  for _, pair in ipairs({ { "lighting", "low", "Light_Small" }, { "lighting", "medium", "Light_On" },
    { "lighting", "high", "Light_Huge" }, { "voice", "low", "Volume_33" }, { "voice", "medium", "Volume_66" },
    { "voice", "high", "Volume_100" }, { "voice", "mute", "Volume_Mute" }, { "displayOff", true, "Display_On" } }) do
    local plan = ac.plan({ kind = pair[1], value = pair[2] }, state)
    assert(plan.path == "/mode/vs/0" and #plan.body[P .. "options"] == 1 and plan.body[P .. "options"][1] == pair[3])
    assert(plan.body[P .. "modes"] == nil and plan.body[P .. "power"] == nil)
  end
  assert(ac.plan({ kind = "lighting", value = "off" }, state) == nil)
  fails(function() ac.plan({ kind = "voice", value = "arbitrary" }, state) end)
  fails(function() ac.plan({ kind = "displayOff", value = true }, {}) end)
end)
test("Speed and Quiet share the preset slot and cannot cancel unrelated presets or active sleep", function()
  local state = ac.summary(observed)
  state.power = true
  state.acMode = "cool"
  assert(not state.speed and not state.quiet)
  assert(ac.plan({ kind = "speed", value = true }, state).body[P .. "options"][1] == "Comode_Speed")
  assert(ac.plan({ kind = "quiet", value = true }, state).body[P .. "options"][1] == "Comode_Quiet")
  assert(ac.plan({ kind = "quiet", value = false }, state) == nil)
  state.speed, state.windfreeRaw = true, "Speed"
  assert(ac.plan({ kind = "speed", value = false }, state).body[P .. "options"][1] == "Comode_Off")
  state.speed, state.windfreeRaw = false, "NanoSleep"
  assert(ac.plan({ kind = "speed", value = false }, state) == nil)
  fails(function() ac.plan({ kind = "speed", value = true }, state) end)
  state.windfreeRaw, state.acMode = "Off", "wind"
  fails(function() ac.plan({ kind = "quiet", value = true }, state) end)
  state.acMode, state.ai = "aIComfort", true
  fails(function() ac.plan({ kind = "speed", value = true }, state) end)
end)
test("Observed resources produce exact scoped command payloads", function()
  local state = ac.summary(observed)
  for _, case in ipairs({
    { { kind = "power", value = true }, "/power/vs/0", P .. "power", "On" },
    { { kind = "setpoint", value = 23 }, "/temperature/desired/0", "temperature", 23 },
    { { kind = "mode", value = "cool" }, "/mode/vs/0", P .. "modes", "Cool" },
    { { kind = "fan", value = "high" }, "/airflow/vs/0", P .. "speedLevel", "3" },
    { { kind = "autoclean", value = true }, "/mode/vs/0", P .. "options", "Autoclean_On" },
  }) do
    local plan = ac.plan(case[1], state)
    assert(plan.path == case[2])
    local value = plan.body[case[3]]
    assert((type(value) == "table" and value[1] or value) == case[4])
    local count = 0; for _ in pairs(plan.body) do count = count + 1 end
    assert(count == 1)
  end
  assert(ac.plan({ kind = "power", value = false }, state) == nil)
end)
test("Unsupported modes, missing resources and invalid setpoints cannot become POSTs", function()
  local state = ac.summary(observed)
  for _, command in ipairs({ { kind = "setpoint", value = 17 }, { kind = "setpoint", value = 31 },
    { kind = "setpoint", value = 24.5 }, { kind = "setpoint", value = "24" }, { kind = "setpoint", value = 0 / 0 },
    { kind = "mode", value = "heat" }, { kind = "mode", value = "Gear" }, { kind = "fan", value = "999" },
    { kind = "power", value = "on" }, { kind = "delete", value = true }, { kind = "windfree", value = true } }) do
    fails(function() ac.plan(command, state) end)
  end
  state.supportedModes = { "auto" }
  fails(function() ac.plan({ kind = "mode", value = "cool" }, state) end)
  state.powerResourceAvailable = false
  fails(function() ac.plan({ kind = "power", value = true }, state) end)
end)
test("WindFree preserves a running sleep timer and other presets when disabling", function()
  local state = ac.summary(observed)
  state.power = true
  state.acMode, state.sleepRaw = "cool", "4"
  local plan = ac.plan({ kind = "windfree", value = true }, state)
  assert(plan.body[P .. "options"][1] == "Comode_NanoSleep" and plan.body[P .. "options"][2] == "Sleep_4")
  state.windfreeRaw, state.windfree = "NanoSleep", true
  plan = ac.plan({ kind = "windfree", value = false }, state)
  assert(plan.body[P .. "options"][1] == "Comode_Sleep" and plan.body[P .. "options"][2] == "Sleep_4")
  state.windfreeRaw, state.windfree = "Quiet", false
  assert(ac.plan({ kind = "windfree", value = false }, state) == nil)
end)
test("Menu guards reject WindFree for off, unknown power, AI and unsupported modes in both directions", function()
  local state = ac.summary(observed)
  state.acMode, state.power = "cool", true
  assert(ac.available("windfree", state))
  for _, patch in ipairs({ {power=false}, {power="unknown"}, {ai=true}, {acMode="auto"}, {acMode="unknown"} }) do
    local changed = {}; for key, value in pairs(state) do changed[key] = value end
    for key, value in pairs(patch) do changed[key] = value end
    assert(not ac.available("windfree", changed))
    for _, value in ipairs({true, false}) do fails(function() ac.plan({kind="windfree", value=value}, changed) end) end
  end
  state.power = nil
  assert(not ac.available("windfree", state))
  fails(function() ac.plan({kind="windfree", value=true}, state) end)
end)
test("Grouped menus use one outlet command, preserve WindFree on normal and report sleep distinctly", function()
  local state = ac.summary(observed)
  state.acMode, state.power = "cool", true
  for name, bits in pairs({closed=0, upper=1, lower=2, both=3}) do
    state.bloomingRaw = tostring((bits + 1) % 4)
    local plan = ac.plan({kind="outlet", value=name}, state)
    assert(plan.path == "/mode/vs/0" and #plan.body[P .. "options"] == 1)
    assert(plan.body[P .. "options"][1] == "Blooming_" .. bits and plan.body[P .. "power"] == nil)
    state.bloomingRaw = tostring(bits)
    assert(ac.matches({kind="outlet", value=name}, state) and ac.plan({kind="outlet", value=name}, state) == nil)
    assert(ac.menu_state(state).outlet == name)
  end
  state.windfreeRaw, state.windfree = "Nano", true
  assert(ac.plan({kind="preset", value="normal"}, state) == nil)
  for _, name in ipairs({"speed", "quiet"}) do
    local plan = ac.plan({kind="preset", value=name}, state)
    assert(plan.body[P .. "options"][1] == (name == "speed" and "Comode_Speed" or "Comode_Quiet"))
  end
  state.windfreeRaw, state.speed, state.windfree = "Speed", true, false
  assert(ac.plan({kind="preset", value="normal"}, state).body[P .. "options"][1] == "Comode_Off")
  assert(ac.plan({kind="windfree", value=true}, state).body[P .. "options"][1] == "Comode_Nano")
  state.windfreeRaw, state.sleepRaw = "NanoSleep", "4"
  local menu = ac.menu_state(state)
  assert(menu.preset == "sleep" and menu.presetEnabled == "disabled" and menu.windfreeEnabled == "enabled")
  fails(function() ac.plan({kind="preset", value="speed"}, state) end)
  fails(function() ac.validate({kind="outlet", value="invalid"}) end)
  fails(function() ac.validate({kind="preset", value="sleep"}) end)
end)
test("False, zero and missing remain distinct", function()
  local value = ac.summary({ { href = "/power/0", rep = { value = false } },
    { href = "/temperature/current/0", rep = { temperature = 0, units = "C" } },
    { href = "/humidity/vs/0", rep = { [P .. "humidity"] = "0" } } })
  assert(value.power == false and value.temperature == 0 and value.humidity == nil and value.desired == nil)
end)
test("Operating card maps modes without clean suffixes and keeps temperature units and missing values", function()
  for raw, expected in pairs({Auto="auto", Cool="cool", Dry="dry", Wind="wind", CoolClean="cool", DryClean="dry"}) do
    local _, _, _, operation = ac.menu_state(state_with_mode(raw))
    assert(operation.mode == expected and operation.setpoint.value == 24 and operation.setpoint.unit == "C")
    assert(operation.fan == "auto")
  end
  local _, _, _, operation = ac.menu_state(ai_state("Cool"))
  assert(operation.mode == "aIComfort")
  local _, _, _, missing = ac.menu_state({})
  assert(next(missing) == nil)
end)
test("Humidity bounds and power sentinel are not measurements", function()
  local value = ac.summary({ { href = "/power/0", rep = { value = false } },
    { href = "/humidity/vs/0", rep = { [P .. "fivepercentHumidity"] = "101" } },
    { href = "/energy/consumption/vs/0", rep = { [P .. "instantaneousPower"] = "65278" } } })
  assert(value.humidity == nil and value.instantaneousPowerRaw == nil)
end)
test("Sensor text is gated by AirMonitoring, preserves valid zero and clears missing values", function()
  local state = {power=true, monitoringRaw="On", temperature=0, unit="C", humidity=0,
    pm10=0, pm25=0, pm1=0, gasLevel=1, airQualityConcern="good"}
  local shown = ac.sensor_state(state)
  assert(shown.monitoring == "on" and shown.temperature == "0.0 °C" and shown.humidity == "0 %")
  assert(shown.dustLevel == "0 μg/m³" and shown.fineDustLevel == "0 μg/m³" and shown.veryFineDustLevel == "0 μg/m³")
  assert(shown.gas == "1단계" and shown.airQuality == "좋음")
  for _, token in ipairs({"Off", "Unexpected", false}) do
    state.monitoringRaw = token or nil
    shown = ac.sensor_state(state)
    assert(shown.monitoring == (token == "Off" and "off" or "unknown"))
    for key, value in pairs(shown) do if key ~= "monitoring" then assert(value == "-") end end
  end
  -- 켜짐이어도 읽지 못한 센서나 확인하지 않은 청정도 등급을 이전 수치/좋음으로 대체하지 않습니다.
  shown = ac.sensor_state({monitoringRaw="On", temperature=25, airQualityConcern="unknown"})
  assert(shown.monitoring == "on")
  for key, value in pairs(shown) do if key ~= "monitoring" then assert(value == "-") end end
  shown = ac.sensor_state({monitoringRaw="On", temperature=72.5, unit="F"})
  assert(shown.temperature == "72.5 °F")
end)

-- UDP 응답 포트와 TLS 스트림을 모사해 전체 경로의 종료·신원 검증을 검사합니다.
local function transport(handshake_failure, secure_identity, behavior)
  behavior = behavior or {}
  local raw, tls = stream(), stream()
  local context, handshakes, fail_next_send = {}, 0, false
  local udp_sockets, requests, posts, tls_config = {}, {}, {}, nil
  local batch = cbor.decode(cbor.encode(observed))
  local api = { gettime = now, tcp = function() return raw end, sleep = function() end }
  raw.connect = function() return 1 end
  api.udp = function()
    local udp = stream(); udp_sockets[#udp_sockets + 1] = udp
    udp.sendto = function(self, packet)
      local token = packet:sub(5, 8)
      local options = coap.parse_options(packet:sub(9))
      local path = ""
      for _, option in ipairs(options) do if option.number == 11 then path = path .. "/" .. option.value end end
      local value = path == "/oic/d" and { di = "appliance-a", rt = { "oic.d.airconditioner" } }
        or { { links = { { href = "/oic/sec/doxm", p = { sec = true, port = 1, ["x.org.iotivity.tls"] = 43834 } } } } }
      self.reply = "\100\69" .. packet:sub(3, 4) .. token .. "\255" .. encode(value)
      return #packet
    end
    udp.receivefrom = function(self) return self.reply, "192.168.1.170", 39954 end
    return udp
  end
  tls.dohandshake = function()
    handshakes = handshakes + 1
    if handshakes <= (behavior.role_collisions or 0) then
      context.tls_role_collision = true
      return nil, "closed"
    end
    if handshake_failure then return nil, "test handshake failure" end
    return 1
  end
  tls.send = function(self, data)
    if fail_next_send then fail_next_send = false; return nil, "closed" end
    local code, token, body = coap.read_frame(stream(data), now, 1)
    if code == 1 then
      local options = coap.parse_options(body)
      local path = ""
      for _, option in ipairs(options) do if option.number == 11 then path = path .. "/" .. option.value end end
      requests[#requests + 1] = path
      if #posts > 0 and behavior.readback_failure then return #data end
      local value = path == "/oic/d" and { di = secure_identity or "appliance-a" } or batch
      self.data = self.data .. frame(69, token, "\255" .. cbor.encode(value))
    elseif code == 2 then
      local options, payload = coap.parse_options(body)
      local path = ""
      for _, option in ipairs(options) do if option.number == 11 then path = path .. "/" .. option.value end end
      local change = cbor.decode(payload)
      posts[#posts + 1] = { path = path, body = change }
      if behavior.drop_response then return #data end
      local response_code = behavior.reject and 131 or 68
      if not behavior.reject and not behavior.ignore_change then
        local resources = ac.resources(batch)
        for key, value in pairs(change) do
          if key == P .. "options" then
            local target = resources[path][key]
            for _, token in ipairs(value) do
              local prefix = token:match("^(%w+)_")
              for index, old in ipairs(target) do
                if old:match("^(%w+)_") == prefix then target[index] = token end
              end
            end
          else resources[path][key] = value end
        end
        if path == "/power/vs/0" then resources["/power/0"].value = change[P .. "power"] == "On" end
      end
      self.data = self.data .. frame(response_code, token)
    else assert(code == 225) end
    return #data
  end
  local ssl_api = { wrap = function(_, config) tls_config = config; return tls end }
  local config = { expires_at = os.time() + 60, ca_pem = "test-root", client_certificate = "test-certificate", client_key = "test-key" }
  local function read() return network.read(api, ssl_api, config, "192.168.1.170", "appliance-a", context) end
  local function control(command, identity)
    local expected = identity
    if identity == nil then expected = "appliance-a" elseif identity == false then expected = nil end
    return network.control(api, ssl_api, config, "192.168.1.170", expected, context, nil, command)
  end
  return { read = read, control = control, raw = raw, tls = tls, udp = udp_sockets, requests = requests, posts = posts, context = context,
    config = function() return tls_config end, handshakes = function() return handshakes end,
    break_connection = function() fail_next_send = true end }
end
test("TLS handshake failure closes every owned socket", function()
  local t = transport(true)
  fails(t.read)
  assert(t.raw.closed and t.tls.closed and t.udp[1].closed and t.udp[2].closed)
  assert(#t.requests == 0 and t.context.stream == nil)
  assert(t.handshakes() == 1, "ordinary TLS failures must not retry")
end)
test("Observed TLS role collisions retry before CoAP and remain bounded", function()
  local t = transport(false, nil, { role_collisions = 2 })
  assert(t.read().temperature == 25 and t.handshakes() == 3 and #t.requests == 2)
  t = transport(false, nil, { role_collisions = 100 })
  fails(t.read)
  assert(t.handshakes() == 6 and #t.requests == 0 and #t.posts == 0 and t.raw.closed and t.tls.closed)
end)
test("TLS role retry never repeats a setting after an acknowledgement is lost", function()
  local t = transport(false, nil, { role_collisions = 2, drop_response = true })
  fails(function() t.control({ kind = "setpoint", value = 23 }) end)
  assert(t.handshakes() == 3 and #t.posts == 1 and t.context.write_attempted)
end)
test("Full read verifies CA and identity before state GET", function()
  local t = transport(false)
  local result = table.pack(t.read())
  assert(result.n == 2, "PC read adapter expects exactly state and identity")
  local value, identity = result[1], result[2]
  assert(identity == "appliance-a" and value.temperature == 25)
  assert(t.requests[1] == "/oic/d" and t.requests[2] == "/device/0" and #t.requests == 2)
  assert(t.config().verify == "peer" and t.config().cafile == "test-root" and t.config().certificates[1].key == "test-key")
  assert(t.raw.closed and t.tls.closed)
end)
test("Authenticated hub connection is reused and explicit close releases it", function()
  local t = transport(false)
  t.context.keep_connection = true
  assert(t.read().temperature == 25 and not t.raw.closed and not t.tls.closed)
  assert(t.read().temperature == 25 and t.handshakes() == 1 and t.context.reused_connection and #t.requests == 4)
  assert(#t.udp == 2, "an authenticated live connection must not depend on another UDP discovery")
  network.close(t.context)
  assert(t.raw.closed and t.tls.closed and t.context.connection == nil)
end)
test("A stale cached connection reconnects before GET and before a setting", function()
  for _, control in ipairs({ false, true }) do
    local t = transport(false)
    t.context.keep_connection = true
    t.read(); t.break_connection()
    if control then
      local state, _, outcome = t.control({ kind = "setpoint", value = 23 })
      assert(state.desired == 23 and outcome == "confirmed" and #t.posts == 1)
    else
      local result = table.pack(t.read())
      assert(result.n == 2 and result[1].temperature == 25 and #t.posts == 0)
    end
    assert(t.handshakes() == 2)
    network.close(t.context)
  end
end)
test("Cached connection does not repeat a POST whose acknowledgement was lost", function()
  local t = transport(false, nil, { drop_response = true })
  t.context.keep_connection = true
  t.read()
  fails(function() t.control({ kind = "setpoint", value = 23 }) end)
  assert(t.handshakes() == 1 and #t.posts == 1 and t.context.connection == nil)
end)
test("Secure identity mismatch prevents state GET", function()
  local t = transport(false, "wrong-appliance")
  fails(t.read)
  assert(#t.requests == 1 and t.raw.closed and t.tls.closed)
end)
test("Control verifies identity, sends one POST and returns observed state", function()
  for _, command in ipairs({ { kind = "power", value = true }, { kind = "setpoint", value = 23 },
    { kind = "mode", value = "cool" }, { kind = "fan", value = "high" }, { kind = "autoclean", value = true } }) do
    local t = transport(false)
    local state, identity, outcome = t.control(command)
    assert(identity == "appliance-a" and outcome == "confirmed" and ac.matches(command, state))
    assert(#t.posts == 1 and #t.requests == 3 and t.requests[1] == "/oic/d")
    assert(t.raw.closed and t.tls.closed)
  end
end)
test("No-op and range rejection send no POST", function()
  local state = ac.summary(observed)
  for kind, value in pairs({power=false, mode=state.acMode, fan=state.fanMode, setpoint=state.desired,
    lighting=state.lighting, voice=state.voice, outlet="closed", panel=state.panel}) do
    local t = transport(false)
    local _, _, outcome = t.control({ kind = kind, value = value })
    assert(outcome == "unchanged" and #t.posts == 0 and #t.requests == 2)
  end
  local t = transport(false)
  fails(function() t.control({ kind = "setpoint", value = 31 }) end)
  assert(#t.posts == 0 and t.context.verified_state.desired == 24 and t.raw.closed)
end)
test("Wrong or missing bound identity prevents every POST", function()
  for _, identity in ipairs({ "wrong-appliance", false }) do
    local t = transport(false)
    fails(function() t.control({ kind = "power", value = true }, identity) end)
    assert(#t.posts == 0)
  end
  local t = transport(false, "wrong-secure-appliance")
  fails(function() t.control({ kind = "power", value = true }) end)
  assert(#t.posts == 0 and #t.requests == 1)
end)
test("Acknowledgement alone does not confirm a setting", function()
  local t = transport(false, nil, { ignore_change = true })
  local state, _, outcome = t.control({ kind = "setpoint", value = 23 })
  assert(outcome == "unconfirmed" and state.desired == 24 and #t.posts == 1 and #t.requests == 5)
end)
test("Native half-hour settings reach the appliance once and confirmation comes from GET", function()
  for _, kind in ipairs({"nativeOnTimer", "nativeOffTimer"}) do
    local t = transport(false)
    local state, _, outcome = t.control({kind=kind, value=1})
    local key = kind == "nativeOnTimer" and "onTimer" or "offTimer"
    local token = kind == "nativeOnTimer" and "OnTimer_1" or "OffTimer_1"
    assert(outcome == "confirmed" and state[key] == 1 and state.power == false)
    assert(#t.posts == 1 and #t.requests == 3 and t.posts[1].path == "/mode/vs/0")
    assert(#t.posts[1].body[P .. "options"] == 1 and t.posts[1].body[P .. "options"][1] == token)
    -- 같은 시간을 다시 선택해도 새 예약 요청은 생략하지 않습니다.
    local _, _, renewed = t.control({kind=kind, value=1})
    assert(#t.posts == 2 and renewed == "accepted")
    t = transport(false, nil, {ignore_change=true})
    state, _, outcome = t.control({kind=kind, value=1})
    assert(outcome == "unconfirmed" and state[key] == 0 and #t.posts == 1)
    for _, behavior in ipairs({{drop_response=true}, {reject=true}, {readback_failure=true}}) do
      t = transport(false, nil, behavior)
      fails(function() t.control({kind=kind, value=1}) end)
      assert(#t.posts == 1)
    end
    t = transport(false)
    fails(function() t.control({kind=kind, value=0}) end)
    assert(#t.posts == 0 and #t.requests == 0)
    t = transport(false, "wrong-appliance")
    fails(function() t.control({kind=kind, value=1}) end)
    assert(#t.posts == 0)
  end
end)
test("POST rejection, response loss and readback failure never retransmit", function()
  for _, behavior in ipairs({ { reject = true }, { drop_response = true }, { readback_failure = true } }) do
    local t = transport(false, nil, behavior)
    fails(function() t.control({ kind = "power", value = true }) end)
    assert(#t.posts == 1 and t.context.write_attempted and t.raw.closed and t.tls.closed)
    assert(t.context.write_rejected == (behavior.reject == true))
  end
end)

-- 실제 소켓 대신 기록 가능한 양방향 스트림으로 허브 내부 전달 순서와 종료를 검사합니다.
local function bridge_fixture(behavior)
  behavior = behavior or {}
  local bridge = require "tls_bridge"
  local tasks, order, created = {}, {}, {}
  local context = {}
  local function tls_record(kind, body)
    return string.char(kind, 3, 3) .. string.pack(">I2", #body) .. body
  end
  local hello = tls_record(22, "\1\0\0\1a")
  local response = tls_record(22, "\2\0\0\1b") .. tls_record(23, "encrypted application data")
  if behavior.collision then response = tls_record(22, "\1\0\0\1b") end
  local function exact_stream(data)
    local value = stream(data)
    value.sent = ""
    value.receive = function(self, count)
      if #self.data < count then return nil, "closed", self.data end
      local part = self.data:sub(1, count)
      self.data = self.data:sub(count + 1)
      return part
    end
    value.send = function(self, data, at)
      self.sent = self.sent .. data:sub(at or 1)
      return #data
    end
    return value
  end
  local accepted = exact_stream(behavior.oversized and tls_record(22, "\1" .. string.rep("a", 4096)) or hello)
  accepted.getpeername = function() return behavior.foreign and "192.168.1.200" or "192.168.1.30", 41000 end
  local receive = accepted.receive
  accepted.receive = function(self, count)
    local value, err, partial = receive(self, count)
    if value and count == 5 and #self.data == 0 then order[#order + 1] = "hello-ready" end
    return value, err, partial
  end
  local api = { tcp = function()
    local value = exact_stream("")
    created[#created + 1] = value
    if #created == 1 then
      value.connect = function(_, host, port) assert(host == "192.168.1.30" and port == 42000); return 1 end
    elseif #created == 2 then
      value.bind = function(_, host, port) assert(host == "0.0.0.0" and port == 0); return 1 end
      value.listen = function() return 1 end
      value.getsockname = function() return "0.0.0.0", 42000 end
      value.accept = function() return accepted end
    else
      value.data = response
      value.connect = function(_, host, port)
        assert(host == "192.168.1.170" and port == 43834)
        order[#order + 1] = "backend-connect"
        return 1
      end
    end
    return value
  end }
  local wrapped = bridge.socket_api(api, function(fn) tasks[#tasks + 1] = fn end, "192.168.1.30", context)
  local raw = wrapped.tcp()
  context.raw = raw
  assert(raw:connect("192.168.1.170", 43834))
  return { tasks = tasks, order = order, created = created, accepted = accepted, context = context,
    hello = hello, response = response, raw = raw }
end
test("Hub relay receives ClientHello before backend connect and preserves ciphertext", function()
  local t = bridge_fixture()
  assert(#t.created == 2, "backend must not connect before ClientHello")
  t.tasks[1]()
  assert(t.order[1] == "hello-ready" and t.order[2] == "backend-connect")
  assert(t.created[3].sent == t.hello and t.accepted.sent == t.response)
  assert(t.created[2].closed and t.created[3].closed and t.accepted.closed and t.context.relay == nil)
  t.tasks[2]()
  network.close(t.context)
  assert(t.raw.closed)
end)
test("Hub relay detects peer ClientHello without forwarding it to TLS client", function()
  local t = bridge_fixture({ collision = true })
  t.tasks[1]()
  assert(t.context.tls_role_collision and t.accepted.sent == "")
  assert(t.accepted.closed and t.created[3].closed)
end)
test("Hub relay rejects foreign peers and oversized ClientHello before backend connect", function()
  for _, behavior in ipairs({ { foreign = true }, { oversized = true } }) do
    local t = bridge_fixture(behavior)
    t.tasks[1]()
    assert(#t.created == 2 and t.accepted.closed and t.context.relay == nil)
  end
end)
test("Cancellation closes relay listener and prevents deferred backend connection", function()
  local t = bridge_fixture()
  t.context.cancelled = true
  network.close(t.context)
  t.tasks[1]()
  assert(#t.created == 2 and t.created[2].closed and t.raw.closed and t.context.relay == nil)
end)

-- 영구 저장과 콜백 시계만 모사해 실제 전원을 켜지 않고 예약 만료·취소·재시작을 검사합니다.
local function reservation_fixture(saved)
  local previous_time, clock = os.time, 1000000
  os.time = function() return clock end
  local fields, timers, commands, changes = { ac_reservations = saved }, {}, {}, 0
  package.loaded["log"] = { info = function() end }
  package.loaded["reservations"] = nil
  local module = require "reservations"
  local device = { get_field = function(_, name) return fields[name] end,
    set_field = function(_, name, value, options)
      if name == "ac_reservations" then assert(options.persist == true) end
      fields[name] = value
    end }
  local driver = { call_with_delay = function(_, delay, callback)
    local timer = { delay = delay, callback = callback }; timers[#timers + 1] = timer; return timer
  end, cancel_timer = function(_, timer) timer.cancelled = true end }
  local function changed() changes = changes + 1 end
  local function command(_, _, value) commands[#commands + 1] = value; return true end
  return { module = module, device = device, driver = driver, fields = fields, timers = timers, commands = commands,
    start = function() module.start(driver, device, command, changed) end,
    set = function(kind, units) module.set(driver, device, kind, units) end,
    advance = function(n) clock = clock + n end, changes = function() return changes end,
    finish = function() os.time = previous_time end }
end
test("Local reservation setting and cancellation never issue a power command", function()
  local t = reservation_fixture(); t.start()
  t.set("onTimer", 2)
  assert(t.timers[1].delay == 3600 and t.module.snapshot(t.device).onTimer == 2 and #t.commands == 0)
  for _, value in ipairs({ -1, 0.5, 49, math.huge, 0 / 0, "2" }) do fails(function() t.set("offTimer", value) end) end
  fails(function() t.set("offTimer", 2) end)
  assert(t.module.snapshot(t.device).onTimer == 2 and #t.timers == 1)
  t.set("onTimer", 0); t.advance(4000); t.timers[1].callback()
  assert(t.timers[1].cancelled and #t.commands == 0 and t.module.snapshot(t.device).onTimer == 0 and t.changes() == 2)
  t.finish()
end)
test("Local reservation expiry dispatches each power action once and consumes it first", function()
  for _, kind in ipairs({ "onTimer", "offTimer" }) do
    local t = reservation_fixture(); t.start(); t.set(kind, 1); t.advance(1800)
    t.timers[1].callback(); t.timers[1].callback()
    assert(#t.commands == 1 and t.commands[1].kind == "power" and t.commands[1].value == (kind == "onTimer"))
    assert(t.module.snapshot(t.device)[kind] == 0 and t.fields.ac_reservations[kind] == nil)
    t.finish()
  end
end)
test("Restart restores only future reservations and invalidates old callbacks", function()
  local t = reservation_fixture(); t.start(); t.set("onTimer", 2); t.advance(1800); t.start()
  assert(t.timers[1].cancelled and t.timers[2].delay == 1800)
  t.advance(1800); t.timers[1].callback(); assert(#t.commands == 0)
  t.timers[2].callback(); assert(#t.commands == 1)
  t.set("onTimer", 1); t.module.stop(t.driver, t.device); t.advance(2000); t.start()
  assert(t.module.snapshot(t.device).onTimer == 0 and #t.commands == 1)
  t.finish()
end)
test("Early callbacks rearm, remaining time rounds up and replacement invalidates earlier work", function()
  local t = reservation_fixture(); t.start(); t.set("offTimer", 2); t.advance(1900)
  assert(t.module.snapshot(t.device).offTimer == 1)
  t.timers[1].callback(); assert(#t.commands == 0 and t.timers[2].delay == 1700)
  t.set("offTimer", 3); t.advance(1700); t.timers[2].callback(); assert(#t.commands == 0)
  t.advance(3700); t.timers[3].callback(); assert(#t.commands == 1 and t.commands[1].value == false)
  t.finish()
end)

local function worker_fixture(read, control, scan)
  local tasks, fields, events = {}, { ocf_host = "192.168.1.170" }, {}
  local counters = { online = 0, offline = 0, schedules = 0, cancelled = 0, closed = 0, logs = {} }
  package.loaded["cosock"] = { spawn = function(fn) tasks[#tasks + 1] = fn end }
  local clock = 0
  counters.advance = function(seconds) clock = clock + seconds end
  package.loaded["cosock.socket"] = { gettime = function() return clock end,
    sleep = function(seconds) clock = clock + seconds; counters.slept = (counters.slept or 0) + seconds end }
  package.loaded["cosock.ssl"] = {}
  package.loaded["st.capabilities"] = capabilities()
  package.loaded["st.json"] = { encode = function() return "{}" end }
  package.loaded["log"] = { info = function(text) counters.logs[#counters.logs + 1] = text end,
    error = function(text) counters.logs[#counters.logs + 1] = text end }
  package.loaded["private_config"] = { host = "192.168.1.170" }
  package.loaded["network"] = { read = read, control = control, valid_host = network.valid_host,
    scan = scan or function() error("unexpected multicast scan") end,
    close = function() counters.closed = counters.closed + 1 end }
  package.loaded["worker"] = nil
  package.loaded["reservations"] = nil
  local worker = require "worker"
  local device = {
    -- 기존 프로필에 새 capability가 아직 도착하지 않은 상태를 기본 fixture로 둡니다.
    missing_capabilities = { ["instantcommon43059.samsungAcLocalComfort"] = true,
      ["instantcommon43059.samsungAcLocalDeviceSettings"] = true, ["instantcommon43059.samsungAcLocalCare"] = true,
      ["instantcommon43059.samsungAcLocalOperation"] = true, ["instantcommon43059.samsungAcLocalTemperature"] = true,
      ["instantcommon43059.samsungAcLocalAirFeatures"] = true, ["instantcommon43059.samsungAcLocalDisplay"] = true,
      ["instantcommon43059.samsungAcLocalPanel"] = true, ["instantcommon43059.samsungAcLocalOperating"] = true,
      ["instantcommon43059.samsungAcLocalNativeTimer"] = true, ["instantcommon43059.samsungAcLocalSensors"] = true },
    device_network_id = "samsung-ac-ocf:appliance-a", preferences = { enablePolling = false },
    profile = { components = { main = { id = "main" }, windfree = { id = "windfree" }, autoclean = { id = "autoclean" }, purify = { id = "purify" },
      doorupper = { id = "doorupper" }, doorlower = { id = "doorlower" }, panel = { id = "panel" }, speed = { id = "speed" }, quiet = { id = "quiet" }, displayoff = { id = "displayoff" } } },
    get_field = function(_, name) return fields[name] end,
    set_field = function(_, name, value) fields[name] = value end,
    emit_event = function(_, value)
      local event = { component = "main", capability = value.capability.ID, attribute = value.attribute.NAME, data = value.value, state_change = value.state_change }
      events[#events + 1] = event; captured_events[#captured_events + 1] = event; return true
    end,
    emit_component_event = function(_, component, value)
      local event = { component = component.id, capability = value.capability.ID, attribute = value.attribute.NAME, data = value.value, state_change = value.state_change }
      events[#events + 1] = event; captured_events[#captured_events + 1] = event; return true
    end,
    online = function() counters.online = counters.online + 1 end,
    offline = function() counters.offline = counters.offline + 1 end,
    supports_capability = function(self, capability) return not (self.missing_capabilities or {})[capability.ID] end,
  }
  local driver = {
    get_devices = function() return { device } end,
    call_on_schedule = function(_, interval, callback) counters.schedules = counters.schedules + 1; counters.interval = interval; return callback end,
    call_with_delay = function(_, delay, callback)
      counters.reservation_timers = counters.reservation_timers or {}
      local timer = { delay = delay, callback = callback }
      counters.reservation_timers[#counters.reservation_timers + 1] = timer
      return timer
    end,
    cancel_timer = function() counters.cancelled = counters.cancelled + 1 end,
  }
  return worker, device, driver, tasks, events, counters
end
test("Worker serializes in-flight refresh and defaults to one-shot", function()
  local worker, device, driver, tasks, events, counters
  local reads = 0
  worker, device, driver, tasks, events, counters = worker_fixture(function()
    reads = reads + 1
    if reads == 1 then worker.request(driver, device); worker.request(driver, device) end
    return { temperature = 25, desired = 24, unit = "C", humidity = 63, monitoringRaw = "On" }, "appliance-a"
  end)
  worker.start(driver, device)
  assert(#tasks == 1 and counters.schedules == 0)
  tasks[1]()
  assert(reads == 2 and #tasks == 1 and #events == 5 and counters.online == 2)
  assert(device:get_field("ac_worker").busy == false)
  package.loaded["network"] = network
end)
test("Removal cancels timer and prevents a queued network query", function()
  local reads = 0
  local worker, device, driver, tasks, events, counters = worker_fixture(function() reads = reads + 1 end)
  device.preferences.enablePolling = true
  worker.start(driver, device)
  worker.stop(driver, device)
  tasks[1]()
  assert(reads == 0 and #events == 0 and counters.cancelled == 1 and counters.closed == 1)
  assert(device:get_field("ac_worker") == nil)
  package.loaded["network"] = network
end)
test("Worker failure marks offline without invented measurements", function()
  local worker, device, driver, tasks, events, counters = worker_fixture(function() error("test connection failure") end)
  worker.start(driver, device)
  tasks[1]()
  assert(counters.offline == 1 and #events == 0 and device:get_field("ac_worker").busy == false)
  package.loaded["network"] = network
end)
test("Worker publishes actual AC state and supported controls", function()
  local state = ac.summary(observed)
  state.monitoringRaw = "On"
  local worker, device, driver, tasks, events = worker_fixture(function() return state, "appliance-a" end)
  worker.start(driver, device); tasks[1]()
  local values = {}
  for _, event in ipairs(events) do values[event.component .. ":" .. event.attribute] = event.data end
  for _, event in ipairs(events) do
    local measurements = { temperature=true, humidity=true, dustLevel=true, fineDustLevel=true,
      veryFineDustLevel=true, odorLevel=true, airQualityHealthConcern=true }
    if event.attribute == "voice" or event.attribute == "lighting" or event.attribute == "onDelay"
      or event.attribute == "offDelay" or event.attribute == "door" or measurements[event.attribute] then
      assert(event.state_change == true)
    else assert(event.state_change == nil) end
  end
  assert(values["main:switch"].value == "off" and values["main:coolingSetpoint"].value == 24)
  assert(values["main:airConditionerMode"].value == "auto" and values["main:fanMode"].value == "auto")
  assert(values["main:coolingSetpointRange"].value.minimum == 18 and #values["main:supportedAcModes"].value == 5)
  assert(values["windfree:switch"].value == "off" and values["autoclean:switch"].value == "off")
  assert(values["purify:switch"].value == "off")
  assert(values["main:dustLevel"].value == 5 and values["main:fineDustLevel"].value == 5)
  assert(values["main:veryFineDustLevel"].value == 5 and values["main:odorLevel"].value == 1)
  assert(values["main:airQualityHealthConcern"].value == "good")
  assert(values["main:onDelay"].value == "none" and values["main:offDelay"].value == "none")
  assert(values["main:lighting"].value == "off" and values["main:voice"].value == "melody")
  assert(values["panel:door"].value == "closed")
  assert(values["speed:switch"].value == "off" and values["quiet:switch"].value == "off" and values["displayoff:switch"].value == "off")
  package.loaded["network"] = network
end)
test("Updated profile publishes grouped menus and reservations cannot overwrite their state", function()
  local state = ac.summary(observed)
  local worker, device, driver, tasks, events = worker_fixture(function() return state, "appliance-a" end)
  device.missing_capabilities = {}
  worker.start(driver, device); tasks[1]()
  local values = {}
  for _, event in ipairs(events) do values[event.capability .. ":" .. event.attribute] = event.data.value end
  local comfort, settings, care = "instantcommon43059.samsungAcLocalComfort:", "instantcommon43059.samsungAcLocalDeviceSettings:", "instantcommon43059.samsungAcLocalCare:"
  assert(values[comfort .. "windfree"] == "off" and values[comfort .. "windfreeEnabled"] == "disabled")
  assert(values[comfort .. "preset"] == "normal" and values[settings .. "display"] == "on")
  assert(values[settings .. "voice"] == "melody" and values[care .. "panel"] == "closed" and values[care .. "panelEnabled"] == "enabled")
  local operation = "instantcommon43059.samsungAcLocalOperation:"
  assert(values[operation .. "mode"] == "auto" and values[operation .. "setpoint"] == 24 and values[operation .. "fan"] == "auto")
  local prefix = "instantcommon43059.samsungAcLocal"
  assert(values[prefix .. "Temperature:setpoint"] == 24 and values[prefix .. "Temperature:setpointEnabled"] == "enabled")
  assert(values[prefix .. "AirFeatures:windfree"] == "off" and values[prefix .. "AirFeatures:purify"] == "off")
  assert(values[prefix .. "AirFeatures:windfreeEnabled"] == "disabled" and values[prefix .. "AirFeatures:purifyEnabled"] == "disabled")
  assert(values[prefix .. "Display:display"] == "on" and values[prefix .. "Panel:panel"] == "closed")
  assert(values[prefix .. "Panel:panelEnabled"] == "enabled" and values[prefix .. "Operating:fanEnabled"] == "enabled")
  assert(values[prefix .. "Operating:mode"] == "auto" and values[prefix .. "Operating:fan"] == "auto")
  local before = #events
  worker.reservation(driver, device, "offTimer", 0)
  for i = before + 1, #events do assert(events[i].capability == "instantcommon43059.samsungAcLocalTimer") end
  package.loaded["network"] = network
end)
test("AirMonitoring transitions clear the sensor card and only resume real numeric samples when on", function()
  local id = "instantcommon43059.samsungAcLocalSensors"
  local numeric = { temperatureMeasurement=true, relativeHumidityMeasurement=true, dustSensor=true,
    veryFineDustSensor=true, odorSensor=true, airQualityHealthConcern=true }
  local state = ac.summary(observed)
  state.monitoringRaw = "On"
  local worker, device, driver, tasks, events, counters = worker_fixture(function() return state, "appliance-a" end)
  device.missing_capabilities = {}
  worker.start(driver, device); tasks[1]()
  local function latest(attribute)
    for i=#events,1,-1 do
      if events[i].capability == id and events[i].attribute == attribute then return events[i].data.value end
    end
  end
  local function sensor_events_since(before)
    local count = 0
    for i=before+1,#events do if numeric[events[i].capability] then count = count + 1 end end
    return count
  end
  assert(latest("monitoring") == "on" and latest("humidity") == "63 %" and latest("dustLevel") == "5 μg/m³")
  local before = #events
  state.monitoringRaw = "Off"
  -- 운전 전원이 켜져도 AirMonitoring Off의 캐시 숫자는 현재 측정값으로 발행하지 않습니다.
  state.power = true
  worker.request(driver, device); tasks[#tasks]()
  assert(latest("monitoring") == "off" and sensor_events_since(before) == 0)
  for _, key in ipairs({"temperature", "humidity", "airQuality", "dustLevel", "fineDustLevel", "veryFineDustLevel", "gas"}) do
    assert(latest(key) == "-")
  end
  assert(device:get_field("ac_worker").sensors_active == false)
  before = #events
  worker.request(driver, device, true); tasks[#tasks]()
  assert(sensor_events_since(before) == 0 and latest("temperature") == "-")
  before = #events
  assert(worker.reservation(driver, device, "offTimer", 0)); tasks[#tasks]()
  for i=before+1,#events do assert(events[i].capability == "instantcommon43059.samsungAcLocalTimer") end
  assert(device:get_field("ac_worker").sensors_active == false and latest("monitoring") == "off")
  state.monitoringRaw = "On"
  before = #events
  worker.request(driver, device); tasks[#tasks]()
  assert(latest("monitoring") == "on" and latest("humidity") == "63 %" and sensor_events_since(before) == 7)
  for i=before+1,#events do
    if numeric[events[i].capability] then assert(events[i].state_change == true) end
  end
  before = #events
  assert(worker.reservation(driver, device, "onTimer", 0)); tasks[#tasks]()
  assert(latest("monitoring") == "on" and device:get_field("ac_worker").sensors_active == true)
  for i=before+1,#events do assert(events[i].capability == "instantcommon43059.samsungAcLocalTimer") end
  before = #events
  worker.request(driver, device); tasks[#tasks]()
  assert(#events == before, "unchanged enabled sensor polling must remain deduplicated")
  state.monitoringRaw = nil
  before = #events
  worker.request(driver, device); tasks[#tasks]()
  assert(latest("monitoring") == "unknown" and latest("temperature") == "-" and sensor_events_since(before) == 0)
  assert(counters.offline == 0)
  package.loaded["network"] = network
end)
test("Sensor card initializes off without numeric events and waits for an updated profile", function()
  local id = "instantcommon43059.samsungAcLocalSensors"
  local state = ac.summary(observed)
  assert(state.monitoringRaw == "Off")
  local worker, device, driver, tasks, events, counters = worker_fixture(function() return state, "appliance-a" end)
  worker.start(driver, device); tasks[1]()
  for _, event in ipairs(events) do
    assert(event.capability ~= id and event.capability ~= "temperatureMeasurement" and event.capability ~= "relativeHumidityMeasurement")
  end
  local before = #events
  device.missing_capabilities[id] = nil
  worker.request(driver, device); tasks[2]()
  assert(#events == before + 8)
  for i=before+1,#events do
    local event = events[i]
    assert(event.capability == id and event.state_change == true)
    assert(event.data.value == (event.attribute == "monitoring" and "off" or "-"))
  end
  assert(counters.offline == 0)
  package.loaded["network"] = network
end)
test("Native timer events use appliance observations and hub-only updates preserve them", function()
  local state = {power=true, onTimer=0, offTimer=1}
  local controls = {}
  local worker, device, driver, tasks, events = worker_fixture(function() return state, "appliance-a" end,
    function(_, _, _, _, _, _, _, command)
      controls[#controls + 1] = command
      return state, "appliance-a", "unconfirmed"
    end)
  local id = "instantcommon43059.samsungAcLocalNativeTimer"
  device.missing_capabilities[id] = nil
  worker.start(driver, device); tasks[1]()
  local function latest(attribute)
    for i=#events,1,-1 do
      if events[i].capability == id and events[i].attribute == attribute then return events[i].data.value end
    end
  end
  assert(latest("onDelay") == "none" and latest("offDelay") == "1")
  -- 기기에 30분이 있어도 허브 저장값은 없으며, 허브 2시간 설정이 본체 표시를 덮어쓰지 않습니다.
  assert(device:get_field("ac_reservations") == nil)
  assert(worker.reservation(driver, device, "offTimer", 4)); tasks[2]()
  local saved = device:get_field("ac_reservations")
  local due = saved.offTimer.due
  assert(latest("offDelay") == "1" and #controls == 0)
  assert(worker.command(driver, device, {kind="nativeOffTimer", value=2})); tasks[3]()
  assert(#controls == 1 and controls[1].kind == "nativeOffTimer" and controls[1].value == 2)
  assert(device:get_field("ac_reservations") == saved and saved.offTimer.due == due)
  assert(latest("offDelay") == "1", "an unconfirmed write must not display the requested delay")
  local before = #events
  assert(worker.reservation(driver, device, "offTimer", 0)); tasks[4]()
  for i=before+1,#events do assert(events[i].capability ~= id) end
  assert(device:get_field("ac_reservations").offTimer == nil and saved.offTimer.due == due)
  state = {power=true}
  worker.request(driver, device); tasks[5]()
  assert(latest("onDelay") == "unknown" and latest("offDelay") == "unknown")
  assert(not worker.command(driver, device, {kind="nativeOnTimer", value=0}))
  assert(#controls == 1)
  package.loaded["network"] = network
end)
test("UI reports basic Cool or Dry and a separate optional purification switch", function()
  for _, pair in ipairs({ { "CoolClean", "cool" }, { "DryClean", "dry" } }) do
    local state = state_with_mode(pair[1])
    local worker, device, driver, tasks, events = worker_fixture(function() return state, "appliance-a" end)
    worker.start(driver, device); tasks[1]()
    local values = {}
    for _, event in ipairs(events) do values[event.component .. ":" .. event.attribute] = event.data.value end
    assert(values["main:airConditionerMode"] == pair[2] and values["purify:switch"] == "on")
    assert(#values["main:supportedAcModes"] == 5)
  end
  package.loaded["network"] = network
end)
test("Ten-second polling uses the configured schedule and unrecognized air-quality grades stay unknown", function()
  local worker, device, driver, tasks, events, counters = worker_fixture(function() return { power = false }, "appliance-a" end)
  device.preferences.enablePolling, device.preferences.refreshSeconds = true, 10
  worker.start(driver, device); tasks[1]()
  assert(counters.interval == 10 and counters.online == 1)
  local batch = cbor.decode(cbor.encode(observed))
  local items = ac.resources(batch)["/sensors/vs/0"][P .. "items"]
  for _, sensor in ipairs(items) do
    if sensor[P .. "type"] == "CleanLevel" then sensor[P .. "value"] = { "99" } end
  end
  assert(ac.summary(batch).airQualityConcern == "unknown")
  package.loaded["network"] = network
end)
test("An existing profile waits for its new purification component without going offline", function()
  local worker, device, driver, tasks, events, counters = worker_fixture(function() return ac.summary(observed), "appliance-a" end)
  device.profile.components.purify = nil
  device.profile.components.panel = nil
  worker.start(driver, device); tasks[1]()
  assert(counters.online == 1 and counters.offline == 0)
  for _, event in ipairs(events) do assert(event.component ~= "purify" and event.component ~= "panel") end
  package.loaded["network"] = network
end)
test("Worker queues settings in order without optimistic state events", function()
  local worker, device, driver, tasks, events, counters
  local calls = {}
  worker, device, driver, tasks, events, counters = worker_fixture(function() error("unexpected redundant read") end,
    function(_, _, _, _, identity, _, _, command)
      assert(identity == "appliance-a")
      calls[#calls + 1] = command.kind
      assert(#events == (#calls == 1 and 0 or 3))
      return { power = command.value }, identity, "confirmed"
    end)
  worker.start(driver, device)
  assert(worker.command(driver, device, { kind = "power", value = true }))
  assert(worker.command(driver, device, { kind = "power", value = false }))
  assert(#events == 0 and #tasks == 1)
  tasks[1]()
  assert(#calls == 2 and events[1].attribute == "switch" and events[1].data.value == "on")
  assert(events[4].attribute == "switch" and events[4].data.value == "off")
  assert(counters.online == 2 and not device:get_field("ac_worker").busy)
  package.loaded["network"] = network
end)
test("Worker rejects invalid commands and cancels queued settings on removal", function()
  local controls = 0
  local worker, device, driver, tasks, events = worker_fixture(function() return { power = false }, "appliance-a" end,
    function() controls = controls + 1 end)
  worker.start(driver, device)
  assert(not worker.command(driver, device, { kind = "mode", value = "heat" }))
  assert(worker.command(driver, device, { kind = "power", value = true }))
  worker.stop(driver, device); tasks[1]()
  assert(controls == 0 and #events == 0)
  package.loaded["network"] = network
end)
test("Unchanged reads emit nothing, local reservations emit without LAN and resync remains paced", function()
  local worker, device, driver, tasks, events, counters = worker_fixture(function()
    local state = ac.summary(cbor.decode(cbor.encode(observed)))
    return state, "appliance-a"
  end)
  worker.start(driver, device); tasks[1]()
  local initial, delay = #events, counters.slept
  assert(initial > 20 and delay >= (initial - 1) * 0.25)
  worker.request(driver, device); tasks[2]()
  assert(#events == initial and counters.online == 2 and counters.offline == 0)
  assert(worker.reservation(driver, device, "offTimer", 2)); tasks[3]()
  assert(#events == initial + 1 and events[#events].attribute == "offDelay" and events[#events].data.value == "2")
  assert(counters.online == 2 and counters.offline == 0)
  worker.request(driver, device, true); tasks[4]()
  assert(#events == initial * 2 + 1)
  counters.advance(301); worker.request(driver, device); tasks[5]()
  assert(#events == initial * 3 + 1 and counters.offline == 0)
  package.loaded["network"] = network
end)
test("Selecting the current list value acknowledges its observed state without republishing sensors", function()
  local prefix = "instantcommon43059.samsungAcLocal"
  local state = ac.summary(observed)
  local control_calls = 0
  local worker, device, driver, tasks, events, counters = worker_fixture(function() return state, "appliance-a" end,
    function(_, _, _, _, _, _, _, command)
      control_calls = control_calls + 1
      -- 실제 전송 계층의 unchanged 반환을 모사합니다. UI 응답은 명령 인자가 아닌 관측값입니다.
      return state, "appliance-a", "unchanged"
    end)
  device.missing_capabilities = {}
  worker.start(driver, device); tasks[1]()
  local cases = {
    { "mode", state.acMode, prefix .. "Operating", "mode" },
    { "fan", state.fanMode, prefix .. "Operating", "fan" },
    { "lighting", state.lighting, prefix .. "DeviceSettings", "lighting" },
    { "voice", state.voice, prefix .. "DeviceSettings", "voice" },
    { "outlet", "closed", prefix .. "Comfort", "outlet" },
    { "panel", state.panel, prefix .. "Panel", "panel" },
    { "preset", "normal", prefix .. "Comfort", "preset" },
    { "setpoint", state.desired, prefix .. "Temperature", "setpoint" },
    { "power", state.power, "switch", "switch" },
  }
  local function latest(capability, attribute)
    for i = #events, 1, -1 do
      local e = events[i]
      if e.component == "main" and e.capability == capability and e.attribute == attribute then return e end
    end
  end
  for _, case in ipairs(cases) do
    local previous = latest(case[3], case[4])
    assert(previous)
    for repeat_selection = 1, 2 do
      local before = #events
      assert(worker.command(driver, device, {kind=case[1], value=case[2]}))
      tasks[#tasks]()
      local reply = latest(case[3], case[4])
      assert(reply ~= previous and reply.state_change == true and reply.data.value == previous.data.value)
      assert(#events > before and #events <= before + 3)
      for i = before + 1, #events do
        local e = events[i]
        assert(e.state_change == true and e.capability ~= "temperatureMeasurement"
          and e.capability ~= "relativeHumidityMeasurement" and e.capability ~= "dustSensor")
      end
      previous = reply
    end
  end
  local before = #events
  worker.request(driver, device); tasks[#tasks]()
  assert(#events == before and control_calls == #cases * 2 and counters.offline == 0)
  package.loaded["network"] = network
end)
test("Selecting no reservation repeatedly replies locally and never writes appliance power", function()
  local reads, writes = 0, 0
  local worker, device, driver, tasks, events = worker_fixture(function()
    reads = reads + 1; return { power=false }, "appliance-a"
  end, function() writes = writes + 1; error("unexpected appliance command") end)
  worker.start(driver, device); tasks[1]()
  for _, kind in ipairs({"onTimer", "offTimer"}) do
    for repeat_selection = 1, 2 do
      local before = #events
      assert(worker.reservation(driver, device, kind, 0)); tasks[#tasks]()
      assert(#events == before + 1)
      local reply = events[#events]
      assert(reply.capability == "instantcommon43059.samsungAcLocalTimer" and reply.data.value == "none")
      assert(reply.attribute == (kind == "onTimer" and "onDelay" or "offDelay") and reply.state_change == true)
    end
  end
  assert(reads == 1 and writes == 0)
  -- 같은 남은 시간을 다시 선택하면 만료 시각을 재설정하되, 동일한 UI 값도 응답합니다.
  assert(worker.reservation(driver, device, "offTimer", 1)); tasks[#tasks]()
  local before = #events
  assert(worker.reservation(driver, device, "offTimer", 1)); tasks[#tasks]()
  assert(#events == before + 1 and events[#events].data.value == "1")
  assert(reads == 1 and writes == 0)
  package.loaded["network"] = network
end)
test("Unconfirmed commands report observed values instead of echoing requested list selections", function()
  local state = ac.summary(observed)
  local worker, device, driver, tasks, events = worker_fixture(function() return state, "appliance-a" end,
    function() return state, "appliance-a", "unconfirmed" end)
  device.missing_capabilities = {}
  worker.start(driver, device); tasks[1]()
  local before = #events
  assert(state.voice ~= "mute")
  assert(worker.command(driver, device, {kind="voice", value="mute"})); tasks[2]()
  assert(#events == before + 2)
  for i = before + 1, #events do
    assert(events[i].attribute == "voice" and events[i].data.value == state.voice and events[i].state_change)
  end
  package.loaded["network"] = network
end)
test("Removal during event pacing stops later events and leaves no online notification", function()
  local worker, device, driver, tasks, events, counters = worker_fixture(function()
    return { power = false, temperature = 25, unit = "C" }, "appliance-a"
  end)
  package.loaded["cosock.socket"].sleep = function() worker.stop(driver, device) end
  worker.start(driver, device); tasks[1]()
  assert(#events == 1 and counters.online == 0 and counters.offline == 0 and device:get_field("ac_worker") == nil)
  package.loaded["network"] = network
end)
test("Local reservation cancellation works offline without fabricating sensor readings or power writes", function()
  local reads, writes = 0, 0
  local worker, device, driver, tasks, events, counters = worker_fixture(function()
    reads = reads + 1; error("appliance offline")
  end, function() writes = writes + 1; error("unexpected power write") end)
  worker.start(driver, device); tasks[1]()
  assert(reads == 1 and counters.offline == 1 and #events == 0)
  assert(worker.reservation(driver, device, "onTimer", 2)); tasks[2]()
  assert(worker.reservation(driver, device, "onTimer", 0)); tasks[3]()
  assert(reads == 1 and writes == 0 and counters.online == 0 and counters.offline == 1)
  for _, event in ipairs(events) do assert(event.attribute == "onDelay" or event.attribute == "offDelay") end
  assert(not worker.command(driver, device, { kind = "onTimer", value = 0 }))
  package.loaded["network"] = network
end)
test("Worker recovers an uncertain write with GET only", function()
  local reads, writes = 0, 0
  local worker, device, driver, tasks, events, counters = worker_fixture(function()
    reads = reads + 1; return { power = true }, "appliance-a"
  end, function(_, _, _, _, _, context)
    writes = writes + 1; context.write_attempted = true; error("lost acknowledgement")
  end)
  worker.start(driver, device); worker.command(driver, device, { kind = "power", value = true }); tasks[1]()
  assert(writes == 1 and reads == 1 and #events == 3 and events[1].data.value == "on")
  assert(counters.offline == 1 and counters.online == 1)
  assert(table.concat(counters.logs, " "):find("AC_COMMAND_UNCERTAIN", 1, true))
  package.loaded["network"] = network
end)
test("Appliance range rejection keeps the last observed state online", function()
  local worker, device, driver, tasks, events, counters = worker_fixture(function() error("unexpected read") end,
    function(_, _, _, _, _, context)
      context.verified_state, context.command_rejected = { power = false }, true
      error("setpoint outside appliance range")
    end)
  worker.start(driver, device); worker.command(driver, device, { kind = "setpoint", value = 31 }); tasks[1]()
  assert(counters.online == 1 and counters.offline == 0 and events[1].data.value == "off")
  assert(not device:get_field("ac_worker").busy)
  package.loaded["network"] = network
end)
test("Explicit appliance POST rejection is an online command failure, not a network outage", function()
  local worker, device, driver, tasks, events, counters = worker_fixture(function() error("no automatic retry after an explicit rejection") end,
    function(_, _, _, _, _, context)
      context.verified_state, context.write_attempted, context.write_rejected = { power = true }, true, true
      error("CoAP POST rejected 4.00")
    end)
  worker.start(driver, device); worker.command(driver, device, { kind = "mode", value = "aIComfort" }); tasks[1]()
  assert(counters.online == 1 and counters.offline == 0 and events[1].data.value == "on")
  assert(table.concat(counters.logs, " "):find("AC_COMMAND_REJECTED", 1, true))
  package.loaded["network"] = network
end)
test("Device removal during a control prevents late events", function()
  local worker, device, driver, tasks, events
  worker, device, driver, tasks, events = worker_fixture(function() error("unexpected read") end,
    function()
      worker.stop(driver, device)
      return { power = true }, "appliance-a", "confirmed"
    end)
  worker.start(driver, device); worker.command(driver, device, { kind = "power", value = true }); tasks[1]()
  assert(#events == 0 and device:get_field("ac_worker") == nil)
  package.loaded["network"] = network
end)
test("Event publication failure releases the worker without repeating a setting", function()
  local writes = 0
  local worker, device, driver, tasks = worker_fixture(function() error("unexpected read") end,
    function(_, _, _, _, _, context)
      writes = writes + 1; context.verified_state = { power = false }
      return context.verified_state, "appliance-a", "unchanged"
    end)
  device.emit_component_event = function() error("test SDK event failure") end
  worker.start(driver, device); worker.command(driver, device, { kind = "power", value = false }); tasks[1]()
  assert(writes == 1 and not device:get_field("ac_worker").busy)
  package.loaded["network"] = network
end)
test("A new device uses its discovered address without a package host", function()
  local scans = 0
  local worker, device, driver, tasks, events = worker_fixture(function(_, _, _, address, identity)
    assert(address == "192.168.1.171" and identity == "appliance-a")
    return { power = false }, identity
  end, nil, function(_, _, _, identity)
    scans = scans + 1; assert(identity == "appliance-a")
    return { { identity = identity, host = "192.168.1.171" } }
  end)
  device:set_field("ocf_host", nil)
  package.loaded["private_config"].host = nil
  worker.start(driver, device); tasks[1]()
  assert(scans == 1 and #events == 3 and device:get_field("ocf_host") == "192.168.1.171")
  assert(driver.ac_hosts["appliance-a"] == "192.168.1.171")
  package.loaded["network"] = network
end)
test("An address remembered before device init is persisted and used", function()
  local worker, device, driver, tasks = worker_fixture(function(_, _, _, address)
    assert(address == "192.168.1.172"); return { power = false }, "appliance-a"
  end)
  worker.remember_host(driver, "appliance-a", "192.168.1.172", false)
  worker.start(driver, device); tasks[1]()
  assert(device:get_field("ocf_host") == "192.168.1.172")
  package.loaded["network"] = network
end)
test("A stale DHCP address is rediscovered by identity and retried with GET", function()
  local reads, scans = 0, 0
  local worker, device, driver, tasks, events = worker_fixture(function(_, _, _, address, identity, _, phase)
    reads = reads + 1
    phase("udp-discovery")
    if address == "192.168.1.170" then error("old address is unreachable") end
    assert(address == "192.168.1.171" and identity == "appliance-a")
    return { power = false }, identity
  end, nil, function(_, _, _, identity)
    scans = scans + 1; assert(identity == "appliance-a")
    return { { identity = identity, host = "192.168.1.171" } }
  end)
  worker.start(driver, device); tasks[1]()
  assert(reads == 2 and scans == 1 and #events == 3 and device:get_field("ocf_host") == "192.168.1.171")
  package.loaded["network"] = network
end)
test("Manual addresses and TLS rejection do not cause automatic relocation", function()
  for _, manual in ipairs({ true, false }) do
    local worker, device, driver, tasks, events, counters = worker_fixture(function(_, _, _, address, _, _, phase)
      if manual then assert(address == "192.168.1.199"); phase("udp-discovery") else phase("tls-handshake") end
      error("test connection failure")
    end)
    if manual then device.preferences.targetIp = "192.168.1.199" end
    worker.start(driver, device); tasks[1]()
    assert(counters.offline == 1 and #events == 0)
  end
  package.loaded["network"] = network
end)
test("A lost write acknowledgement recovers the address without another POST", function()
  local reads, controls, scans = 0, 0, 0
  local worker, device, driver, tasks, events = worker_fixture(function(_, _, _, address, identity, _, phase)
    reads = reads + 1; phase("udp-discovery")
    if address == "192.168.1.170" then error("old DHCP address") end
    return { power = true }, identity
  end, function(_, _, _, _, _, context)
    controls = controls + 1; context.write_attempted = true; error("acknowledgement lost")
  end, function(_, _, _, identity)
    scans = scans + 1; return { { identity = identity, host = "192.168.1.171" } }
  end)
  worker.start(driver, device); worker.command(driver, device, { kind = "power", value = true }); tasks[1]()
  assert(controls == 1 and reads == 2 and scans == 1 and #events == 3 and events[1].data.value == "on")
  package.loaded["network"] = network
end)
test("Removal while resolving an address prevents a late query", function()
  local worker, device, driver, tasks, events
  worker, device, driver, tasks, events = worker_fixture(function() error("removed device must not read") end,
    nil, function(_, _, _, identity)
      worker.stop(driver, device)
      return { { identity = identity, host = "192.168.1.171" } }
    end)
  device:set_field("ocf_host", nil)
  worker.start(driver, device); tasks[1]()
  assert(#events == 0 and device:get_field("ac_worker") == nil)
  package.loaded["network"] = network
end)

-- 초기 검색·앱 검색·비동기 생성 사이의 연결을 실제 init.lua 진입점에서 검사합니다.
local function discovery_driver_fixture(options)
  options = options or {}
  local template, bootstrap, instance
  local tasks, devices, creations, remembered = {}, {}, {}, {}
  local counters = { scans = 0, clock = 0 }
  local active = true
  local result = { identity = "appliance-a", host = "192.168.1.170", manufacturer = "Samsung Electronics", model = "A20_FAC_BORA_18K" }
  package.loaded["st.capabilities"] = capabilities()
  package.loaded["cosock"] = { spawn = function(fn) tasks[#tasks + 1] = fn end }
  package.loaded["cosock.socket"] = { gettime = function() return counters.clock end, sleep = function(n) counters.clock = counters.clock + n end }
  package.loaded["network"] = { scan = function(_, _, should_continue)
    counters.scans = counters.scans + 1
    if options.cancel then active = false end
    return options.empty and {} or { result, result }
  end, close = function() end }
  package.loaded["worker"] = { start = function() end, stop = function() end, request = function() end,
    remember_host = function(_, identity, address) remembered[#remembered + 1] = { identity, address } end }
  package.loaded["private_config"] = { build_id = "test-without-host" }
  package.loaded["log"] = { info = function() end, error = function() end }
  package.loaded["st.driver"] = function(_, definition)
    template = definition
    instance = { run = function() end, call_with_delay = function(_, _, callback) bootstrap = callback end,
      get_devices = function() return devices end,
      try_create_device = function(_, metadata)
        creations[#creations + 1] = metadata
        if options.fail_first and #creations == 1 then return nil, "test creation failure" end
      end }
    return instance
  end
  dofile(root .. "/driver/src/init.lua")
  return { template = template, driver = instance, bootstrap = bootstrap, tasks = tasks, creations = creations,
    devices = devices, remembered = remembered, counters = counters, continuing = function() return active end }
end
test("Startup search and pending creations do not add duplicate devices", function()
  local t = discovery_driver_fixture()
  t.bootstrap(); t.template.discovery(t.driver)
  assert(#t.tasks == 1)
  t.tasks[1]()
  assert(#t.creations == 1 and t.creations[1].device_network_id == "samsung-ac-ocf:appliance-a")
  assert(t.creations[1].model == "A20_FAC_BORA_18K" and #t.remembered == 2)
  t.template.discovery(t.driver); t.tasks[2]()
  assert(#t.creations == 1 and t.counters.scans == 2)
  local requested_profile
  local device = { device_network_id = "samsung-ac-ocf:appliance-a",
    try_update_metadata = function(_, metadata) requested_profile = metadata.profile end }
  t.devices[1] = device
  t.template.lifecycle_handlers.init(t.driver, device)
  assert(requested_profile == "samsung-ac")
  t.template.discovery(t.driver); t.tasks[3]()
  assert(#t.creations == 1)
  package.loaded["network"] = network
end)
test("App search cancellation prevents creation and creation errors allow a later search", function()
  local t = discovery_driver_fixture({ cancel = true })
  t.template.discovery(t.driver, {}, t.continuing); t.tasks[1]()
  assert(#t.creations == 0)
  t = discovery_driver_fixture({ fail_first = true })
  t.bootstrap(); t.tasks[1]()
  t.template.discovery(t.driver); t.tasks[2]()
  assert(#t.creations == 2)
  package.loaded["network"] = network
end)
test("Driver routes standard AC commands and switch components", function()
  local template, bootstrap
  local caps, commands, reservations = capabilities(), {}, {}
  package.loaded["st.capabilities"] = caps
  package.loaded["cosock"] = { spawn = function() end }
  package.loaded["cosock.socket"] = {}
  package.loaded["private_config"] = { expires_at = os.time() + 60, build_id = "test" }
  package.loaded["worker"] = { request = function() end, start = function() end, stop = function() end,
    command = function(_, _, command) commands[#commands + 1] = command end,
    reservation = function(_, _, kind, units) reservations[#reservations + 1] = { kind = kind, value = units } end }
  package.loaded["log"] = { info = function() end, error = function() end }
  package.loaded["st.driver"] = function(_, options)
    template = options
    return { run = function() end, call_with_delay = function(_, _, callback) bootstrap = callback end }
  end
  dofile(root .. "/driver/src/init.lua")
  assert(#template.supported_capabilities == 25 and template.capability_handlers.refresh.refresh and type(bootstrap) == "function")
  local h = template.capability_handlers
  h.switch.on(nil, nil, { component = "main" })
  h.switch.off(nil, nil, { component = "windfree" })
  h.switch.on(nil, nil, { component = "autoclean" })
  h.thermostatCoolingSetpoint.setCoolingSetpoint(nil, nil, { args = { setpoint = 23 } })
  h.airConditionerMode.setAirConditionerMode(nil, nil, { args = { mode = "cool" } })
  h.airConditionerFanMode.setFanMode(nil, nil, { args = { fanMode = "high" } })
  h.switch.on(nil, nil, { component = "purify" })
  h.airConditionerMode.setAirConditionerMode(nil, nil, { args = { mode = "aIComfort" } })
  h.switch.on(nil, nil, { component = "unknown" })
  h.airConditionerMode.setAirConditionerMode(nil, nil, { component = "windfree", args = { mode = "cool" } })
  assert(#commands == 8 and commands[1].kind == "power" and commands[1].value == true)
  assert(commands[2].kind == "windfree" and commands[2].value == false and commands[3].kind == "autoclean")
  assert(commands[4].kind == "setpoint" and commands[4].value == 23 and commands[5].kind == "mode" and commands[6].kind == "fan")
  assert(commands[7].kind == "purify" and commands[8].value == "aIComfort")
  local timers = h["instantcommon43059.samsungAcLocalTimer"]
  timers.setOnDelay(nil, nil, { args = { delay = "2" } })
  timers.setOffDelay(nil, nil, { args = { delay = "4" } })
  timers.cancelOn(nil, nil, {})
  timers.cancelOff(nil, nil, {})
  assert(#commands == 8 and #reservations == 4 and reservations[1].kind == "onTimer" and reservations[1].value == 2)
  assert(reservations[2].kind == "offTimer" and reservations[2].value == 4)
  assert(reservations[3].value == 0 and reservations[4].value == 0)
  timers.setOffDelay(nil, nil, { args = { delay = "none" } })
  assert(#commands == 8 and reservations[5].kind == "offTimer" and reservations[5].value == 0)
  local options = h["instantcommon43059.samsungAcLocalSettings"]
  options.setLighting(nil, nil, { args = { setting = "medium" } })
  options.setVoice(nil, nil, { args = { setting = "mute" } })
  h.switch.on(nil, nil, { component = "speed" })
  h.switch.off(nil, nil, { component = "quiet" })
  h.switch.on(nil, nil, { component = "displayoff" })
  assert(#commands == 13 and commands[9].kind == "lighting" and commands[9].value == "medium")
  assert(commands[10].kind == "voice" and commands[10].value == "mute" and commands[11].kind == "speed")
  assert(commands[12].kind == "quiet" and commands[13].kind == "displayOff")
  h.doorControl.open(nil, nil, { component = "panel" })
  h.doorControl.close(nil, nil, { component = "panel" })
  h.doorControl.open(nil, nil, { component = "main" })
  h.doorControl.open(nil, nil, { component = "doorupper" })
  assert(#commands == 15 and commands[14].kind == "panel" and commands[14].value == "open" and commands[15].value == "closed")
  local comfort = h["instantcommon43059.samsungAcLocalComfort"]
  comfort.setPreset(nil, nil, {args={setting="quiet"}})
  comfort.setOutlet(nil, nil, {args={setting="upper"}})
  comfort.setWindfree(nil, nil, {args={setting="on"}})
  comfort.setPurify(nil, nil, {args={setting="off"}})
  local device_settings = h["instantcommon43059.samsungAcLocalDeviceSettings"]
  device_settings.setDisplay(nil, nil, {args={setting="on"}})
  device_settings.setDisplay(nil, nil, {args={setting="off"}})
  device_settings.setDisplay(nil, nil, {args={setting="invalid"}})
  device_settings.setDisplay(nil, nil, {component="displayoff",args={setting="on"}})
  h["instantcommon43059.samsungAcLocalCare"].setPanel(nil, nil, {args={setting="closed"}})
  assert(#commands == 22 and commands[16].kind == "preset" and commands[16].value == "quiet")
  assert(commands[17].kind == "outlet" and commands[17].value == "upper")
  assert(commands[18].kind == "windfree" and commands[18].value == true)
  assert(commands[19].kind == "purify" and commands[19].value == false)
  assert(commands[20].kind == "displayOff" and commands[20].value == false)
  assert(commands[21].kind == "displayOff" and commands[21].value == true and commands[22].kind == "panel")
  local operation = h["instantcommon43059.samsungAcLocalOperation"]
  operation.setMode(nil, nil, {args={setting="dry"}})
  operation.setTemperature(nil, nil, {args={setpoint=26}})
  operation.setFan(nil, nil, {args={setting="low"}})
  operation.setMode(nil, nil, {component="windfree",args={setting="cool"}})
  assert(#commands == 25 and commands[23].kind == "mode" and commands[23].value == "dry")
  assert(commands[24].kind == "setpoint" and commands[24].value == 26)
  assert(commands[25].kind == "fan" and commands[25].value == "low")
  -- 분리된 카드가 기존 모드 검사와 같은 작업 큐에 정확한 값으로 연결되는지 확인합니다.
  h["instantcommon43059.samsungAcLocalTemperature"].setTemperature(nil, nil, {args={setpoint=23}})
  h["instantcommon43059.samsungAcLocalAirFeatures"].setWindfree(nil, nil, {args={setting="on"}})
  h["instantcommon43059.samsungAcLocalAirFeatures"].setPurify(nil, nil, {args={setting="off"}})
  h["instantcommon43059.samsungAcLocalDisplay"].setDisplay(nil, nil, {args={setting="on"}})
  h["instantcommon43059.samsungAcLocalPanel"].setPanel(nil, nil, {args={setting="closed"}})
  assert(#commands == 30 and commands[26].kind == "setpoint" and commands[26].value == 23)
  assert(commands[27].kind == "windfree" and commands[27].value == true)
  assert(commands[28].kind == "purify" and commands[28].value == false)
  assert(commands[29].kind == "displayOff" and commands[29].value == false)
  assert(commands[30].kind == "panel" and commands[30].value == "closed")
  h["instantcommon43059.samsungAcLocalOperating"].setMode(nil, nil, {args={setting="cool"}})
  h["instantcommon43059.samsungAcLocalOperating"].setFan(nil, nil, {args={setting="high"}})
  assert(commands[31].kind == "mode" and commands[31].value == "cool")
  assert(commands[32].kind == "fan" and commands[32].value == "high")
  h["instantcommon43059.samsungAcLocalAirFeatures"].setWindfree(nil, nil, {args={setting="invalid"}})
  h["instantcommon43059.samsungAcLocalDisplay"].setDisplay(nil, nil, {component="windfree",args={setting="on"}})
  h["instantcommon43059.samsungAcLocalPanel"].setPanel(nil, nil, {component="panel",args={setting="open"}})
  assert(#commands == 32)
  local native = h["instantcommon43059.samsungAcLocalNativeTimer"]
  assert(native.cancelOn == nil and native.cancelOff == nil)
  native.setOffDelay(nil, nil, {args={setting="1"}})
  native.setOnDelay(nil, nil, {args={setting="2"}})
  native.setOffDelay(nil, nil, {component="panel",args={setting="1"}})
  assert(#commands == 34 and #reservations == 5)
  assert(commands[33].kind == "nativeOffTimer" and commands[33].value == 1)
  assert(commands[34].kind == "nativeOnTimer" and commands[34].value == 2)
end)
if arg[3] then
  -- 검사 전체의 이벤트 수가 늘어도 본체용 64 KiB 프레임 제한을 완화하지 않습니다.
  -- 개수를 앞에 기록하고 각 이벤트를 독립 CBOR 항목으로 내보냅니다.
  local output = assert(io.open(arg[3], "wb"))
  output:write(cbor.encode(#captured_events))
  for _, event in ipairs(captured_events) do output:write(cbor.encode(event)) end
  output:close()
end
print("Lua 5.3 tests passed: " .. passed)
