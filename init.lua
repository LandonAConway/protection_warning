local storage = minetest.get_mod_storage()
local data = minetest.deserialize(storage:get_string("data")) or {}

--default data
if data.use == nil then data.use = true end
data.records = data.records or {}
data.max_violations = data.max_violations or 25
data.first_timeout_amount = data.first_timeout_amount or 30 --seconds

local function save_data()
    storage:set_string("data", minetest.serialize(data))
end

minetest.register_privilege("protection_warning_bypass", {
    description = "Prevents players from receiving timeouts when violating protected areas.",
    give_to_singleplayer = false
})

local commands = {}
local function register_command(name, def)
    commands[name] = def
end

minetest.register_chatcommand("my_protection_violation_record", {
    description = "Shows a player their protection violation record.",
    func = function(name, text)
        protection_warning.show_record(name, name)
    end
})

minetest.register_chatcommand("protection_warning", {
    privs = { server = true },
    description = "Executes a command of the [protection_warning] mod.",
    params = "<cmd>",
    func = function(name, text)
        local s = string.split(text, " ")
        local cmdname = s[1]
        local subtext = table.concat({select(2, unpack(s))}, " ") or ""
        if not cmdname then return false, "Enter a command name." end
        local cmd = commands[cmdname]
        if cmd then
            return cmd.func(name, subtext)
        end
        return false, "'"..cmdname.."' is not a recognized command."
    end
})

register_command("help", {
    description = "Shows all commands under the 'protection_warning' command.",
    func = function(name, text)
        for cmdname, def in pairs(commands) do
            local params = ""
            if def.params then
                params = " "..def.params
            end
            minetest.chat_send_player(name, "'"..cmdname..params.."' --> "..(def.description or "No description."))
        end
    end
})

register_command("toggle_state", {
    description = "Toggles the usage of this mod without having to uninstall it.",
    func = function(name, text)
        data.use = not data.use
        for _, plr in pairs(minetest.get_connected_players()) do
            protection_warning.refresh_interact_priv(plr)
        end
        local state = "on"
        if not data.use then state = "off" end
        return true, "Toggled "..state.."."
    end
})

register_command("get_record", {
    description = "Gets the record of a player.",
    params = "<player>",
    func = function(name, text)
        local exists = data.records[text] ~= nil
        if exists then
            protection_warning.show_record(name, text)
            return true
        end
        return false, "No records could be found for '"..text.."'."
    end
})

local function grant_interact(name)
    local privs = minetest.get_player_privs(name)
    privs.interact = true
    minetest.set_player_privs(name, privs)
end

local function revoke_interact(name)
    local privs = minetest.get_player_privs(name)
    privs.interact = nil
    minetest.set_player_privs(name, privs)
end

register_command("clear_record", {
    description = "Clears a player's protection viotation record.",
    params = "<player>",
    func = function(name, text)
        protection_warning.clear_record(text or "")
        return true, text.."'s record has been cleared."
    end
})

register_command("set_timeout_time_left", {
    description = "Sets the time a player has left until the get interact.",
    params = "<player>",
    func = function(name, text)
        protection_warning.clear_record(text)
        return true, text.."'s record has been cleared."
    end
})

register_command("set_max_violations", {
    description = "Sets the maximum amount of violations before a player will have a timeout from interact.",
    params = "<number>",
    func = function(name, text)
        local n = tonumber(text)
        if n and n > -1 then
            data.max_violations = n
            save_data()
            return "Maximum violations set to "..text.."."
        end
        return false, "Please enter a valid number that is greater than negative one."
    end
})

--api
--note: protection_bypass priv
protection_warning = {}

function protection_warning.get_record(player)
    local name = player
    if type(name) == "userdata" then
        name = player:get_player_name()
    end
    local r = data.records[name]
    if r then
        return r
    else
        r = {
            name = name,
            timeout_time_left = 0,
            total_violations = 0,
            total_violations_slt = 0, --total violations since last timeout
            total_timeouts = 0
        }
        data.records[name] = r
        return r
    end
end

