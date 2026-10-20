-- 본체 OnTimer/OffTimer는 쓰지 않습니다. 예약 시각을 허브에 저장하고 전원 명령을 한 번만 요청합니다.
local log = require "log"
local M = {}
local SAVED, ACTIVE = "ac_reservations", "ac_reservation_runtime"
local KINDS = { "onTimer", "offTimer" }

local function valid_kind(kind)
  assert(kind == "onTimer" or kind == "offTimer", "unknown reservation")
end

local function store(device, kind, entry)
  local old, updated = device:get_field(SAVED) or {}, {}
  for _, name in ipairs(KINDS) do updated[name] = old[name] end
  updated[kind] = entry
  device:set_field(SAVED, updated, { persist = true })
end

local function cancel_handle(driver, context, kind)
  if context.handles[kind] then driver:cancel_timer(context.handles[kind]); context.handles[kind] = nil end
end

-- 취소·재설정·드라이버 재시작 뒤 이전 콜백이 실행돼도 전원을 건드리지 않습니다.
local function arm(driver, device, context, kind, entry)
  local remaining = entry.due - os.time()
  context.handles[kind] = driver:call_with_delay(math.max(remaining, 1), function()
    if device:get_field(ACTIVE) ~= context or (device:get_field(SAVED) or {})[kind] ~= entry then return end
    context.handles[kind] = nil
    if os.time() < entry.due then arm(driver, device, context, kind, entry); return end
    -- 명령 전 예약을 소모합니다. 통신 결과가 불확실해도 자동으로 전원 명령을 반복하지 않습니다.
    store(device, kind, nil)
    context.changed(driver, device)
    local accepted = context.command(driver, device, { kind = "power", value = kind == "onTimer" })
    log.info(accepted and "AC_RESERVATION_DISPATCHED " .. kind or "AC_RESERVATION_FAILED " .. kind)
  end, "ac-reservation-" .. kind)
end

function M.stop(driver, device)
  local context = device:get_field(ACTIVE)
  if not context then return end
  device:set_field(ACTIVE, nil)
  for _, kind in ipairs(KINDS) do cancel_handle(driver, context, kind) end
end

-- 중단 중 지나간 예약은 실행하지 않습니다. 재시작 후 뒤늦게 켜지는 일을 막습니다.
function M.start(driver, device, command, changed)
  M.stop(driver, device)
  local context = { handles = {}, command = command, changed = changed }
  device:set_field(ACTIVE, context)
  for _, kind in ipairs(KINDS) do
    local entry = (device:get_field(SAVED) or {})[kind]
    if entry ~= nil then
      if type(entry) == "table" and type(entry.due) == "number" and entry.due > os.time() then
        arm(driver, device, context, kind, entry)
      else
        store(device, kind, nil)
        log.info("AC_RESERVATION_EXPIRED " .. kind)
      end
    end
  end
end

function M.set(driver, device, kind, units)
  valid_kind(kind)
  assert(type(units) == "number" and units % 1 == 0 and units >= 0 and units <= 48,
    "예약은 취소 또는 30분~24시간 범위에서 선택해 주세요")
  local context = assert(device:get_field(ACTIVE), "reservation worker unavailable")
  local entry = units > 0 and { due = os.time() + units * 1800 } or nil
  local other = kind == "onTimer" and "offTimer" or "onTimer"
  local previous = (device:get_field(SAVED) or {})[other]
  assert(not entry or not previous or previous.due ~= entry.due, "켜짐과 꺼짐 예약을 같은 시각으로 설정할 수 없습니다")
  cancel_handle(driver, context, kind)
  store(device, kind, entry)
  if entry then arm(driver, device, context, kind, entry) end
  context.changed(driver, device)
  log.info("AC_RESERVATION_" .. (entry and "SET " or "CANCELLED ") .. kind)
end

-- UI의 30분 단위 목록에는 남은 시간을 올림해 표시합니다. 본체 예약 값과 섞지 않습니다.
function M.snapshot(device)
  local saved, result = device:get_field(SAVED) or {}, {}
  for _, kind in ipairs(KINDS) do
    local entry = saved[kind]
    result[kind] = entry and math.max(0, math.min(48, math.ceil((entry.due - os.time()) / 1800))) or 0
  end
  return result
end

return M
