-- 장비 식별 정보와 원문을 제외한 상태만 추출합니다. kWh 환산은 하지 않습니다.
local M = {}
local P = "x.com.samsung.da."
-- 실제 AI 선택은 ComfortAICooling 옵션이며 기본 모드 Auto/Cool과 독립적입니다.
-- Gear POST는 본인 장비가 4.00으로 거부했습니다. HOMECARE_WIZARD_V2도 운전 모드가 아닙니다.
local MODES = { Auto = "auto", Cool = "cool", Dry = "dry", Wind = "wind", CoolClean = "coolClean", DryClean = "dryClean" }
-- 이 보드의 legacy airflow에는 지원 목록이 없어 공개 구현의 0..4 대응을 사용합니다.
local FANS = { [0] = "auto", [1] = "low", [2] = "medium", [3] = "high", [4] = "turbo" }
-- 본인 삼성 앱의 단계 선택과 로컬 GET을 대조한 값입니다. 다른 보드의 Light 반전 규칙은 적용하지 않습니다.
local LIGHTS = { Off = "off", Small = "low", On = "medium", Huge = "high" }
local VOICES = { ["33"] = "low", ["66"] = "medium", ["100"] = "high", Melody = "melody", Mute = "mute" }
local NATIVE_TIMERS = { nativeOnTimer = "onTimer", nativeOffTimer = "offTimer" }

local function contains(values, value)
  for _, entry in ipairs(values or {}) do if entry == value then return true end end
  return false
end

local function base_mode(mode)
  if mode == "coolClean" then return "cool" end
  if mode == "dryClean" then return "dry" end
  return mode
end

local OUTLETS = { closed = 0, upper = 1, lower = 2, both = 3 }

-- 화면의 활성 조건과 실제 명령 검사를 같은 상태에서 계산합니다.
-- 본체 응답이 빠졌으면 활성화하지 않으며, 앱의 마지막 표시값으로 허용하지 않습니다.
function M.available(kind, state)
  local mode = base_mode(state.acMode)
  if kind == "windfree" then
    local sleep = M.number(state.sleepRaw)
    return state.power == true and state.ai == false and contains({ "cool", "dry", "wind" }, mode)
      and state.windfree ~= nil and sleep ~= nil and sleep >= 0
  elseif kind == "preset" then
    return state.power == true and state.ai == false and mode == "cool" and state.speed ~= nil and state.quiet ~= nil
      and not contains({ "Sleep", "NanoSleep" }, state.windfreeRaw)
  elseif kind == "purify" then
    return state.ai == false and contains({ "cool", "dry" }, mode) and state.purify ~= nil
  elseif kind == "setpoint" then
    return state.ai == false and mode ~= nil and mode ~= "wind" and state.setpointPath ~= nil
  elseif kind == "fan" then
    return state.ai == false and state.fanMode ~= nil
  elseif kind == "panel" then
    return state.power == false and state.panel ~= nil
  end
  return false
end

