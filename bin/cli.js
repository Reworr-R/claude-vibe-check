#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const os = require("os");

const HOOK_DIR = path.resolve(__dirname);
const SETTINGS_PATH = path.join(os.homedir(), ".claude", "settings.json");

const HOOK_TIMEOUT = 30;

function readSettings() {
  if (!fs.existsSync(SETTINGS_PATH)) {
    return {};
  }
  return JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf-8"));
}

function writeSettings(settings) {
  const dir = path.dirname(SETTINGS_PATH);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");
}

function checkDependencies() {
  const platform = os.platform();
  const tools = [];

  if (platform === "linux") {
    tools.push("fswebcam", "ffmpeg");
  } else if (platform === "darwin") {
    tools.push("imagesnap", "ffmpeg");
  }

  const available = [];
  const missing = [];

  for (const tool of tools) {
    try {
      execSync(`command -v ${tool}`, { stdio: "ignore" });
      available.push(tool);
    } catch {
      missing.push(tool);
    }
  }

  return { available, missing, platform };
}

function setup() {
  console.log("\n  claude-vibe-check setup\n");

  // Check dependencies
  const deps = checkDependencies();

  if (deps.available.length === 0) {
    console.log("  No webcam capture tools found.");
    if (deps.platform === "linux") {
      console.log("  Install one of: sudo apt install fswebcam");
      console.log("                  sudo apt install ffmpeg");
    } else if (deps.platform === "darwin") {
      console.log("  Install one of: brew install imagesnap");
      console.log("                  brew install ffmpeg");
    }
    console.log("");
    process.exit(1);
  }

  console.log(`  Capture tool: ${deps.available[0]}`);
  if (deps.missing.length > 0) {
    console.log(`  Also supported (not installed): ${deps.missing.join(", ")}`);
  }

  // Make scripts executable
  try {
    fs.chmodSync(path.join(HOOK_DIR, "hook.sh"), 0o755);
    fs.chmodSync(path.join(HOOK_DIR, "capture.sh"), 0o755);
  } catch (e) {
    // Ignore permission errors on some systems
  }

  // Add hook to settings
  const settings = readSettings();

  if (!settings.hooks) {
    settings.hooks = {};
  }

  // Check if already installed
  const existingStop = settings.hooks.Stop || [];
  const alreadyInstalled = existingStop.some((entry) =>
    JSON.stringify(entry).includes("claude-vibe-check")
  );

  if (alreadyInstalled) {
    console.log("  Already installed in Claude Code settings.\n");
    return;
  }

  if (!settings.hooks.Stop) {
    settings.hooks.Stop = [];
  }

  settings.hooks.Stop.push({
    hooks: [
      {
        type: "command",
        command: `bash "${path.join(HOOK_DIR, "hook.sh")}"`,
        timeout: HOOK_TIMEOUT,
      },
    ],
  });

  writeSettings(settings);
  console.log(`  Hook added to ${SETTINGS_PATH}`);
  console.log("  claude-vibe-check is now active in Claude Code.\n");
}

function uninstall() {
  console.log("\n  claude-vibe-check uninstall\n");

  const settings = readSettings();

  if (!settings.hooks || !settings.hooks.Stop) {
    console.log("  Not installed.\n");
    return;
  }

  settings.hooks.Stop = settings.hooks.Stop.filter(
    (entry) => !JSON.stringify(entry).includes("claude-vibe-check")
  );

  if (settings.hooks.Stop.length === 0) {
    delete settings.hooks.Stop;
  }

  if (Object.keys(settings.hooks).length === 0) {
    delete settings.hooks;
  }

  writeSettings(settings);
  console.log("  Hook removed from Claude Code settings.\n");
}

