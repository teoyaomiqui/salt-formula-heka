-- Copyright 2015 Mirantis, Inc.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
require 'table'
require 'string'

local afd = require 'afd'
local consts = require 'gse_constants'
local lma = require 'lma_utils'
local interp = require "msg_interpolate"

local host_suffix_dimension_field
if read_config('host_suffix_dimension_key') then
    host_suffix_dimension_field = string.format('Fields[%s]', read_config('host_suffix_dimension_key'))
end

-- These 2 configurations are used only to encode GSE messages
local default_host = read_config('default_nagios_host')
local host_dimension_field
if read_config('nagios_host_dimension_key') then
    host_dimension_field = string.format('Fields[%s]', read_config('nagios_host_dimension_key'))
end

-- Nagios CGI cannot accept 'plugin_output' parameter greater than 1024 bytes
-- See bug #1517917 for details.
-- With the 'cmd.cgi' re-implementation for the command PROCESS_SERVICE_CHECK_RESULT,
-- this limit can be increased to 3KB. See blueprint scalable-nagios-api.
local truncate_size = (read_config('truncate_size') or 3072) + 0
local data = {
   cmd_typ = '30',
   cmd_mod = '2',
   service = nil,
   plugin_state = nil,
   plugin_output = nil,
   performance_data = '',
}
local nagios_break_line = '\\n'
-- mapping GSE statuses to Nagios states
local nagios_state_map = {
    [consts.OKAY]=0,
    [consts.WARN]=1,
    [consts.UNKW]=3,
    [consts.CRIT]=2,
    [consts.DOWN]=2
}

function url_encode(str)
  if (str) then
    str = string.gsub (str, "([^%w %-%_%.%~])",
        function (c) return string.format ("%%%02X", string.byte(c)) end)
    str = string.gsub (str, " ", "+")
  end
  return str
end

function process_message()
    local service_name = read_message('Fields[member]')
    local status = afd.get_status()
    local alarms = afd.alarms_for_human(afd.extract_alarms())

    if not service_name or not nagios_state_map[status] or not alarms then
        return -1
    end

    local host
    if host_dimension_field then
        host = read_message(host_dimension_field) or default_host
    else
        host = read_message('Fields[hostname]') or read_message('Hostname')
    end

    if host_suffix_dimension_field then
        local suffix = read_message(host_suffix_dimension_field)
        if suffix then
            host = host .. '.' .. suffix
        end
    end
    data['host'] = host

    data['service'] = service_name
    data['plugin_state'] = nagios_state_map[status]

    local details = {
        string.format('%s %s', service_name, consts.status_label(status))
    }
    if #alarms == 0 then
        details[#details+1] = 'no details'
    else
        for _, alarm in ipairs(alarms) do
            details[#details+1] = alarm
        end
    end
    data['plugin_output'] = lma.truncate(table.concat(details, nagios_break_line), truncate_size, nagios_break_line)

    local params = {}
    for k, v in pairs(data) do
        params[#params+1] = string.format("%s=%s", k, url_encode(v))
    end

    return lma.safe_inject_payload('txt', 'nagios', table.concat(params, '&'))
end