-- 묶음 메뉴는 기존 상태의 다른 표현입니다. 원래 스위치와 자동화 이벤트는 계속 유지합니다.
function M.menu_state(state)
  local comfort, settings, care, operation = {}, {}, {}, {}
  if state.windfree ~= nil then comfort.windfree = state.windfree and "on" or "off" end
  if state.purify ~= nil then comfort.purify = state.purify and "on" or "off" end
  local presets = { Off = "normal", Nano = "normal", Speed = "speed", Quiet = "quiet",
    Sleep = "sleep", NanoSleep = "sleep", Comfort = "other", ["2Step"] = "other" }
  comfort.preset = presets[state.windfreeRaw]
  for name, bits in pairs(OUTLETS) do if M.number(state.bloomingRaw) == bits then comfort.outlet = name end end
  for _, kind in ipairs({ "windfree", "preset", "purify", "setpoint", "fan" }) do
    comfort[kind .. "Enabled"] = M.available(kind, state) and "enabled" or "disabled"
  end
  settings.lighting, settings.voice = state.lighting, state.voice
  if state.displayOff ~= nil then settings.display = state.displayOff and "off" or "on" end
  if state.autoclean ~= nil then care.autoclean = state.autoclean and "on" or "off" end
  care.panel = state.panel
  care.panelEnabled = M.available("panel", state) and "enabled" or "disabled"
  operation.mode, operation.fan = base_mode(state.acMode), state.fanMode
  local unit = state.desiredUnit or state.unit
  if state.desired ~= nil and unit then operation.setpoint = { value = state.desired, unit = unit } end
  -- 화면의 활성 조건은 해당 capability의 속성을 조회하므로 각 카드에도 같은 관측값을 제공합니다.
  local operating = { mode = operation.mode, fan = operation.fan, fanEnabled = comfort.fanEnabled }
  local temperature = { setpoint = operation.setpoint, setpointEnabled = comfort.setpointEnabled }
  local air_features = { windfree = comfort.windfree, purify = comfort.purify,
    windfreeEnabled = comfort.windfreeEnabled, purifyEnabled = comfort.purifyEnabled }
  local display = { display = settings.display }
  local panel = { panel = care.panel, panelEnabled = care.panelEnabled }
  return comfort, settings, care, operation, temperature, air_features, display, panel, operating
end

-- 숫자 센서에 가짜 0이나 문자열을 넣지 않고 읽기 전용 카드의 표시값을 만듭니다.
-- 운전 전원과 별개로 AirMonitoring_On을 확인한 경우에만 현재 측정값을 표시합니다.
function M.sensor_state(state)
  local monitoring = ({ On = "on", Off = "off" })[state.monitoringRaw] or "unknown"
  local result = { monitoring = monitoring, temperature = "-", humidity = "-", airQuality = "-",
    dustLevel = "-", fineDustLevel = "-", veryFineDustLevel = "-", gas = "-" }
  if monitoring ~= "on" then return result end
  if state.temperature ~= nil and (state.unit == "C" or state.unit == "F") then
    result.temperature = string.format("%.1f °%s", state.temperature, state.unit)
  end
  if state.humidity ~= nil then result.humidity = string.format("%g %%", state.humidity) end
  if state.airQualityConcern == "good" then result.airQuality = "좋음" end
  for key, attribute in pairs({ pm10 = "dustLevel", pm25 = "fineDustLevel", pm1 = "veryFineDustLevel" }) do
    if state[key] ~= nil then result[attribute] = string.format("%d μg/m³", state[key]) end
  end
  if state.gasLevel ~= nil then result.gas = string.format("%d단계", state.gasLevel) end
  return result
end

function M.number(value)
  local result = tonumber(value)
  if result and result == result and result ~= math.huge and result ~= -math.huge then return result end
end

function M.walk(value, callback, depth)
  depth = depth or 0
  assert(depth <= 32, "OCF nesting limit")
  if type(value) ~= "table" then return end
  callback(value)
  for _, child in pairs(value) do
    if type(child) == "table" then M.walk(child, callback, depth + 1) end
  end
end

function M.resources(batch)
  local result = {}
  M.walk(batch, function(entry)
    if type(entry.href) == "string" and type(entry.rep) == "table" then result[entry.href] = entry.rep end
  end)
  return result
end

local function bounded(value, low, high)
  local n = M.number(value)
  if n and n >= low and n <= high then return n end
end

