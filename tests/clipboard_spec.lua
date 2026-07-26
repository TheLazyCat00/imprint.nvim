package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local clipboard = require("imprint.clipboard")
local uv = vim.uv

local function assert_eq(actual, expected)
	if actual ~= expected then
		error("failed: expected " .. tostring(expected) .. ", got " .. tostring(actual))
	end
end

local function assert_match(actual, pattern)
	if type(actual) ~= "string" or not actual:find(pattern, 1, true) then
		error("failed: expected " .. tostring(actual) .. " to contain " .. pattern)
	end
end

local function with_mocks(run)
	local orig_exec = vim.fn.executable
	local orig_has = vim.fn.has
	local orig_sys = vim.system
	local orig_wayland = vim.env.WAYLAND_DISPLAY
	local orig_wsl_distro = vim.env.WSL_DISTRO_NAME
	local orig_wsl_interop = vim.env.WSL_INTEROP

	vim.env.WSL_DISTRO_NAME = nil
	vim.env.WSL_INTEROP = nil
	vim.env.WAYLAND_DISPLAY = nil

	local executable_map = {}
	local has_map = {}

	vim.fn.executable = function(name)
		return executable_map[name] or 0
	end

	vim.fn.has = function(feature)
		return has_map[feature] or 0
	end

	vim.system = function()
		return { wait = function() return { code = 0, stdout = "", stderr = "" } end }
	end

	local ctx = {
		set_has = function(feature, value)
			has_map[feature] = value and 1 or 0
		end,
		set_executable = function(name, value)
			executable_map[name] = value and 1 or 0
		end,
		set_is_mac = function(value)
			has_map["mac"] = value and 1 or 0
		end,
		set_is_wsl = function(value)
			has_map["wsl"] = value and 1 or 0
			if value then
				vim.env.WSL_DISTRO_NAME = "test-distro"
			else
				vim.env.WSL_DISTRO_NAME = nil
				vim.env.WSL_INTEROP = nil
			end
		end,
		set_wayland = function(value)
			vim.env.WAYLAND_DISPLAY = value
		end,
		set_system = function(fn)
			vim.system = fn
		end,
	}

	local ok, err = pcall(run, ctx)

	vim.fn.executable = orig_exec
	vim.fn.has = orig_has
	vim.system = orig_sys
	vim.env.WAYLAND_DISPLAY = orig_wayland
	vim.env.WSL_DISTRO_NAME = orig_wsl_distro
	vim.env.WSL_INTEROP = orig_wsl_interop

	if not ok then error(err) end
end

with_mocks(function(ctx)
	ctx.set_executable("xclip", true)
	assert_eq(clipboard.detect_provider(), "x11")
end)

with_mocks(function(ctx)
	ctx.set_executable("xclip", true)
	ctx.set_executable("wl-copy", true)
	ctx.set_wayland("wayland-1")
	assert_eq(clipboard.detect_provider(), "wayland")
end)

with_mocks(function(ctx)
	ctx.set_is_mac(true)
	ctx.set_executable("osascript", true)
	ctx.set_executable("wl-copy", true)
	ctx.set_wayland("wayland-1")
	assert_eq(clipboard.detect_provider(), "macos")
end)

with_mocks(function(ctx)
	local temp_path = vim.fn.tempname()
	local fd = assert(uv.fs_open(temp_path, "w", 420))
	assert(uv.fs_write(fd, "PNG\0DATA", 0))
	assert(uv.fs_close(fd))

	local captured = {}
	ctx.set_system(function(cmd, opts)
		captured = { cmd = cmd, opts = opts }
		return { wait = function() return { code = 0, stderr = "" } end }
	end)

	local ok, err = clipboard.copy_image(temp_path, "wayland")
	assert_eq(ok, true)
	assert_eq(err, nil)
	assert_eq(captured.cmd[1], "wl-copy")
	assert_eq(captured.cmd[2], "--type")
	assert_eq(captured.cmd[3], "image/png")
	assert_eq(captured.opts.stdin, "PNG\0DATA")
	assert_eq(captured.opts.text, false)

	vim.fn.delete(temp_path)
end)

