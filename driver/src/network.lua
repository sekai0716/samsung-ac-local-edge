-- 공개 탐색 → CA 검증·클라이언트 인증 → 신원 대조 뒤에만 상태 조회·설정을 수행합니다.
local cbor = require "cbor"
local coap = require "coap"
local ac = require "ac"
local M = {}
local TIMEOUT = 4
local MULTICAST, DISCOVERY_SECONDS = "224.0.1.187", 5
local SUPPORTED_MODEL = "A20_FAC_BORA_18K"

function M.valid_host(host)
  if type(host) ~= "string" then return false end
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 or a == 0 or a == 127 or a >= 224 then return false end
  return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
end

local function close(socket)
  if socket then pcall(function() socket:close() end) end
end

function M.close(context)
  close(context.stream)
  close(context.raw)
  close(context.udp)
  if context.relay then context.relay.close() end
  context.stream, context.raw, context.udp = nil, nil, nil
  context.connection = nil
end

local function timeout(socket, seconds)
  local _, err = socket:settimeout(seconds)
  assert(not err, "socket timeout configuration failed")
end

function M.public_get(socket_api, host, path, query, context)
  local udp = assert(socket_api.udp())
  context.udp = udp
  local token = coap.token()
  local deadline = socket_api.gettime() + TIMEOUT
  local ok, value = pcall(function()
    timeout(udp, TIMEOUT)
    assert(udp:sendto(coap.udp_get(path, token, query), host, 5683))
    while socket_api.gettime() < deadline do
      assert(not context.cancelled, "query cancelled")
      timeout(udp, math.max(0.001, deadline - socket_api.gettime()))
      local data, address, port = udp:receivefrom()
      assert(data, "public CoAP receive failed")
      if address == host then
        local response = coap.udp_reply(data, token)
        if response then
          if response.ack then assert(udp:sendto(response.ack, address, port)) end
          assert(response.code == 69, "public CoAP GET rejected")
          return cbor.decode(response.payload)
        end
      end
    end
    error("public CoAP deadline")
  end)
  close(udp)
  if context.udp == udp then context.udp = nil end
  if not ok then error(value, 0) end
  return value
end

function M.endpoint(directory)
  local result
  ac.walk(directory, function(entry)
    if entry.href == "/oic/sec/doxm" and type(entry.p) == "table" and entry.p.sec == true then
      local port = entry.p["x.org.iotivity.tls"]
      if type(port) == "number" and port % 1 == 0 and port > 0 and port <= 65535 then result = port end
    end
  end)
  assert(result, "no advertised TCP TLS endpoint")
  return result
end

