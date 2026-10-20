-- 장비별 설정은 순서대로 처리하고 새로고침은 병합합니다. 관측 상태만 이벤트로 발행합니다.
local cosock = require "cosock"
local socket = require "cosock.socket"
local ssl = require "cosock.ssl"
local caps = require "st.capabilities"
local json = require "st.json"
local log = require "log"
local network = require "network"
local tls_bridge = require "tls_bridge"
local ac = require "ac"
local reservations = require "reservations"
local config = require "private_config"
local M = {}
local FIELD = "ac_worker"
local BASE_MODES = { coolClean = "cool", dryClean = "dry" }
local reservation = caps["instantcommon43059.samsungAcLocalTimer"]
local native_reservation = caps["instantcommon43059.samsungAcLocalNativeTimer"]
local settings = caps["instantcommon43059.samsungAcLocalSettings"]
local menu_caps = { caps["instantcommon43059.samsungAcLocalComfort"],
  caps["instantcommon43059.samsungAcLocalDeviceSettings"], caps["instantcommon43059.samsungAcLocalCare"],
  caps["instantcommon43059.samsungAcLocalOperation"], caps["instantcommon43059.samsungAcLocalTemperature"],
  caps["instantcommon43059.samsungAcLocalAirFeatures"], caps["instantcommon43059.samsungAcLocalDisplay"],
  caps["instantcommon43059.samsungAcLocalPanel"], caps["instantcommon43059.samsungAcLocalOperating"] }

local function manual_host(device)
  local value = device.preferences and device.preferences.targetIp
  if value and value ~= "" then
    assert(network.valid_host(value), "invalid manual appliance IPv4 address")
    return value
  end
end

-- 생성 요청 직후의 캐시와 실제 기기의 영구 필드를 함께 갱신합니다. IP는 식별자가 아닙니다.
function M.remember_host(driver, identity, address, refresh)
  assert(network.valid_host(address), "invalid discovered appliance IPv4 address")
  driver.ac_hosts = driver.ac_hosts or {}
  driver.ac_hosts[identity] = address
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == "samsung-ac-ocf:" .. identity then
      local changed = device:get_field("ocf_host") ~= address
      device:set_field("ocf_host", address, { persist = true })
      if changed and refresh then M.request(driver, device) end
    end
  end
end

local function relocate(driver, device, context)
  local identity = assert(device:get_field("ocf_identity"), "missing bound appliance identity")
  local results = network.scan(socket, context, nil, identity)
  assert(not context.cancelled, "query cancelled")
  assert(results[1], "bound appliance not found by multicast")
  M.remember_host(driver, identity, results[1].host, false)
  return results[1].host
end

-- 저장한 주소가 더 이상 유효하지 않으면 같은 OCF ID만 다시 찾고 GET을 재시도합니다.
-- 설정 명령의 재전송은 이 경로에서 하지 않습니다.
local function query(driver, device, context, command)
  local manual = manual_host(device)
  local identity = device:get_field("ocf_identity")
  local address = manual or (driver.ac_hosts or {})[identity] or device:get_field("ocf_host")
  local cached = address ~= nil
  local socket_api = socket
  local hub_host = driver.environment_info and driver.environment_info.hub_ipv4
  context.keep_connection = hub_host ~= nil
  if hub_host then socket_api = tls_bridge.socket_api(socket, cosock.spawn, hub_host, context) end
  context.phase = nil
  if not address then address = relocate(driver, device, context) end
  local function phase(name) context.phase = name; log.info("AC_PHASE " .. name) end
  if command then return network.control(socket_api, ssl, config, address, identity, context, phase, command) end
  local ok, state, actual_identity = pcall(network.read, socket_api, ssl, config, address, identity, context, phase)
  if ok then return state, actual_identity end
  if not context.cancelled and not manual and cached and (context.phase == "udp-discovery" or context.phase == "tcp-connect") then
    local next_address = relocate(driver, device, context)
    if next_address ~= address then return network.read(socket_api, ssl, config, next_address, identity, context, phase) end
  end
  error(state, 0)
end

-- 배열·범위·단위까지 비교합니다. 관측값을 문자열로 바꿔 동일성을 판단하지 않습니다.
local function equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