with_mocks(function(ctx)
	local called = {}
	ctx.set_system(function(cmd)
		called = cmd
		return { wait = function() return { code = 0, stderr = "" } end }
	end)

	local ok, err = clipboard.copy_image("/tmp/test image.png", "macos")
	assert_eq(ok, true)
	assert_eq(err, nil)
	assert_eq(called[1], "osascript")
	assert_eq(called[#called], "/tmp/test image.png")
end)

with_mocks(function(ctx)
	ctx.set_is_wsl(true)
	ctx.set_executable("powershell.exe", true)
	ctx.set_executable("xclip", true)
	assert_eq(clipboard.detect_provider(), "wsl")
end)

-- interop off still selects wsl, so copy_image can explain why it fails instead
-- of quietly copying into a linux clipboard the user is not pasting from
with_mocks(function(ctx)
	ctx.set_is_wsl(true)
	ctx.set_executable("xclip", true)
	assert_eq(clipboard.detect_provider(), "wsl")
end)

with_mocks(function(ctx)
	ctx.set_has("win32", true)
	ctx.set_executable("powershell.exe", true)
	ctx.set_executable("xclip", true)
	assert_eq(clipboard.detect_provider(), "windows")
end)

with_mocks(function(ctx)
	ctx.set_is_wsl(true)
	ctx.set_executable("powershell.exe", false)

	local called = false
	ctx.set_system(function()
		called = true
		return { wait = function() return { code = 0, stdout = "", stderr = "" } end }
	end)

	local ok, err = clipboard.copy_image("/tmp/test.png", "wsl")
	assert_eq(ok, false)
	assert_eq(called, false)
	assert_match(err, "powershell.exe not found")
end)

with_mocks(function(ctx)
	ctx.set_is_wsl(true)
	ctx.set_executable("powershell.exe", true)

	local calls = {}
	ctx.set_system(function(cmd)
		table.insert(calls, cmd)
		if cmd[1] == "wslpath" then
			return {
				wait = function()
					return { code = 0, stdout = "C:\\tmp\\it's.png\n", stderr = "" }
				end,
			}
		end
		return { wait = function() return { code = 0, stdout = "", stderr = "" } end }
	end)

	local ok, err = clipboard.copy_image("/tmp/it's.png", "wsl")
	assert_eq(ok, true)
	assert_eq(err, nil)
	assert_eq(#calls, 2)
	assert_eq(calls[1][1], "wslpath")
	assert_eq(calls[1][2], "-w")
	assert_eq(calls[1][3], "/tmp/it's.png")
	assert_eq(calls[2][1], "powershell.exe")
	-- trailing newline stripped and the single quote escaped for powershell
	assert_match(calls[2][4], "FromFile('C:\\tmp\\it''s.png')")
end)

with_mocks(function(ctx)
	ctx.set_is_wsl(true)
	ctx.set_executable("powershell.exe", true)

	ctx.set_system(function(cmd)
		if cmd[1] == "wslpath" then
			return {
				wait = function()
					return { code = 1, stdout = "", stderr = "not a valid path" }
				end,
			}
		end
		error("powershell.exe should not run when wslpath fails")
	end)

	local ok, err = clipboard.copy_image("/tmp/test.png", "wsl")
	assert_eq(ok, false)
	assert_match(err, "wslpath failed: not a valid path")
end)

-- xclip forks into the background; a timeout means it took the selection
with_mocks(function(ctx)
	ctx.set_system(function()
		return { wait = function() return { code = 137, signal = 9, stderr = "" } end }
	end)

	local ok, err = clipboard.copy_image("/tmp/test.png", "x11")
	assert_eq(ok, true)
	assert_eq(err, nil)
end)

print("clipboard_spec.lua: ok")