function protection_warning.clear_record(player)
    local name = player
    if type(name) == "userdata" then
        name = player:get_player_name()
    end
    if not minetest.get_player_by_name(name) then return end
    data.records[name] = nil
    grant_interact(name)
    save_data()
end

function protection_warning.show_record(showto, name)
    local record = protection_warning.get_record(name)
    local text = "Protection Violation Record:\n"..
        "Player: "..name.."\n"..
        "Timeout Time Left: "..record.timeout_time_left.."seconds\n"..
        "Total Violations: "..record.total_violations.."\n"..
        "Total Violations Since Last Timeout: "..record.total_violations_slt.."\n"..
        "Total Timeouts: "..record.total_timeouts
    minetest.chat_send_player(showto, text)
end

function protection_warning.can_bypass_timeout(player)
    local name = player
    if type(name) == "userdata" then
        name = player:get_player_name()
    end
    local privs = minetest.get_player_privs(name)
    return privs.protection_bypass or privs.protection_warning_bypass
end

function protection_warning.is_timeout_active(player)
    local name = player
    if type(name) == "userdata" then
        name = player:get_player_name()
    end
    if not data.use then return false end
    if protection_warning.can_bypass_timeout(player) then return false end
    local record = protection_warning.get_record(player)
    return record.timeout_time_left > 0
end

function protection_warning.refresh_interact_priv(player)
    local name = player
    if type(name) == "userdata" then
        name = player:get_player_name()
    end
    if protection_warning.is_timeout_active(name) then
        revoke_interact(name)
    else
        if minetest.get_player_by_name(name):get_meta():get_string("accepted_rules") == "true" then
            grant_interact(name)
        end
    end
end

minetest.register_on_protection_violation(function(pos, name)
    if data.use then
        local record = protection_warning.get_record(name)
        if protection_warning.can_bypass_timeout(name) ~= true then
            record.total_violations = record.total_violations + 1
            record.total_violations_slt = record.total_violations_slt + 1
            if record.total_violations_slt >= data.max_violations then
                if not protection_warning.is_timeout_active(name) then
                    record.total_timeouts = record.total_timeouts + 1
                end
                local time_left = data.first_timeout_amount
                for i = 1, record.total_timeouts - 1 do
                    time_left = time_left * 2
                end
                record.timeout_time_left = time_left
                revoke_interact(name)
                local text = "You will have interact taken away for "..record.timeout_time_left..
                    " seconds becuase you have violated protection too many times. Use the chat command "..
                    "'/my_protection_violation_record' for more details."
                local fs = "formspec_version[6]" ..
                "size[10.5,2.0]" ..
                "textarea[0.2,0.2;10.1,1.8;;;"..minetest.formspec_escape(text).."]"
                minetest.show_formspec(name, "protection_warning:"..name, fs)
            else
                local violations_left = data.max_violations - record.total_violations_slt
                local notmuch = 0.25 * data.max_violations
                local text = "WARNING: You have just violated a protected area or node. \nTo prevent "..
                    "interact from being taken away from you, stop violating protected areas. You have "..
                    violations_left.." attempts left.\n"..
                    "Use the chat command '/my_protection_violation_record' for more details."
                if violations_left > notmuch then
                    text = minetest.colorize("#ffcb30", text)
                else
                    text = minetest.colorize("#ff0000",  text)
                end
                minetest.chat_send_player(name, text)
            end
            save_data()
        end
    end
end)

minetest.register_globalstep(function(dtime)
    if data.use then
        for _, plr in pairs(minetest.get_connected_players()) do
            if plr then
                local record = protection_warning.get_record(plr)
                if record.timeout_time_left > 0 then
                    local new_time_left = record.timeout_time_left - dtime
                    if new_time_left <= 0 then
                        new_time_left = 0
                        record.total_violations_slt = 0
                        grant_interact(plr:get_player_name())
                    end
                    record.timeout_time_left = new_time_left
                    save_data()
                end
            end
        end
    end
end)

minetest.register_on_joinplayer(function(player)
    protection_warning.refresh_interact_priv(player)
end)