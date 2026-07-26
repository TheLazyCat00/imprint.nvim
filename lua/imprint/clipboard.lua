local M = {}
local uv = vim.uv

local function read_binary(path)
	local fd, open_err = uv.fs_open(path, "r", 438)
	if not fd then
		return nil, "failed to open file: " .. tostring(open_err or "")
	end

	local stat, stat_err = uv.fs_fstat(fd)
	if not stat or not stat.size then
		uv.fs_close(fd)
		return nil, "failed to stat file: " .. tostring(stat_err or "")
	end

	local data, read_err = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	if not data then
		return nil, "failed to read file: " .. tostring(read_err or "")
	end
	return data, nil
end

local function run_cmd(cmd, stdin, timeout)
	local opts = { text = false }
	if stdin ~= nil then
		opts.stdin = stdin
	end
	local proc = vim.system(cmd, opts)
	local result
	if timeout ~= nil then
		result = proc:wait(timeout)
	else
		result = proc:wait()
	end
	if result == nil then
		return nil, "timeout"
	end
	if result.code == 0 then
		return true, nil
	end
	-- proc:wait(timeout) kills the process with SIGKILL once the timeout expires
	-- instead of returning nil, so surface that as a timeout too.
	if timeout ~= nil and result.signal == 9 then
		return nil, "timeout"
	end
	local reason = result.stderr
	if not reason or reason == "" then
		reason = "exit code " .. tostring(result.code)
	end
	return false, reason
end

local function capture_cmd(cmd)
	local result = vim.system(cmd, { text = true }):wait()
	if result == nil then
		return nil, "timeout"
	end
	if result.code ~= 0 then
		local reason = result.stderr
		if not reason or reason == "" then
			reason = "exit code " .. tostring(result.code)
		end
		return nil, reason
	end
	return result.stdout or "", nil
end

-- single quotes are the escape character inside a powershell single-quoted string
local function ps_quote(value)
	return (value:gsub("'", "''"))
end

local function powershell_copy_cmd(path)
	return {
		"powershell.exe",
		"-NoProfile",
		"-Command",
		string.format(
			"Add-Type -AssemblyName System.Windows.Forms,System.Drawing; "
			.. "[System.Windows.Forms.Clipboard]::SetImage([System.Drawing.Image]::FromFile('%s'))",
			ps_quote(path)
		),
	}
end

local function env_has(name)
	local value = vim.env[name]
	return value ~= nil and value ~= ""
end

local function is_wsl()
	return vim.fn.has("wsl") == 1
		or env_has("WSL_DISTRO_NAME")
		or env_has("WSL_INTEROP")
end

-- WSL reaches the Windows clipboard through Windows interop, which can be
-- turned off (`interop.enabled=false` in /etc/wsl.conf). powershell.exe is then
-- not executable at all.
function M.has_windows_interop()
	return vim.fn.executable("powershell.exe") == 1
end

function M.detect_provider()
	if vim.fn.has("mac") == 1 and vim.fn.executable("osascript") == 1 then
		return "macos"
	end
	if (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) and vim.fn.executable("powershell.exe") == 1 then
		return "windows"
	end
	-- returned even when interop is off: copy_image then reports what is wrong
	-- instead of silently falling back to a linux backend that cannot reach the
	-- Windows clipboard the user is actually pasting into.
	if is_wsl() then
		return "wsl"
	end
	if env_has("WAYLAND_DISPLAY") and vim.fn.executable("wl-copy") == 1 then
		return "wayland"
	end
	if vim.fn.executable("xclip") == 1 then
		return "x11"
	end
	return nil
end

function M.copy_image(image_path, provider)
	if not provider then
		return false, "no clipboard provider available"
	end

	if provider == "x11" then
		local ok, err = run_cmd({ "xclip", "-selection", "clipboard", "-t", "image/png", "-i", image_path }, nil, 350)
		if ok then return true, nil end
		if ok == nil and err == "timeout" then
			return true, nil
		end
		return false, "xclip failed: " .. err
	elseif provider == "wayland" then
		local data, read_err = read_binary(image_path)
		if not data then
			return false, read_err
		end
		local ok, err = run_cmd({ "wl-copy", "--type", "image/png" }, data, 350)
		if ok then return true, nil end
		if ok == nil and err == "timeout" then
			return true, nil
		end
		return false, "wl-copy failed: " .. err
	elseif provider == "macos" then
		local cmd = {
			"osascript",
			"-e",
			"on run argv",
			"-e",
			"set imagePath to POSIX file (item 1 of argv)",
			"-e",
			"set the clipboard to (read imagePath as «class PNGf»)",
			"-e",
			"end run",
			image_path,
		}
		local ok, err = run_cmd(cmd)
		if ok then return true, nil end
		return false, "osascript failed: " .. err
	elseif provider == "windows" then
		local ok, err = run_cmd(powershell_copy_cmd(image_path))
		if ok then return true, nil end
		return false, "powershell failed: " .. err
	elseif provider == "wsl" then
		if not M.has_windows_interop() then
			return false,
				"powershell.exe not found: Windows interop is disabled in this WSL distro, "
				.. "so the Windows clipboard cannot be reached (enable interop in /etc/wsl.conf)"
		end
		local out, path_err = capture_cmd({ "wslpath", "-w", image_path })
		if not out then
			return false, "wslpath failed: " .. path_err
		end
		local win_path = vim.trim(out)
		if win_path == "" then
			return false, "wslpath failed to convert path"
		end
		local ok, err = run_cmd(powershell_copy_cmd(win_path))
		if ok then return true, nil end
		return false, "powershell (wsl) failed: " .. err
	end

	return false, "err " .. tostring(provider)
end

return M
