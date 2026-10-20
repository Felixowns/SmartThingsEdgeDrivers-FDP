local commands = require('commands')
-- local config = require('config')

local lifecycle_handler = {}
local log = require('log')

function lifecycle_handler.init(_, device)
  -------------------
  -- Set up scheduled
  -- services once the
  -- driver gets
  -- initialized.

  -- Refresh schedule
  log.trace('Scheduling refresh every ' .. device.preferences.interval .. ' seconds')
  device.thread:call_on_schedule(
    device.preferences.interval,
    function ()
      return commands.refresh(nil, device)
    end,
    'Refresh schedule')
end

function lifecycle_handler.infoChanged(_, device, event, args)
  -- Update device preferences
  -- and reschedule refresh
  -- schedule.
  if args.old_st_store.preferences and args.old_st_store.preferences.interval ~= device.preferences.interval then
      lifecycle_handler.removed(nil, device)
      lifecycle_handler.init(nil, device)
  end
end


function lifecycle_handler.added(driver, device)
  -- Once device has been created
  -- at API level, poll its state
  -- via refresh command and send
  -- request to share server's ip
  -- and port to the device os it
  -- can communicate back.
  commands.refresh(nil, device)
end

function lifecycle_handler.removed(_, device)
  -- Remove Schedules created under
  -- device.thread to avoid unnecessary
  -- CPU processing.
  for timer in pairs(device.thread.timers) do
    device.thread:cancel_timer(timer)
  end
end

return lifecycle_handler
