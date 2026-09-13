local Runtime = {}
local controller, screens

function Runtime.get(host_ui, options)
    if not controller or controller.closed then
        options = options or {}
        local root = options.root or require("datastorage"):getDataDir() .. "/bilicomics"
        controller = require("bilicomics/controller").new{ root = root, ui = host_ui }
        screens = require("bilicomics/ui/screens").new{ controller = controller }
        controller:setScreens(screens)
    elseif host_ui then controller:setHostUI(host_ui) end
    local registry = require("document/documentregistry")
    local provider = require("bilicomics/reader/document")
    if not registry.known_providers[provider.provider] then provider:register(registry) end
    return controller, screens
end

function Runtime.peek() return controller, screens end
function Runtime.close()
    if controller then controller:close() end
    controller, screens = nil, nil
end
return Runtime
