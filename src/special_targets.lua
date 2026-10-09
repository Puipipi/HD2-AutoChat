-- Verified target-name enrichment for special resources.
-- The six shell IDs are Spottable + ObjectiveShell entries in current RawData
-- EntityComponentMap (game version 1.007.100). They remain ordinary building
-- events and do not introduce a separate user-facing category or rule system.
local function build_special_targets()
    local rows = {
        {resource='DC19126D15692D04', name_zh='大炮 炸弹', name_en='Explosive (SEAF)'},
        {resource='6B7EE87FB2EC6455', name_zh='大炮 高爆弹', name_en='High-Yield Explosive (SEAF)'},
        {resource='E09FCB5A280ACB1D', name_zh='大炮 迷你核弹', name_en='Mini Nuke (SEAF)'},
        {resource='E4BE3FDF0C857B7F', name_zh='大炮 凝固汽油弹', name_en='Napalm (SEAF)'},
        {resource='F598598C47617605', name_zh='大炮 烟雾弹', name_en='Smoke (SEAF)'},
        {resource='C02C2623B6359BB3', name_zh='大炮 静电场', name_en='Static Field (SEAF)'},
        -- Exact-hash fallback for a user-confirmed live direct-target event:
        -- sanitized capture was kind=10, target present, resource=0ABED3586E397289,
        -- generic location key=3585962803, identity_link=true. The immediately
        -- preceding user action was the Salute drop pod mark. Static asset path:
        -- work/eagle-stingray-research/stingray-archive-list.txt:93034-93035
        -- (super_earth_cache.physics/.unit); this is a contextual fallback, not
        -- an official localized label and must not be generalized to other caches.
        {resource='0ABED3586E397289', name_zh='坠落舱', name_en='Super Earth cache'},
    }
    local by_resource = {}
    for _, row in ipairs(rows) do
        assert(row.resource:match('^[0-9A-F][0-9A-F]+$') and #row.resource == 16,
            'invalid special target resource')
        assert(not by_resource[row.resource], 'duplicate special target resource')
        by_resource[row.resource] = row
    end
    return {
        list = function() return rows end,
        resolve = function(resource)
            if type(resource) ~= 'string' then return nil end
            return by_resource[resource:upper()]
        end,
    }
end

return build_special_targets