function M.discover(socket_api, host, context)
  assert(M.valid_host(host), "a private appliance IPv4 address is required")
  local device = M.public_get(socket_api, host, "/oic/d", nil, context)
  local is_ac = false
  for _, resource_type in ipairs(type(device.rt) == "table" and device.rt or {}) do
    if resource_type == "oic.d.airconditioner" then is_ac = true end
  end
  assert(is_ac and type(device.di) == "string" and #device.di > 0, "target is not an identified OCF AC")
  local directory = M.public_get(socket_api, host, "/oic/res", "rt=oic.r.doxm", context)
  return { identity = device.di, port = M.endpoint(directory), host = host }
end

-- 디렉터리 안의 에어컨 링크만 후보로 삼습니다. 응답이 알려 준 URL이나 임의 주소는 사용하지 않습니다.
local function ac_directory(directory)
  local found = false
  ac.walk(directory, function(entry)
    if entry.href == "/oic/d" and type(entry.rt) == "table" then
      for _, kind in ipairs(entry.rt) do if kind == "oic.d.airconditioner" then found = true end end
    end
  end)
  return found
end

-- IP 입력 없이 검색합니다. 공개 GET만 사용하고 각 후보를 unicast로 다시 확인합니다.
-- 설정 매핑을 확인한 보드만 등록하며, mnmo의 | 뒤에 붙은 추가 식별 정보는 반환하지 않습니다.
function M.scan(socket_api, context, should_continue, expected_identity, seed_host)
  local udp = assert(socket_api.udp())
  context.udp = udp
  local function continuing()
    return not context.cancelled and (not should_continue or should_continue())
  end
  local ok, hosts = pcall(function()
    local _, bind_error = udp:setsockname("*", 0)
    assert(not bind_error, "discovery UDP bind failed")
    -- 허브 SDK는 ip-multicast-ttl을 지원하지 않으므로 기본 멀티캐스트 TTL을 사용합니다.
    local token, found = coap.token(), {}
    if seed_host then
      assert(M.valid_host(seed_host), "invalid optional discovery host")
      found[seed_host] = true
    end
    local deadline = socket_api.gettime() + DISCOVERY_SECONDS
    timeout(udp, 0.25)
    if continuing() then assert(udp:sendto(coap.udp_discovery(token), MULTICAST, 5683)) end
    while continuing() and socket_api.gettime() < deadline do
      timeout(udp, math.max(0.001, math.min(0.25, deadline - socket_api.gettime())))
      local data, address, port = udp:receivefrom()
      if data and M.valid_host(address) then
        -- 잘못된 CBOR·분할 응답·다른 토큰은 다른 기기의 정상 응답까지 중단시키지 않습니다.
        local parsed, response = pcall(coap.udp_reply, data, token)
        if parsed and response and response.code == 69 then
          if response.ack then assert(udp:sendto(response.ack, address, port)) end
          local decoded, directory = pcall(cbor.decode, response.payload)
          if decoded then
            local checked, is_ac = pcall(ac_directory, directory)
            if checked and is_ac then found[address] = true end
          end
        end
      elseif not data and address ~= "timeout" then error("multicast receive failed") end
    end
    local result = {}
    for address in pairs(found) do result[#result + 1] = address end
    table.sort(result)
    return result
  end)
  close(udp)
  if context.udp == udp then context.udp = nil end
  if not ok then error(hosts, 0) end

  local result, identities = {}, {}
  for _, host in ipairs(hosts) do
    if not continuing() then break end
    local verified, device = pcall(function()
      local candidate = M.discover(socket_api, host, context)
      if expected_identity and candidate.identity ~= expected_identity then return nil end
      local platform = M.public_get(socket_api, host, "/oic/p", nil, context)
      local model = type(platform.mnmo) == "string" and platform.mnmo:match("^[^|]+")
      if platform.mnmn ~= "Samsung Electronics" or model ~= SUPPORTED_MODEL then return nil end
      candidate.model, candidate.manufacturer = model, platform.mnmn
      return candidate
    end)
    if verified and device and not identities[device.identity] then
      identities[device.identity] = true
      result[#result + 1] = device
      if expected_identity then break end
    end
  end
  return result
end

local function open_tls(socket_api, ssl_api, config, host, port, context, mark)
  for attempt = 1, 6 do
    context.tls_role_collision = false
    mark("tcp-connect")
    local raw = assert(socket_api.tcp())
    context.raw = raw
    timeout(raw, TIMEOUT)
    local _, err = raw:connect(host, port)
    assert(not err, "TCP connect failed")
    mark("tls-wrap")
    local stream, wrap_error = ssl_api.wrap(raw, {
      mode = "client", protocol = "any", verify = "peer",
      options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
      cafile = assert(config.ca_pem, "missing server CA"),
      certificates = { { certificate = assert(config.client_certificate, "missing client certificate"),
        key = assert(config.client_key, "missing client key") } },
    })
    assert(stream and not wrap_error, "TLS wrap failed: " .. tostring(wrap_error))
    context.stream = stream
    timeout(stream, TIMEOUT)
    mark("tls-handshake")
    local _, handshake_error = stream:dohandshake()
    if not handshake_error then return stream end
    -- 실제 ClientHello 충돌을 본 경우에만, CoAP 요청 전 연결을 다시 엽니다.
    -- 인증서 거부와 POST 이후의 오류는 이 재시도 경로에 들어오지 않습니다.
    local retry = context.tls_role_collision and not context.cancelled and attempt < 6
    M.close(context)
    assert(retry, "TLS handshake failed: " .. tostring(handshake_error))
    mark("tls-role-retry:" .. attempt)
    socket_api.sleep(0.1 * attempt)
  end
end

local function run(socket_api, ssl_api, config, host, expected_identity, context, phase, command)
  context.write_attempted, context.write_rejected, context.command_rejected, context.verified_state = false, false, false, nil
  context.reused_connection = false
  local function mark(name)
    assert(not context.cancelled, "query cancelled")
    if phase then phase(name) end
  end
  local ok, value, identity, outcome = pcall(function()
    assert(type(config.expires_at) == "number" and os.time() < config.expires_at, "client certificate expired")
    assert(M.valid_host(host), "a private appliance IPv4 address is required")
    local connection, stream = context.connection, context.stream
    local endpoint
    if context.keep_connection and connection and stream and connection.host == host
      and (not expected_identity or connection.identity == expected_identity) then
      -- 이미 인증된 같은 TCP 연결은 UDP 손실 때문에 버리지 않습니다. TLS 내부 ID는 매번 다시 대조합니다.
      endpoint = connection
      context.reused_connection = true
      mark("tls-reuse")
    else
      M.close(context)
      mark("udp-discovery")
      endpoint = M.discover(socket_api, host, context)
      assert(not expected_identity or endpoint.identity == expected_identity, "public appliance identity mismatch")
      stream = open_tls(socket_api, ssl_api, config, host, endpoint.port, context, mark)
      -- ALPN은 제안하지 않습니다. 실제 장비에서 이 구성의 GET을 확인했습니다.
      coap.send(stream, "\48\225\34\64\0", socket_api.gettime, socket_api.gettime() + TIMEOUT)
    end
    mark("secure-identity")
    local secure = cbor.decode(coap.get(stream, "/oic/d", nil, socket_api.gettime, TIMEOUT))
    assert(secure.di == endpoint.identity, "secure appliance identity mismatch")
    if context.keep_connection then
      context.connection = { host = host, port = endpoint.port, identity = endpoint.identity }
    end
    local function read_state()
      mark("batch-get")
      local batch = cbor.decode(coap.get(stream, "/device/0", "if=oic.if.b", socket_api.gettime, TIMEOUT))
      local state = ac.summary(batch)
      context.verified_state = state
      return state
    end
    local state = read_state()
    if not command then return state, endpoint.identity end

    -- 자동 후속 작업은 GET 중 들어온 사용자 취소·새 전원 명령까지 확인한 뒤에만 씁니다.
    -- guard는 드라이버 내부에서만 붙이며, 생략된 일반 수동 명령은 기존 경로를 따릅니다.
    if command.guard and not command.guard(state) then return state, endpoint.identity, "skipped" end

    -- 매번 새 응답의 지원 목록과 범위로 검사합니다. 동일 상태는 POST 없이 종료합니다.
    local planned, plan = pcall(ac.plan, command, state)
    if not planned then context.command_rejected = true; error(plan, 0) end
    if not plan then return state, endpoint.identity, "unchanged" end
    local payload = cbor.encode(plan.body)
    mark("command-post:" .. command.kind)
    context.write_attempted = true
    local code = coap.post(stream, plan.path, payload, socket_api.gettime, TIMEOUT)
    if code >> 5 ~= 2 or code == 95 then
      context.write_rejected = true
      error(string.format("CoAP POST rejected %d.%02d", code >> 5, code & 31))
    end

    -- 2.xx만으로 적용 완료를 가정하지 않습니다. 최대 세 번 GET하며 POST는 한 번뿐입니다.
    for attempt = 1, 3 do
      if attempt > 1 then socket_api.sleep(1) end
      state = read_state()
      if ac.matches(command, state) then
        return state, endpoint.identity, plan.readback_ambiguous and "accepted" or "confirmed"
      end
    end
    return state, endpoint.identity, "unconfirmed"
  end)
  if not ok or not context.keep_connection then M.close(context) end
  if not ok then error(value, 0) end
  return value, identity, outcome
end

function M.read(socket_api, ssl_api, config, host, expected_identity, context, phase)
  -- PC 읽기 어댑터의 기존 2개 반환값 계약을 유지합니다. 제어 결과는 control에서만 반환합니다.
  local ok, state, identity = pcall(run, socket_api, ssl_api, config, host, expected_identity, context, phase)
  if ok then return state, identity end
  -- 유휴 중 닫힌 연결의 GET만 새 연결에서 다시 수행합니다.
  if context.reused_connection and not context.cancelled then
    local next_state, next_identity = run(socket_api, ssl_api, config, host, expected_identity, context, phase)
    return next_state, next_identity
  end
  error(state, 0)
end

-- 생성한 기기의 신원을 고정한 뒤에만 명령을 허용합니다. 임의 URI·메서드는 받지 않습니다.
function M.control(socket_api, ssl_api, config, host, expected_identity, context, phase, command)
  assert(type(expected_identity) == "string" and #expected_identity > 0, "bound appliance identity required for control")
  ac.validate(command)
  local ok, state, identity, outcome = pcall(run, socket_api, ssl_api, config, host, expected_identity, context, phase, command)
  if ok then return state, identity, outcome end
  if context.reused_connection and not context.write_attempted and not context.command_rejected and not context.cancelled then
    return run(socket_api, ssl_api, config, host, expected_identity, context, phase, command)
  end
  error(state, 0)
end

return M