function test() {
  console.log("\n  claude-vibe-check test\n");

  const deps = checkDependencies();
  console.log(`  Platform: ${deps.platform}`);
  console.log(`  Available tools: ${deps.available.join(", ") || "none"}`);
  console.log(`  Missing tools: ${deps.missing.join(", ") || "none"}`);

  if (deps.available.length === 0) {
    console.log("\n  Cannot test without capture tools.\n");
    process.exit(1);
  }

  console.log("\n  Capturing test photo...");

  try {
    const result = execSync(
      `bash "${path.join(HOOK_DIR, "capture.sh")}" /tmp/claude-vibe-check-test.jpg`,
      { encoding: "utf-8", timeout: 10000 }
    ).trim();

    if (fs.existsSync(result)) {
      const stats = fs.statSync(result);
      console.log(`  Photo saved: ${result} (${stats.size} bytes)`);
      console.log("  Webcam capture works.\n");
    } else {
      console.log("  Capture command ran but no file was produced.\n");
      process.exit(1);
    }
  } catch (e) {
    console.log(`  Capture failed: ${e.message}\n`);
    process.exit(1);
  }
}

function getConfigDir() {
  return path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config"), "claude-vibe-check");
}

function readConfig() {
  const configFile = path.join(getConfigDir(), "config");
  if (!fs.existsSync(configFile)) {
    return {};
  }
  const lines = fs.readFileSync(configFile, "utf-8").split("\n");
  const config = {};
  for (const line of lines) {
    const match = line.match(/^(\w+)=(.*)$/);
    if (match) {
      config[match[1]] = match[2].replace(/^["']|["']$/g, "");
    }
  }
  return config;
}

function writeConfig(config) {
  const configDir = getConfigDir();
  if (!fs.existsSync(configDir)) {
    fs.mkdirSync(configDir, { recursive: true });
  }
  const lines = Object.entries(config).map(([k, v]) => `${k}=${v}`);
  fs.writeFileSync(path.join(configDir, "config"), lines.join("\n") + "\n");
}

function getVenvPython() {
  const venvPy = path.join(__dirname, "..", ".venv", "bin", "python3");
  return fs.existsSync(venvPy) ? venvPy : null;
}

function checkOfflineDeps() {
  const py = getVenvPython() || "python3";
  const backends = [];
  try {
    execSync(`${py} -c 'from hsemotion_onnx.facial_emotions import HSEmotionRecognizer'`, { stdio: "ignore" });
    backends.push("hsemotion");
  } catch {}
  try {
    execSync(`${py} -c 'from fer import FER'`, { stdio: "ignore" });
    backends.push("fer");
  } catch {}
  return backends;
}

function ensureVenv() {
  const projectDir = path.join(__dirname, "..");
  const venvDir = path.join(projectDir, ".venv");
  const venvPy = path.join(venvDir, "bin", "python3");

  if (!fs.existsSync(venvPy)) {
    console.log("  Creating Python virtual environment...");
    try {
      execSync(`python3 -m venv "${venvDir}"`, { stdio: "inherit" });
    } catch (e) {
      console.log("  Failed to create venv. Make sure python3 is installed.");
      console.log(`  Error: ${e.message}\n`);
      process.exit(1);
    }
  }

  return venvPy;
}

function installOfflineDeps(backend) {
  const py = ensureVenv();

  const packages =
    backend === "hsemotion"
      ? ["hsemotion-onnx", "opencv-python-headless"]
      : ["fer", "opencv-python-headless"];

  console.log(`  Installing ${packages.join(", ")}...`);
  console.log("  This may take a minute on the first run.\n");

  try {
    execSync(`"${py}" -m pip install --quiet ${packages.join(" ")}`, {
      stdio: "inherit",
      timeout: 300000,
    });
    console.log("\n  Dependencies installed.");
  } catch (e) {
    console.log(`\n  pip install failed: ${e.message}\n`);
    process.exit(1);
  }
}

function mode(newMode, arg2) {
  const config = readConfig();

  if (!newMode) {
    console.log(`\n  Current mode: ${config.VIBE_CHECK_MODE || "online"}\n`);
    console.log("  Available modes:");
    console.log("    online   — Claude analyzes your photo directly (default)");
    console.log("    offline  — Local CV model detects emotions (private)\n");
    return;
  }

  if (!["online", "offline"].includes(newMode)) {
    console.log(`\n  Unknown mode: ${newMode}`);
    console.log("  Available: online, offline\n");
    process.exit(1);
  }

  if (newMode === "offline") {
    let backends = checkOfflineDeps();
    if (backends.length === 0) {
      console.log("\n  No offline backend found. Setting up automatically...\n");
      console.log("  Choose a backend:");
      console.log("    1) hsemotion — better accuracy, faster (~100ms)");
      console.log("    2) fer       — simpler, decent accuracy (~200ms)\n");

      const choice = arg2 || "1";
      const backend = choice === "2" || choice === "fer" ? "fer" : "hsemotion";

      installOfflineDeps(backend);
      backends = checkOfflineDeps();

      if (backends.length === 0) {
        console.log("  Installation succeeded but backend still not detected.\n");
        process.exit(1);
      }
    }
    console.log(`  Offline backends available: ${backends.join(", ")}`);
  }

  config.VIBE_CHECK_MODE = newMode;
  writeConfig(config);
  console.log(`  Mode set to: ${newMode}\n`);
}

function cooldown(seconds) {
  const config = readConfig();

  if (seconds === undefined) {
    console.log(`\n  Current cooldown: ${config.VIBE_CHECK_COOLDOWN || 60}s\n`);
    return;
  }

  const n = parseInt(seconds, 10);
  if (isNaN(n) || n < 0) {
    console.log("\n  Cooldown must be a non-negative number of seconds.\n");
    process.exit(1);
  }

  config.VIBE_CHECK_COOLDOWN = String(n);
  writeConfig(config);
  console.log(`\n  Cooldown set to: ${n}s\n`);
}

function status() {
  const settings = readSettings();
  const installed =
    settings.hooks?.Stop?.some((entry) =>
      JSON.stringify(entry).includes("claude-vibe-check")
    ) || false;

  const deps = checkDependencies();
  const config = readConfig();
  const currentMode = config.VIBE_CHECK_MODE || "online";
  const currentCooldown = config.VIBE_CHECK_COOLDOWN || "60";

  console.log("\n  claude-vibe-check status\n");
  console.log(`  Installed: ${installed ? "yes" : "no"}`);
  console.log(`  Mode: ${currentMode}`);
  console.log(`  Cooldown: ${currentCooldown}s`);
  console.log(`  Capture tools: ${deps.available.join(", ") || "none"}`);

  if (currentMode === "offline") {
    const backends = checkOfflineDeps();
    console.log(`  Offline backends: ${backends.join(", ") || "none"}`);
  }

  console.log(`  Settings: ${SETTINGS_PATH}\n`);
}

// CLI routing
const command = process.argv[2];
const arg = process.argv[3];
const arg2 = process.argv[4];

switch (command) {
  case "setup":
  case "install":
    setup();
    break;
  case "uninstall":
  case "remove":
    uninstall();
    break;
  case "test":
    test();
    break;
  case "status":
    status();
    break;
  case "mode":
    mode(arg, arg2);
    break;
  case "cooldown":
    cooldown(arg);
    break;
  default:
    console.log(`
  claude-vibe-check — webcam emotion feedback for Claude Code

  Usage:
    claude-vibe-check setup              Install the hook into Claude Code
    claude-vibe-check uninstall          Remove the hook
    claude-vibe-check test               Test webcam capture
    claude-vibe-check status             Check installation status
    claude-vibe-check mode [online|offline] [hsemotion|fer]
                                  Set analysis mode (offline auto-installs deps)
    claude-vibe-check cooldown [seconds] Set cooldown between checks
`);
}