function M.summary(batch)
  local resources, result = M.resources(batch), {}
  local current, desired = resources["/temperature/current/0"] or {}, resources["/temperature/desired/0"] or {}
  local temperatures = resources["/temperatures/vs/0"] or {}
  local items = temperatures[P .. "items"]
  local legacy = type(items) == "table" and items[1] or {}
  if type(legacy) ~= "table" then legacy = {} end
  result.temperature = bounded(current.temperature, -60, 100) or bounded(legacy[P .. "current"], -60, 100)
  result.desired = bounded(desired.temperature, -60, 100) or bounded(legacy[P .. "desired"], -60, 100)
  local unit = current.units or desired.units or legacy[P .. "unit"]
  if unit == "C" or unit == "Celsius" then result.unit = "C"
  elseif unit == "F" or unit == "Fahrenheit" then result.unit = "F" end
  local desired_unit = desired.units or legacy[P .. "unit"]
  if desired_unit == "C" or desired_unit == "Celsius" then result.desiredUnit = "C"
  elseif desired_unit == "F" or desired_unit == "Fahrenheit" then result.desiredUnit = "F" end
  local range = type(desired.range) == "table" and desired.range or {}
  result.minimum = M.number(range[1]) or M.number(legacy[P .. "minimum"])
  result.maximum = M.number(range[2]) or M.number(legacy[P .. "maximum"])
  local control = resources["/temperature/control/vs/0"] or {}
  local step = M.number(control.increment or control[P .. "increment"] or legacy[P .. "increment"])
  result.step = step and step > 0 and step or 1
  result.setpointPath = desired.temperature ~= nil and "/temperature/desired/0" or nil
  local humidity = resources["/humidity/vs/0"] or {}
  if humidity[P .. "fivepercentHumidity"] ~= nil then
    result.humidity = bounded(humidity[P .. "fivepercentHumidity"], 0, 100)
  else
    local n = bounded(humidity[P .. "humidity"], 0, 100)
    if n and n > 0 then result.humidity = n end
  end
  local power = resources["/power/0"] or {}
  local vendor_power = (resources["/power/vs/0"] or {})[P .. "power"]
  result.powerResourceAvailable = vendor_power == "On" or vendor_power == "Off"
  if type(power.value) == "boolean" then result.power = power.value
  else
    if vendor_power == "On" then result.power = true elseif vendor_power == "Off" then result.power = false end
  end
  local mode = resources["/mode/vs/0"] or {}
  local modes = mode[P .. "modes"]
  if type(modes) == "table" and type(modes[1]) == "string" then result.mode = modes[1] end
  result.acMode = MODES[result.mode]
  -- 이 스위치는 냉방·제습에 추가하는 청정 선택입니다. 청정 단독·자동 운전과 구분합니다.
  if result.mode == "CoolClean" or result.mode == "DryClean" then result.purify = true
  elseif MODES[result.mode] then result.purify = false end
  result.supportedModes = {}
  for _, raw in ipairs(type(mode[P .. "supportedModes"]) == "table" and mode[P .. "supportedModes"] or {}) do
    if MODES[raw] and not contains(result.supportedModes, MODES[raw]) then
      result.supportedModes[#result.supportedModes + 1] = MODES[raw]
    end
  end
  local airflow = resources["/airflow/vs/0"] or {}
  result.fan = M.number(airflow[P .. "speedLevel"])
  result.fanMode = FANS[result.fan]
  if result.fanMode then result.supportedFans = { "auto", "low", "medium", "high", "turbo" } end
  if type(airflow[P .. "direction"]) == "string" then result.direction = airflow[P .. "direction"] end
  local energy = resources["/energy/consumption/vs/0"] or {}
  local watts = M.number(energy[P .. "instantaneousPower"])
  if watts and watts >= 0 and watts ~= 65278 then result.instantaneousPowerRaw = watts end
  local counter = energy[P .. "cumulativePower"]
  if type(counter) == "string" and counter:match("^%d+$") then result.energyCounterRaw = counter end
  local sensors = (resources["/sensors/vs/0"] or {})[P .. "items"]
  local names = { Dust = "dustRaw", FineDust = "fineDustRaw", SuperFineDust = "superFineDustRaw",
    CleanLevel = "cleanLevelRaw", Odor = "odorRaw", CO2 = "co2Raw" }
  if type(sensors) == "table" then
    for _, sensor in ipairs(sensors) do
      if type(sensor) == "table" then
        local name, values = names[sensor[P .. "type"]], sensor[P .. "value"]
        if name and type(values) == "table" then result[name] = M.number(values[1]) end
      end
    end
  end
  -- 본인 기기의 삼성 화면·capability와 대조한 PM 단위는 μg/m³, GAS 원시 0은 1단계입니다.
  -- 청정도는 현재 실측 대조한 1=좋음만 확정하고 다른 코드를 임의의 건강 등급으로 바꾸지 않습니다.
  for raw, target in pairs({ dustRaw = "pm10", fineDustRaw = "pm25", superFineDustRaw = "pm1" }) do
    local value = result[raw]
    if value and value >= 0 and value % 1 == 0 then result[target] = value end
  end
  if result.odorRaw and result.odorRaw >= 0 and result.odorRaw <= 3 and result.odorRaw % 1 == 0 then
    result.gasLevel = result.odorRaw + 1
  end
  if result.cleanLevelRaw ~= nil then result.airQualityConcern = result.cleanLevelRaw == 1 and "good" or "unknown" end
  local options = mode[P .. "options"]
  local prefixes = { Comode = "windfreeRaw", Sleep = "sleepRaw", Autoclean = "autocleanRaw",
    AI = "aiSupportRaw", ComfortAICooling = "aiSettingRaw", ArtificialWorking = "aiWorkingRaw",
    AutocleanProgress = "autocleanProgressRaw", StopAutoClean = "autocleanStopRaw",
    AirMonitoring = "monitoringRaw", PM1Progress = "filterProgressRaw", Blooming = "bloomingRaw",
    OnTimer = "onTimerRaw", OffTimer = "offTimerRaw", Light = "lightingRaw", Volume = "voiceRaw", Display = "displayRaw", Panel = "panelRaw" }
  if type(options) == "table" then
    for _, option in ipairs(options) do
      if type(option) == "string" then
        local prefix, value = option:match("^(%w+)_(%w+)$")
        if prefixes[prefix] then result[prefixes[prefix]] = value end
      end
    end
  end
  if result.windfreeRaw == "Nano" or result.windfreeRaw == "NanoSleep" then result.windfree = true
  elseif contains({ "Off", "Sleep", "Quiet", "Comfort", "2Step", "Speed" }, result.windfreeRaw) then result.windfree = false end
  if contains({ "Off", "Nano", "NanoSleep", "Sleep", "Quiet", "Comfort", "2Step", "Speed" }, result.windfreeRaw) then
    result.speed, result.quiet = result.windfreeRaw == "Speed", result.windfreeRaw == "Quiet"
  end
  result.lighting, result.voice = LIGHTS[result.lightingRaw], VOICES[result.voiceRaw]
  -- 운전 중 상·하 선택(Blooming)과 청소용 패널 열림(Panel)은 별개입니다.
  if result.panelRaw == "Open" then result.panel = "open"
  elseif result.panelRaw == "Close" then result.panel = "closed" end
  if result.displayRaw == "On" then result.displayOff = true
  elseif result.displayRaw == "Off" then result.displayOff = false end
  if result.autocleanRaw == "On" then result.autoclean = true
  elseif result.autocleanRaw == "Off" then result.autoclean = false end
  if result.aiSettingRaw == "On" then result.ai = true
  elseif result.aiSettingRaw == "Off" then result.ai = false end
  result.aiAvailable = result.aiSupportRaw == "Enable" and result.ai ~= nil
  if result.aiAvailable then result.supportedModes[#result.supportedModes + 1] = "aIComfort" end
  -- AI가 기본 모드를 스스로 바꾸어도 UI는 선택한 AI 운전을 계속 표시합니다.
  if result.ai then result.acMode = "aIComfort" end
  local doors = M.number(result.bloomingRaw)
  if doors and doors >= 0 and doors <= 3 and doors % 1 == 0 then
    result.doorUpper, result.doorLower = (doors & 1) ~= 0, (doors & 2) ~= 0
  end
  -- 본체에서 읽은 예약만 기록합니다. 허브 예약의 남은 시간으로 대체하지 않습니다.
  for _, kind in ipairs({ "onTimer", "offTimer" }) do
    local units = M.number(result[kind .. "Raw"])
    if units and units >= 0 and units <= 48 and units % 1 == 0 then result[kind] = units end
  end
  -- 진행률 1·Idle은 사용 설정의 On/Off와 다릅니다. 진행률로 설정을 덮어쓰지 않습니다.
  result.autocleanProgress = bounded(result.autocleanProgressRaw, 0, 100)
  assert(result.temperature ~= nil or result.humidity ~= nil or result.power ~= nil, "no recognized AC state")
  return result
end

-- UI/API 입력을 정해진 명령으로 제한합니다. 장비별 범위 검사는 새 GET 뒤에 수행합니다.
function M.validate(command)
  assert(type(command) == "table", "missing AC command")
  local kind, value = command.kind, command.value
  if contains({ "power", "windfree", "autoclean", "purify", "doorUpper", "doorLower", "speed", "quiet", "displayOff" }, kind) then
    assert(type(value) == "boolean", "switch value must be boolean")
  elseif NATIVE_TIMERS[kind] then
    -- 0 전송 직후 전원 켜짐이 관측됐습니다. 확인된 30분 단위의 양수 설정만 허용합니다.
    assert(type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 48,
      "기기 예약은 30분~24시간만 설정할 수 있습니다. 취소는 본체나 리모컨에서 해 주세요")
  elseif kind == "lighting" or kind == "voice" then
    local known = false
    for _, setting in pairs(kind == "lighting" and LIGHTS or VOICES) do if setting == value then known = true end end
    assert(known, "unsupported appliance setting")
  elseif kind == "panel" then
    assert(value == "open" or value == "closed", "unsupported panel position")
  elseif kind == "outlet" then
    assert(OUTLETS[value] ~= nil, "unsupported air outlet position")
  elseif kind == "preset" then
    assert(contains({ "normal", "speed", "quiet" }, value), "unsupported operating preset")
  elseif kind == "setpoint" then
    assert(type(value) == "number" and M.number(value), "setpoint must be a finite number")
  elseif kind == "mode" then
    local known = value == "aIComfort"
    for _, mode in pairs(MODES) do if value == mode then known = true end end
    assert(known, "unsupported AC mode")
  elseif kind == "fan" then
    local known = false
    for _, fan in pairs(FANS) do if value == fan then known = true end end
    assert(known, "unsupported fan mode")
  else error("unsupported AC command") end
end

function M.matches(command, state)
  local kind, value = command.kind, command.value
  if NATIVE_TIMERS[kind] then return state[NATIVE_TIMERS[kind]] == value end
  if kind == "power" then return state.power == value end
  if kind == "mode" then
    if value == "aIComfort" then return state.ai == true end
    if state.ai then return false end
    if value == "cool" or value == "dry" then return base_mode(state.acMode) == value end
    return state.acMode == value
  end
  if kind == "fan" then return state.fanMode == value end
  if kind == "setpoint" then return state.desired ~= nil and math.abs(state.desired - value) < 0.001 end
  if kind == "windfree" then return state.windfree == value end
  if kind == "autoclean" then return state.autocleanRaw == (value and "On" or "Off") end
  if kind == "purify" then return state.purify == value end
  if kind == "doorUpper" or kind == "doorLower" then return state[kind] == value end
  if kind == "panel" then return state.panel == value and state.power == false end
  if kind == "outlet" then return M.number(state.bloomingRaw) == OUTLETS[value] end
  if kind == "preset" then
    if value == "normal" then return contains({ "Off", "Nano" }, state.windfreeRaw) end
    return state[value] == true
  end
  if contains({ "speed", "quiet", "lighting", "voice", "displayOff" }, kind) then return state[kind] == value end
  return false
end

-- 같은 상태는 전송하지 않습니다. 상대시간 예약은 재설정 의미가 있어 같은 값도 한 번 전송합니다.
function M.plan(command, state)
  M.validate(command)
  local kind, value = command.kind, command.value
  local path, body
  if state.ai and contains({ "setpoint", "fan", "windfree", "purify", "speed", "quiet", "preset" }, kind) then
    error("인공지능 쾌적에서는 스마트쾌적·냉방·제습으로 전환한 뒤 수동 설정해 주세요")
  end
  if NATIVE_TIMERS[kind] then
    local timer = NATIVE_TIMERS[kind]
    assert(state[timer] ~= nil, "기기의 예약 상태를 확인할 수 없어 설정하지 않았습니다")
    local token = kind == "nativeOnTimer" and "OnTimer_" or "OffTimer_"
    -- 시간 옵션 하나만 설정합니다. 전원·반대 예약·허브 예약을 취소하거나 함께 쓰지 않습니다.
    -- 재설정을 동등 상태로 생략하면 이전 예약이 계속되므로 matches 검사를 건너뜁니다.
    return { path = "/mode/vs/0", body = { [P .. "options"] = { token .. string.format("%d", value) } },
      -- 같은 값의 GET만으로 시작 시각이 갱신됐는지는 알 수 없습니다.
      readback_ambiguous = state[timer] == value }
  elseif kind == "power" then
    assert(state.powerResourceAvailable, "vendor power resource unavailable")
    path, body = "/power/vs/0", { [P .. "power"] = value and "On" or "Off" }
  elseif kind == "mode" then
    if value == "aIComfort" then
      assert(state.aiAvailable and contains(state.supportedModes, value), "AI comfort option unavailable")
      path, body = "/mode/vs/0", { [P .. "options"] = { "ComfortAICooling_On" } }
      if M.matches(command, state) then return nil end
      return { path = path, body = body }
    end
    local target = value
    -- 선택형 청정이 켜진 냉방·제습 사이에서는 청정 설정을 유지합니다.
    if state.mode == "CoolClean" or state.mode == "DryClean" then
      if value == "cool" then target = "coolClean" elseif value == "dry" then target = "dryClean" end
    end
    assert(contains(state.supportedModes, target), "mode not advertised by appliance")
    for raw, mode in pairs(MODES) do if target == mode then body = { [P .. "modes"] = { raw } } end end
    -- AI 종료와 요청한 일반 모드는 같은 명령으로 바꿉니다. 다른 옵션은 덮어쓰지 않습니다.
    if state.ai then body[P .. "options"] = { "ComfortAICooling_Off" } end
    path = "/mode/vs/0"
  elseif kind == "purify" then
    if M.matches(command, state) then return nil end
    local mode = base_mode(state.acMode)
    assert(mode == "cool" or mode == "dry", "청정 On/Off는 냉방 또는 제습 모드에서 설정해 주세요")
    local target = value and (mode == "cool" and "coolClean" or "dryClean") or mode
    assert(contains(state.supportedModes, target), "purification mode not advertised by appliance")
    for raw, mapped in pairs(MODES) do if target == mapped then body = { [P .. "modes"] = { raw } } end end
    path = "/mode/vs/0"
  elseif kind == "panel" then
    assert(state.power == false, "바람문(패널) 열림은 에어컨 전원이 꺼진 상태에서 사용해 주세요")
    assert(state.panel ~= nil, "panel state unavailable")
    -- 패널 옵션 하나만 보냅니다. 청소 기능을 위해 전원을 자동으로 바꾸지 않습니다.
    path, body = "/mode/vs/0", { [P .. "options"] = { value == "open" and "Panel_Open" or "Panel_Close" } }
  elseif kind == "outlet" then
    local doors = M.number(state.bloomingRaw)
    assert(doors and doors >= 0 and doors <= 3 and doors % 1 == 0, "air outlet state unavailable")
    -- 네 가지 위치를 한 번의 POST로 지정합니다. 두 스위치를 연속 조작하는 중간 상태를 만들지 않습니다.
    path, body = "/mode/vs/0", { [P .. "options"] = { "Blooming_" .. OUTLETS[value] } }
  elseif kind == "doorUpper" or kind == "doorLower" then
    local doors = M.number(state.bloomingRaw)
    assert(doors and doors >= 0 and doors <= 3 and doors % 1 == 0, "air outlet state unavailable")
    -- 상단만 열림=1과 양쪽 열림=3을 실기 대조했습니다. 다른 바람문의 비트는 보존합니다.
    local bit = kind == "doorUpper" and 1 or 2
    doors = value and (doors | bit) or (doors & ~bit)
    path, body = "/mode/vs/0", { [P .. "options"] = { "Blooming_" .. doors } }
  elseif kind == "lighting" or kind == "voice" then
    assert(state[kind] ~= nil, "appliance setting unavailable")
    local token
    for raw, setting in pairs(kind == "lighting" and LIGHTS or VOICES) do if setting == value then token = raw end end
    local prefix = kind == "lighting" and "Light_" or "Volume_"
    path, body = "/mode/vs/0", { [P .. "options"] = { prefix .. token } }
  elseif kind == "displayOff" then
    assert(state.displayOff ~= nil, "display setting unavailable")
    path, body = "/mode/vs/0", { [P .. "options"] = { "Display_" .. (value and "On" or "Off") } }
  elseif kind == "preset" then
    assert(M.available("preset", state), "운전 옵션은 냉방 운전 중에 설정해 주세요. 열대야 쾌면 중에는 변경할 수 없습니다")
    if M.matches(command, state) then return nil end
    -- 일반은 스피드·정음만 해제합니다. 별도 토글로 켠 무풍을 함께 끄지 않습니다.
    assert(value ~= "normal" or state.speed or state.quiet, "현재 운전 옵션은 기존 삼성 앱에서 변경해 주세요")
    local token = ({ normal = "Off", speed = "Speed", quiet = "Quiet" })[value]
    path, body = "/mode/vs/0", { [P .. "options"] = { "Comode_" .. token } }
  elseif kind == "speed" or kind == "quiet" then
    assert(state[kind] ~= nil, "convenience preset unavailable")
    if M.matches(command, state) then return nil end
    if value then
      assert(M.available("preset", state), "스피드·정음은 냉방 운전 중에 설정해 주세요. 열대야 쾌면 중에는 변경할 수 없습니다")
    end
    -- 무풍·스피드·정음은 같은 Comode 슬롯입니다. 다른 프리셋에 대한 Off는 위에서 전송을 생략합니다.
    local token = value and (kind == "speed" and "Speed" or "Quiet") or "Off"
    path, body = "/mode/vs/0", { [P .. "options"] = { "Comode_" .. token } }
  elseif kind == "setpoint" then
    assert(state.setpointPath and state.desiredUnit, "setpoint resource or unit unavailable")
    assert(state.minimum and state.maximum and state.minimum <= state.maximum, "setpoint range unavailable")
    assert(value >= state.minimum and value <= state.maximum, "setpoint outside appliance range")
    local steps = (value - state.minimum) / state.step
    assert(math.abs(steps - math.floor(steps + 0.5)) < 0.001, "setpoint does not match appliance step")
    path, body = state.setpointPath, { temperature = value }
  elseif kind == "fan" then
    assert(contains(state.supportedFans, value), "legacy fan resource unavailable")
    for raw, fan in pairs(FANS) do if value == fan then body = { [P .. "speedLevel"] = tostring(raw) } end end
    path = "/airflow/vs/0"
  elseif kind == "autoclean" then
    assert(state.autocleanRaw == "On" or state.autocleanRaw == "Off", "autoclean option unavailable")
    path, body = "/mode/vs/0", { [P .. "options"] = { "Autoclean_" .. (value and "On" or "Off") } }
  elseif kind == "windfree" then
    assert(M.available("windfree", state), "무풍은 전원이 켜진 냉방·제습·청정에서 설정해 주세요. 인공지능 쾌적에서는 수동 설정할 수 없습니다")
    -- 무풍은 legacy Comode 슬롯을 수면과 공유합니다. 예약 시간을 바꾸는 명령은 만들지 않습니다.
    local sleep = M.number(state.sleepRaw)
    assert(sleep and sleep >= 0, "sleep duration unavailable; cannot preserve timer")
    if not value and state.windfreeRaw ~= "Nano" and state.windfreeRaw ~= "NanoSleep" then return nil end
    local token = value and (sleep > 0 and "NanoSleep" or "Nano") or (sleep > 0 and "Sleep" or "Off")
    local options = { "Comode_" .. token }
    if sleep > 0 then options[#options + 1] = "Sleep_" .. state.sleepRaw end
    path, body = "/mode/vs/0", { [P .. "options"] = options }
  end
  if M.matches(command, state) then return nil end
  return { path = path, body = body }
end

return M
