local Driver = require "st.driver"
local caps = require "st.capabilities"
local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"
local network = require "network"
local worker = require "worker"
local config = require "private_config"
local reservation = caps["instantcommon43059.samsungAcLocalTimer"]
local settings = caps["instantcommon43059.samsungAcLocalSettings"]
local comfort = caps["instantcommon43059.samsungAcLocalComfort"]
local device_settings = caps["instantcommon43059.samsungAcLocalDeviceSettings"]
local care = caps["instantcommon43059.samsungAcLocalCare"]
local operation = caps["instantcommon43059.samsungAcLocalOperation"]

-- 시작 시 한 번, 앱 검색 중에는 취소될 때까지 OCF 멀티캐스트로 지원 모델을 찾습니다.
local discovering = false
local pending = {}
local function device_identity(device)
  return (device.device_network_id or ""):match("^samsung%-ac%-ocf:(.+)$")
end

local function discover(driver, options, should_continue)
  if type(options) == "function" then should_continue = options end
  if discovering then return end
  discovering = true
  cosock.spawn(function()
    local context = {}
    local ok, failure = pcall(function()
      repeat
        local results = network.scan(socket, context, should_continue, nil, config.discovery_host)
        for _, result in ipairs(results) do
          if should_continue and not should_continue() then break end
          worker.remember_host(driver, result.identity, result.host, true)
          local exists = false
          for _, device in ipairs(driver:get_devices()) do
            if device_identity(device) == result.identity then exists = true; break end
          end
          -- 생성 요청과 lifecycle init 사이에도 같은 DNI를 반복 요청하지 않습니다.
          if not exists and (not pending[result.identity] or socket.gettime() - pending[result.identity] >= 60) then
            pending[result.identity] = socket.gettime()
            local created, create_error = pcall(function()
              local _, err = driver:try_create_device({
                type = "LAN", device_network_id = "samsung-ac-ocf:" .. result.identity, label = "Samsung AC Local",
                profile = "samsung-ac", manufacturer = result.manufacturer, model = result.model,
                vendor_provided_label = "Samsung AC Local",
              })
              assert(not err, "device creation request failed")
            end)
            if not created then pending[result.identity] = nil; error(create_error, 0) end
            socket.sleep(1)
          end
        end
        log.info("AC_DISCOVERY_OK " .. tostring(#results))
      until not should_continue or not should_continue()
    end)
    network.close(context)
    discovering = false
    if not ok then log.error("AC_DISCOVERY_FAILED " .. tostring(failure)) end
  end, "samsung-ac-local-discovery")
end

-- 같은 stock switch라도 component로 전원·무풍·자동 건조·청정을 구분합니다.
local function switch_handler(value)
  return function(driver, device, command)
    local kind = ({ main = "power", windfree = "windfree", autoclean = "autoclean", purify = "purify",
      doorupper = "doorUpper", doorlower = "doorLower", speed = "speed", quiet = "quiet", displayoff = "displayOff" })[command.component or "main"]
    if not kind then log.error("AC_COMMAND_REJECTED unknown switch component"); return end
    worker.command(driver, device, { kind = kind, value = value })
  end
end

local function setting_handler(kind, argument)
  return function(driver, device, command)
    if (command.component or "main") ~= "main" then log.error("AC_COMMAND_REJECTED wrong component"); return end
    worker.command(driver, device, { kind = kind, value = (command.args or {})[argument] })
  end
end

-- 메뉴 토글의 문자열 입력을 검증한 뒤 기존 제어 경로에 전달합니다.
-- 본체 화면 On은 기존 '화면 끄기' Off이므로 표시 메뉴에서만 방향을 바꿉니다.
local function menu_toggle_handler(kind, inverted)
  return function(driver, device, command)
    local value = (command.args or {}).setting
    if (command.component or "main") ~= "main" or (value ~= "on" and value ~= "off") then
      log.error("AC_COMMAND_REJECTED invalid menu toggle"); return
    end
    local enabled = value == "on"
    if inverted then enabled = not enabled end
    worker.command(driver, device, { kind = kind, value = enabled })
  end
end

-- 앱의 지연시간을 허브 예약에 저장합니다. 본체의 OnTimer/OffTimer 옵션은 보내지 않습니다.
local function reservation_handler(kind, cancel)
  return function(driver, device, command)
    if (command.component or "main") ~= "main" then log.error("AC_COMMAND_REJECTED wrong component"); return end
    local delay = (command.args or {}).delay
    local value = (cancel or delay == "none") and 0 or tonumber(delay)
    worker.reservation(driver, device, kind, value)
  end
end

-- 청소용 패널은 운전용 상·하 바람문 스위치와 독립된 열림/닫힘 명령으로 처리합니다.
local function panel_handler(position)
  return function(driver, device, command)
    if command.component ~= "panel" then log.error("AC_COMMAND_REJECTED wrong panel component"); return end
    worker.command(driver, device, { kind = "panel", value = position })
  end
end

local driver = Driver("samsung-ac-local", {
  discovery = discover,
  supported_capabilities = { caps.switch, caps.airConditionerMode, caps.airConditionerFanMode,
    caps.thermostatCoolingSetpoint, caps.temperatureMeasurement, caps.relativeHumidityMeasurement, caps.refresh,
    caps.dustSensor, caps.veryFineDustSensor, caps.odorSensor, caps.airQualityHealthConcern, reservation, settings, caps.doorControl,
    comfort, device_settings, care, operation },
  capability_handlers = {
    [caps.switch.ID] = { [caps.switch.commands.on.NAME] = switch_handler(true), [caps.switch.commands.off.NAME] = switch_handler(false) },
    [caps.airConditionerMode.ID] = { [caps.airConditionerMode.commands.setAirConditionerMode.NAME] = setting_handler("mode", "mode") },
    [caps.airConditionerFanMode.ID] = { [caps.airConditionerFanMode.commands.setFanMode.NAME] = setting_handler("fan", "fanMode") },
    [caps.thermostatCoolingSetpoint.ID] = { [caps.thermostatCoolingSetpoint.commands.setCoolingSetpoint.NAME] = setting_handler("setpoint", "setpoint") },
    [caps.refresh.ID] = { [caps.refresh.commands.refresh.NAME] = worker.request },
    [caps.doorControl.ID] = { [caps.doorControl.commands.open.NAME] = panel_handler("open"),
      [caps.doorControl.commands.close.NAME] = panel_handler("closed") },
    [reservation.ID] = {
      [reservation.commands.setOnDelay.NAME] = reservation_handler("onTimer", false),
      [reservation.commands.setOffDelay.NAME] = reservation_handler("offTimer", false),
      [reservation.commands.cancelOn.NAME] = reservation_handler("onTimer", true),
      [reservation.commands.cancelOff.NAME] = reservation_handler("offTimer", true),
    },
    [settings.ID] = {
      [settings.commands.setLighting.NAME] = setting_handler("lighting", "setting"),
      [settings.commands.setVoice.NAME] = setting_handler("voice", "setting"),
    },
    [comfort.ID] = {
      [comfort.commands.setPreset.NAME] = setting_handler("preset", "setting"),
      [comfort.commands.setOutlet.NAME] = setting_handler("outlet", "setting"),
      [comfort.commands.setWindfree.NAME] = menu_toggle_handler("windfree", false),
      [comfort.commands.setPurify.NAME] = menu_toggle_handler("purify", false),
    },
    [device_settings.ID] = {
      [device_settings.commands.setLighting.NAME] = setting_handler("lighting", "setting"),
      [device_settings.commands.setVoice.NAME] = setting_handler("voice", "setting"),
      [device_settings.commands.setDisplay.NAME] = menu_toggle_handler("displayOff", true),
    },
    [care.ID] = {
      [care.commands.setAutoclean.NAME] = menu_toggle_handler("autoclean", false),
      [care.commands.setPanel.NAME] = setting_handler("panel", "setting"),
    },
    -- 운전 카드만 묶고 기존 표준 capability와 동일한 검증·제어 큐를 사용합니다.
    [operation.ID] = {
      [operation.commands.setMode.NAME] = setting_handler("mode", "setting"),
      [operation.commands.setTemperature.NAME] = setting_handler("setpoint", "setpoint"),
      [operation.commands.setFan.NAME] = setting_handler("fan", "setting"),
    },
  },
  lifecycle_handlers = {
    init = function(self, device)
      local identity = device_identity(device)
      if identity then pending[identity] = nil end
      -- 설치된 기존 기기에도 추가된 청정 component와 모드 표시를 적용합니다.
      device:try_update_metadata({ profile = "samsung-ac" })
      worker.start(self, device)
    end,
    infoChanged = function(self, device) worker.start(self, device) end,
    removed = function(self, device)
      local identity = device_identity(device)
      if identity then
        pending[identity] = nil
        if self.ac_hosts then self.ac_hosts[identity] = nil end
      end
      worker.stop(self, device)
    end,
  },
})

log.info("AC_DRIVER_START " .. config.build_id)
-- 초기 검색은 IP와 무관합니다. 이후 앱의 주변 검색에서도 같은 경로를 사용합니다.
driver:call_with_delay(1, function() discover(driver) end, "ac-bootstrap")
driver:run()
