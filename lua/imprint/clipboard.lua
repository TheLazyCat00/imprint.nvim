local M = {}

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
	local reason = result.stderr
	if not reason or reason == "" then
		reason = "exit code " .. tostring(result.code)
	end
	return false, reason
end
local function env_has(name)
	local value = vim.env[name]
	return value ~= nil and value ~= ""
end
function M.detect_provider()
	if vim.fn.has("mac") == 1 and vim.fn.executable("osascript") == 1 then
		return "macos"
	end
	local is_wsl = vim.fn.has("wsl") == 1
		or env_has("WSL_DISTRO_NAME")
		or env_has("WSL_INTEROP")
	if is_wsl then
		return "wsl"
	end
	if env_has("WAYLAND_DISPLAY") and vim.fn.executable("wl-copy") == 1 then
		return "wayland"
	end
	if vim.fn.executable("xclip") == 1 then
		return "x11"
	end
	if (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) and vim.fn.executable("powershell.exe") == 1 then
		return "windows"
	end
	return nil
end
function M.copy_file(file_path, provider)
	if not provider then
		return false, "no clipboard provider available"
	end
	local abs_path = vim.fn.fnamemodify(file_path, ":p")
	if provider == "wayland" then
		local uri = "file://" .. abs_path
		local ok, err = run_cmd({ "wl-copy", "--type", "text/uri-list" }, uri, 350)
		if ok then return true, nil end
		if ok == nil and err == "timeout" then return true, nil end
		return false, "wl-copy failed: " .. err
	elseif provider == "x11" then
		local uri = "file://" .. abs_path .. "\r\n"
		local ok, err = run_cmd({ "xclip", "-selection", "clipboard", "-t", "text/uri-list" }, uri, 350)
		if ok then return true, nil end
		if ok == nil and err == "timeout" then return true, nil end
		return false, "xclip failed: " .. err
	elseif provider == "macos" then
		local cmd = {
			"osascript",
			"-e",
			"on run argv",
			"-e",
			"set the clipboard to (POSIX file (item 1 of argv))",
			"-e",
			"end run",
			abs_path,
		}
		local ok, err = run_cmd(cmd)
		if ok then return true, nil end
		return false, "osascript failed: " .. err
	elseif provider == "windows" then
		local cmd = {
			"powershell.exe",
			"-NoProfile",
			"-Command",
			string.format(
				"Add-Type -AssemblyName System.Windows.Forms; " ..
				"$f = New-Object System.Collections.Specialized.StringCollection; " ..
				"$f.Add('%s') | Out-Null; " ..
				"[System.Windows.Forms.Clipboard]::SetFileDropList($f)",
				abs_path
			),
		}
		local ok, err = run_cmd(cmd)
		if ok then return true, nil end
		return false, "powershell failed: " .. err
	elseif provider == "wsl" then
		local win_path = vim.fn.system("wslpath -w " .. vim.fn.shellescape(abs_path)):gsub("\n", "")
		if not win_path or win_path == "" then
			return false, "wslpath failed to convert path"
		end
		local cmd = {
			"powershell.exe",
			"-NoProfile",
			"-Command",
			string.format(
				"Add-Type -AssemblyName System.Windows.Forms; " ..
				"$f = New-Object System.Collections.Specialized.StringCollection; " ..
				"$f.Add('%s') | Out-Null; " ..
				"[System.Windows.Forms.Clipboard]::SetFileDropList($f)",
				win_path
			),
		}
		local ok, err = run_cmd(cmd)
		if ok then return true, nil end
		return false, "powershell (wsl) failed: " .. err
	end
	return false, "unknown provider: " .. tostring(provider)
end
return M
