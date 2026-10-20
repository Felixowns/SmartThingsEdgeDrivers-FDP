
-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local lazy_load_if_possible = require "lazy_load_subdriver"

return {
    lazy_load_if_possible("aeotec-smart-switch"),
    lazy_load_if_possible("aeotec-heavy-duty")
}
