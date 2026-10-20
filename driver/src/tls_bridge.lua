-- TLS 암호문만 허브 안에서 전달합니다. ClientHello를 준비한 뒤 기기 TCP 연결을 엽니다.
-- TCP 연결 직후 기기가 먼저 TLS client가 되는 경합을 줄이고, 충돌은 호출자에게 알립니다.
local M = {}
local TIMEOUT, MAX_RECORD = 8, 18432

local function close_socket(stream)
  if stream then pcall(function() stream:close() end) end
end

local function record(stream)
  local header, err = stream:receive(5)
  if not header then return nil, err end
  local length = string.unpack(">I2", header, 4)
  assert(length > 0 and length <= MAX_RECORD, "invalid TLS relay record length")
  return header, assert(stream:receive(length))
end

local function send(stream, data)
  local at = 1
  while at <= #data do
    local last, err, partial = stream:send(data, at)
    if last then at = last + 1
    elseif partial and partial >= at then at = partial + 1
    else error("TLS relay send failed: " .. tostring(err)) end
  end
end

function M.socket_api(socket, spawn, hub_host, context)
  assert(type(hub_host) == "string" and hub_host ~= "", "missing hub IPv4 address")
  local api = {}
  for name, value in pairs(socket) do api[name] = value end
  api.tcp = function()
    assert(not context.cancelled, "query cancelled")
    local raw = assert(socket.tcp())
    local connect = raw.connect
    raw.connect = function(self, host, port)
      local relay = {}
      function relay.close()
        if relay.closed then return end
        relay.closed = true
        close_socket(relay.listener)
        close_socket(relay.client)
        close_socket(relay.server)
        if context.relay == relay then context.relay = nil end
      end
      context.relay = relay
      relay.listener = assert(socket.tcp())
      assert(relay.listener:bind("0.0.0.0", 0))
      assert(relay.listener:listen(1))
      relay.listener:settimeout(TIMEOUT)
      local _, local_port = relay.listener:getsockname()

      local function pump(from, to, server)
        local first = true
        local ok, failure = pcall(function()
          while not relay.closed and not context.cancelled do
            local header, body = record(from)
            if not header then return end
            if server and first and header:byte(1) == 22 and body:byte(1) == 1 then
              context.tls_role_collision = true
              return
            end
            first = false
            send(to, header .. body)
          end
        end)
        if not ok and not relay.closed then relay.failure = tostring(failure) end
        relay.close()
      end

      spawn(function()
        local ok, failure = pcall(function()
          if relay.closed or context.cancelled then return end
          relay.client = assert(relay.listener:accept())
          relay.listener:close(); relay.listener = nil
          local peer = relay.client:getpeername()
          assert(peer == hub_host, "TLS relay accepts only this hub")
          relay.client:settimeout(TIMEOUT)
          local header, body = record(relay.client)
          assert(header and header:byte(1) == 22 and #body <= 4096 and body:byte(1) == 1, "missing TLS ClientHello")
          assert(not relay.closed and not context.cancelled, "query cancelled")
          -- 기기 연결과 첫 전송 사이에는 TLS 초기화나 인증서 로딩을 하지 않습니다.
          relay.server = assert(socket.tcp())
          relay.server:settimeout(TIMEOUT)
          assert(relay.server:connect(host, port))
          send(relay.server, header .. body)
          relay.client:settimeout(120)
          relay.server:settimeout(120)
          local client, server = relay.client, relay.server
          spawn(function() pump(client, server, false) end, "ac-tls-relay-client")
          pump(server, client, true)
        end)
        if not ok and not relay.closed then relay.failure = tostring(failure) end
        relay.close()
      end, "ac-tls-relay")
      return connect(self, hub_host, local_port)
    end
    return raw
  end
  return api
end

return M