local function publish(device, state, force)
  local context = assert(device:get_field(FIELD), "query context unavailable")
  context.published = context.published or {}
  local emitted, available = 0, 0
  local function emit(event, component)
    available = available + 1
    local key = (component or "main") .. ":" .. event.capability.ID .. ":" .. event.attribute.NAME
    local previous = context.published[key]
    local now = socket.gettime()
    if not force and previous and equal(previous.value, event.value) and now - previous.at < 300 then return end
    -- 장비 이벤트 한도에 여유를 두고 최대 초당 4개로 보냅니다. 초기 전체 상태도 순서대로 전달합니다.
    local delay = context.last_event_at and 0.25 - (now - context.last_event_at) or 0
    if delay > 0 then socket.sleep(delay) end
    assert(not context.cancelled and device:get_field(FIELD) == context, "event publication cancelled")
    -- SDK의 main emit_event 래퍼는 반환값을 버립니다. 결과를 돌려주는 component 메서드를 사용합니다.
    local result, failure = device:emit_component_event(device.profile.components[component or "main"], event)
    assert(result and not failure, "capability event send failed")
    -- 이벤트 객체는 이후 변경하지 않습니다. 새 조회는 새 객체를 만들어 이전 값과 비교합니다.
    context.last_event_at = socket.gettime()
    context.published[key] = { value = event.value, at = context.last_event_at }
    emitted = emitted + 1
  end
  if state.power ~= nil then emit(caps.switch.switch(state.power and "on" or "off")) end
  if state.temperature ~= nil and state.unit then
    emit(caps.temperatureMeasurement.temperature({ value = state.temperature, unit = state.unit }))
  end
  if state.humidity ~= nil then
    emit(caps.relativeHumidityMeasurement.humidity(state.humidity))
  end
  local unit = state.desiredUnit or state.unit
  if state.desired ~= nil and unit then
    emit(caps.thermostatCoolingSetpoint.coolingSetpoint({ value = state.desired, unit = unit }))
  end
  if unit and state.minimum and state.maximum and state.minimum <= state.maximum then
    emit(caps.thermostatCoolingSetpoint.coolingSetpointRange({
      value = { minimum = state.minimum, maximum = state.maximum, step = state.step }, unit = unit }))
  end
  if state.supportedModes and #state.supportedModes > 0 then
    -- 냉방·제습과 추가 청정 선택을 UI에서 분리합니다. 원시 조합 모드는 제어 계층에 남깁니다.
    local modes, seen = {}, {}
    for _, mode in ipairs(state.supportedModes) do
      mode = BASE_MODES[mode] or mode
      if not seen[mode] then modes[#modes + 1], seen[mode] = mode, true end
    end
    emit(caps.airConditionerMode.supportedAcModes(modes))
    emit(caps.airConditionerMode.availableAcModes(modes))
  end
  if state.acMode then emit(caps.airConditionerMode.airConditionerMode(BASE_MODES[state.acMode] or state.acMode)) end
  if state.supportedFans then
    emit(caps.airConditionerFanMode.supportedAcFanModes(state.supportedFans))
    emit(caps.airConditionerFanMode.availableAcFanModes(state.supportedFans))
  end
  if state.fanMode then emit(caps.airConditionerFanMode.fanMode(state.fanMode)) end
  if state.windfree ~= nil then emit(caps.switch.switch(state.windfree and "on" or "off"), "windfree") end
  if state.autoclean ~= nil then emit(caps.switch.switch(state.autoclean and "on" or "off"), "autoclean") end
  -- 프로필 갱신 중인 기존 기기는 새 component가 도착한 뒤 infoChanged에서 다시 발행합니다.
  if state.purify ~= nil and device.profile.components.purify then
    emit(caps.switch.switch(state.purify and "on" or "off"), "purify")
  end
  for kind, component in pairs({ doorUpper = "doorupper", doorLower = "doorlower", speed = "speed", quiet = "quiet", displayOff = "displayoff" }) do
    if state[kind] ~= nil and device.profile.components[component] then
      emit(caps.switch.switch(state[kind] and "on" or "off"), component)
    end
  end
  if state.panel and device.profile.components.panel and device:supports_capability(caps.doorControl, "panel") then
    local event = caps.doorControl.door(state.panel)
    -- 재동기화 때도 오래된 패널 표시가 남지 않도록 값 비교를 통과한 이벤트를 명시적 변경으로 보냅니다.
    event.state_change = true
    emit(event, "panel")
  end
  -- 갱신 전 프로필에는 새 센서가 없을 수 있으므로 capability가 도착한 뒤부터 발행합니다.
  if device:supports_capability(caps.dustSensor) then
    if state.pm10 ~= nil then emit(caps.dustSensor.dustLevel({ value = state.pm10, unit = "μg/m^3" })) end
    if state.pm25 ~= nil then emit(caps.dustSensor.fineDustLevel({ value = state.pm25, unit = "μg/m^3" })) end
  end
  if state.pm1 ~= nil and device:supports_capability(caps.veryFineDustSensor) then
    emit(caps.veryFineDustSensor.veryFineDustLevel({ value = state.pm1, unit = "μg/m^3" }))
  end
  if state.gasLevel ~= nil and device:supports_capability(caps.odorSensor) then emit(caps.odorSensor.odorLevel(state.gasLevel)) end
  if state.airQualityConcern and device:supports_capability(caps.airQualityHealthConcern) then
    emit(caps.airQualityHealthConcern.supportedAirQualityValues({ "unknown", "good" }))
    emit(caps.airQualityHealthConcern.airQualityHealthConcern(state.airQualityConcern))
  end
  if device:supports_capability(reservation) then
    local timers = reservations.snapshot(device)
    for kind, attribute in pairs({ onTimer = "onDelay", offTimer = "offDelay" }) do
      local event = reservation[attribute](timers[kind] == 0 and "none" or tostring(timers[kind]))
      event.state_change = true
      emit(event)
    end
  end
  -- 본체의 GET 결과만 발행합니다. 누락은 예약 없음과 구분하고 허브 예약 갱신에서는 건드리지 않습니다.
  if next(state) and device:supports_capability(native_reservation) then
    for kind, attribute in pairs({ onTimer = "onDelay", offTimer = "offDelay" }) do
      local units = state[kind]
      local value = units == nil and "unknown" or (units == 0 and "none" or string.format("%d", units))
      local event = native_reservation[attribute](value)
      event.state_change = true
      emit(event)
    end
  end
  if device:supports_capability(settings) then
    for kind, attribute in pairs({ lighting = "lighting", voice = "voice" }) do
      if state[kind] then
        local event = settings[attribute](state[kind])
        -- 허브가 읽은 효과음과 클라우드의 음소거 값이 달랐습니다. 재동기화도 변경 이벤트로 전달합니다.
        -- 위의 값 비교·300초 간격을 통과한 이벤트만 발행하므로 5초마다 강제 발행하지 않습니다.
        event.state_change = true
        emit(event)
      end
    end
  end
  -- 예약만 갱신하는 빈 상태로 메뉴를 덮어쓰지 않습니다. 새 프로필이 전달된 후부터 발행합니다.
  if next(state) then
    local menus = { ac.menu_state(state) }
    for index, capability in ipairs(menu_caps) do
      if device:supports_capability(capability) then
        for attribute, value in pairs(menus[index]) do
          local event = capability[attribute](value)
          event.state_change = true
          emit(event)
        end
      end
    end
  end
  assert(available > 0, "no verified AC state available to publish")
  if next(state) then log.info("AC_STATE " .. json.encode(state))
  else log.info("AC_LOCAL_RESERVATIONS " .. json.encode(reservations.snapshot(device))) end
  log.info("AC_EVENTS_QUEUED " .. tostring(emitted))
end

-- 하나의 cosock 작업만 소켓을 소유합니다. POST 오류 뒤에는 GET만 예약하며 명령은 재전송하지 않습니다.
local function schedule(driver, device)
  local context = device:get_field(FIELD)
  if not context or context.cancelled then return end
  if context.busy then return end
  context.busy = true
  cosock.spawn(function()
    if context.cancelled then context.busy = false; return end
    while not context.cancelled do
      local command
      if not context.recovery then command = table.remove(context.commands, 1) end
      local local_only = not command and context.local_refresh
      if not command and not context.refresh and not local_only then break end
      if local_only then context.local_refresh = false else context.refresh = false end
      context.recovery = false
      local force_publish = not local_only and context.force_publish
      if not local_only then context.force_publish = false end
      context.write_attempted, context.write_rejected, context.command_rejected, context.verified_state = false, false, false, nil
      local ok, failure = pcall(function()
        -- 예약 설정·취소는 LAN 조회 없이도 UI에 반영합니다. 센서 이벤트나 ONLINE 상태는 만들지 않습니다.
        if local_only then publish(device, {}); return end
        local state, identity, outcome = query(driver, device, context, command)
        if context.cancelled or device:get_field(FIELD) ~= context then return end
        if not device:get_field("ocf_identity") then device:set_field("ocf_identity", identity, { persist = true }) end
        publish(device, state, force_publish)
        device:online()
        if command then
          log.info("AC_COMMAND_" .. string.upper(outcome) .. " " .. command.kind)
        else log.info("AC_QUERY_OK") end
      end)
      if not ok and not context.cancelled then
        if local_only then log.error("AC_EVENT_FAILED " .. tostring(failure))
        elseif command and (context.command_rejected or context.write_rejected) and context.verified_state then
          -- 지원 범위 또는 기기의 명시적 POST 거부는 통신 성공이므로 오프라인으로 바꾸지 않습니다.
          local published, event_error = pcall(publish, device, context.verified_state)
          if published then device:online() else log.error("AC_EVENT_FAILED " .. tostring(event_error)) end
          log.error("AC_COMMAND_REJECTED " .. tostring(failure))
        else
          device:offline()
          local label = "AC_QUERY_FAILED"
          if command then
            label = context.write_attempted and (context.write_rejected and "AC_COMMAND_REJECTED" or "AC_COMMAND_UNCERTAIN") or "AC_COMMAND_FAILED"
            context.refresh, context.recovery = true, true
          end
          log.error(label .. " " .. tostring(failure))
        end
      end
    end
    context.busy = false
  end, "samsung-ac-local-worker")
end

local function reservation_changed(driver, device)
  local context = device:get_field(FIELD)
  if not context or context.cancelled then return end
  context.local_refresh = true
  schedule(driver, device)
end

function M.reservation(driver, device, kind, units)
  local ok, failure = pcall(reservations.set, driver, device, kind, units)
  if not ok then log.error("AC_RESERVATION_REJECTED " .. tostring(failure)) end
  return ok
end

function M.request(driver, device, manual)
  local context = device:get_field(FIELD)
  if not context or context.cancelled then return end
  context.refresh = true
  if manual == true or type(manual) == "table" then context.force_publish = true end
  schedule(driver, device)
end

function M.command(driver, device, command)
  local ok, failure = pcall(ac.validate, command)
  if not ok then log.error("AC_COMMAND_REJECTED " .. tostring(failure)); return false end
  local context = device:get_field(FIELD)
  if not context or context.cancelled then return false end
  -- 입력 폭주 때 메모리와 오래된 명령이 쌓이지 않도록 초과 요청을 명시적으로 거부합니다.
  if #context.commands >= 32 then log.error("AC_COMMAND_REJECTED command queue full"); return false end
  context.commands[#context.commands + 1] = { kind = command.kind, value = command.value }
  schedule(driver, device)
  return true
end

function M.stop(driver, device)
  reservations.stop(driver, device)
  local context = device:get_field(FIELD)
  if not context then return end
  context.cancelled = true
  if context.timer then driver:cancel_timer(context.timer) end
  network.close(context)
  device:set_field(FIELD, nil)
end

function M.start(driver, device)
  M.stop(driver, device)
  local context = { busy = false, cancelled = false, commands = {} }
  device:set_field(FIELD, context)
  reservations.start(driver, device, M.command, reservation_changed)
  -- 탐색 당시의 OCF ID를 최초 설정부터 고정합니다. IP 변경으로 다른 에어컨을 제어하지 않습니다.
  local identity = (device.device_network_id or ""):match("^samsung%-ac%-ocf:(.+)$")
  if identity and not device:get_field("ocf_identity") then device:set_field("ocf_identity", identity, { persist = true }) end
  local address = identity and (driver.ac_hosts or {})[identity]
  if address then device:set_field("ocf_host", address, { persist = true }) end
  if device.preferences and device.preferences.enablePolling == true then
    -- 새 설정은 기존 60초 기본값과 구분해, 기존 기기에도 요청한 10초 갱신을 적용합니다.
    local interval = tonumber(device.preferences.refreshSeconds) or 10
    assert(interval >= 5 and interval <= 900, "poll interval outside profile range")
    context.timer = driver:call_on_schedule(interval, function() M.request(driver, device) end, "ac-poll")
  end
  M.request(driver, device)
end

return M
