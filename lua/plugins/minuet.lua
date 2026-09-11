local DEFAULT_PROFILE = "deepseek"

-- Add a provider here once. The profile builder creates both `<provider>` and
-- `<provider>-duet` profiles when a duet backend is present.
local provider_defs = {
  deepseek = {
    api_key = "MINUET_DEEPSEEK_API",
    model = "deepseek-v4-pro",
    name = "DeepSeek",

    completion = {
      provider = "openai_fim_compatible",
      end_point = "https://api.deepseek.com/beta/completions",
      request_timeout = 3,
    },

    duet = {
      provider = "openai_compatible",
      end_point = "https://api.deepseek.com/chat/completions",
      request_timeout = 15,
      -- Keep automatic Duet requests opt-in. Add filetypes here if desired.
      auto_trigger_ft = {},
      auto_trigger_ignore_ft = {},
    },
  },
}

local function make_backend_options(def, section, fallback_name)
  return vim.tbl_deep_extend("force", {
    api_key = section.api_key or def.api_key,
    end_point = section.end_point,
    model = section.model or def.model,
    name = section.name or fallback_name,
  }, section.opts or {})
end

local function make_profile(id, def, enable_duet)
  local completion = assert(def.completion, "Missing completion config for " .. id)
  assert(completion.provider, "Missing completion provider for " .. id)
  assert(completion.end_point, "Missing completion endpoint for " .. id)

  local profile = {
    provider = completion.provider,
    request_timeout = completion.request_timeout or 3,
    provider_options = {
      [completion.provider] = make_backend_options(def, completion, def.name or id),
    },
  }

  if def.duet then
    local duet = def.duet
    assert(duet.provider, "Missing duet provider for " .. id)
    assert(duet.end_point, "Missing duet endpoint for " .. id)

    profile.duet = {
      provider = duet.provider,
      request_timeout = duet.request_timeout or 15,
      auto_trigger = {
        auto_trigger_ft = enable_duet and (duet.auto_trigger_ft or {}) or {},
        auto_trigger_ignore_ft = duet.auto_trigger_ignore_ft or {},
        enable_predicates = enable_duet and (duet.enable_predicates or {}) or {
          function()
            return false
          end,
        },
      },
      recent_edits = {
        enabled = enable_duet and (duet.recent_edits_enabled or "lazy") or false,
      },
      provider_options = {
        [duet.provider] = make_backend_options(def, duet, (def.name or id) .. " Chat"),
      },
    }
  end

  return profile
end

local provider_order = vim.tbl_keys(provider_defs)
table.sort(provider_order)

local profiles = {}
for _, id in ipairs(provider_order) do
  local def = provider_defs[id]
  profiles[id] = make_profile(id, def, false)
  if def.duet then
    profiles[id .. "-duet"] = make_profile(id, def, true)
  end
end

assert(profiles[DEFAULT_PROFILE], "Unknown default Minuet profile: " .. DEFAULT_PROFILE)

local active_profile = DEFAULT_PROFILE
vim.g.minuet_active_profile = DEFAULT_PROFILE

local function is_duet_profile(name)
  return name:sub(-5) == "-duet"
end

local function base_profile_name(name)
  return is_duet_profile(name) and name:sub(1, -6) or name
end

local function refresh_duet_state(name)
  require("minuet.duet").setup()

  local def = provider_defs[base_profile_name(name)]
  local duet = def and def.duet
  local filetypes = is_duet_profile(name) and duet and duet.auto_trigger_ft or {}
  local ignored = duet and duet.auto_trigger_ignore_ft or {}
  local filetype_enabled = vim.tbl_contains(filetypes, "*") or vim.tbl_contains(filetypes, vim.bo.filetype)

  vim.b.minuet_duet_auto_trigger = filetype_enabled and not vim.tbl_contains(ignored, vim.bo.filetype)
  vim.g.minuet_active_profile = name
end

local function set_minuet_profile(name)
  local minuet = require("minuet")
  if not minuet.presets or not minuet.presets[name] then
    vim.notify("Unknown Minuet profile: " .. tostring(name), vim.log.levels.ERROR)
    return
  end

  minuet.change_preset(name)
  active_profile = name
  refresh_duet_state(name)
  vim.notify("Minuet profile: " .. name, vim.log.levels.INFO)
end

local function toggle_minuet_profile()
  local target = is_duet_profile(active_profile) and base_profile_name(active_profile) or active_profile .. "-duet"
  set_minuet_profile(target)
end

local function select_minuet_profile()
  local names = {}
  for _, id in ipairs(provider_order) do
    names[#names + 1] = id
    if profiles[id .. "-duet"] then
      names[#names + 1] = id .. "-duet"
    end
  end

  vim.ui.select(names, {
    prompt = "Minuet profile: ",
    format_item = function(name)
      return name == active_profile and name .. " (current)" or name
    end,
  }, function(name)
    if name then
      set_minuet_profile(name)
    end
  end)
end

local function toggle_minuet_auto_complete()
  local minuet = require("minuet")
  local enabled = not minuet.config.blink.enable_auto_complete
  minuet.config.blink.enable_auto_complete = enabled
  vim.notify("Minuet auto trigger: " .. (enabled and "enabled" or "disabled"), vim.log.levels.INFO)
end

local initial_opts = vim.deepcopy(profiles[DEFAULT_PROFILE])
initial_opts.blink = {
  enable_auto_complete = false,
}
initial_opts.presets = profiles

return {
  {
    "milanglacier/minuet-ai.nvim",
    dependencies = { "saghen/blink.cmp" },
    keys = {
      {
        "<leader>as",
        toggle_minuet_auto_complete,
        mode = "n",
        desc = "Toggle Minuet auto trigger",
      },
      {
        "<leader>ad",
        toggle_minuet_profile,
        mode = "n",
        desc = "Toggle Minuet Duet profile",
      },
      {
        "<leader>ap",
        select_minuet_profile,
        mode = "n",
        desc = "Select Minuet profile",
      },
    },
    opts = initial_opts,
  },
  {
    "saghen/blink.cmp",
    opts = {
      sources = {
        -- LazyVim's opts_extend keeps the existing LSP/path/snippet/buffer
        -- sources and appends Minuet to them.
        default = { "minuet" },
        providers = {
          minuet = {
            name = "minuet",
            module = "minuet.blink",
            async = true,
            -- Follow the active profile when providers use different timeouts.
            timeout_ms = function()
              local config = require("minuet").config
              return (config and config.request_timeout or 3) * 1000
            end,
            score_offset = 50,
          },
        },
      },
      completion = {
        -- Avoid an LLM request just because a buffer was entered.
        trigger = { prefetch_on_insert = false },
      },
    },
  },
}
