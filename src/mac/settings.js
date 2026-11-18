// claude-notifier: добавляет или убирает хуки в ~/.claude/settings.json на Mac.
// Запуск (JavaScript for Automation, есть в каждой macOS):
//   osascript -l JavaScript settings.js install|uninstall <путь к settings.json> <путь к hook.sh>
// Чужие хуки и настройки не трогаются; перед изменением рядом сохраняется settings.json.bak-<время>.

var MARKER = '.claude-notifier/hook.sh';
// [событие, matcher, режим hook.sh, параметры хука]. Без параметров — асинхронный (Claude не ждёт).
// permreq — синхронный: Claude ждёт решения с ПК (у приложения Claude параллельно свой диалог, «кто первый»);
// replywait — asyncRewake: после «Готово» ждёт быстрого ответа с ПК и будит Claude, если он пришёл.
var SPECS = [
  ['Stop', null, 'stop'],
  ['Notification', 'permission_prompt|elicitation_dialog|agent_needs_input', 'notification'],
  ['StopFailure', null, 'stopfailure'],
  ['SessionStart', null, 'sessionstart'],
  ['UserPromptSubmit', null, 'prompt'],
  ['SessionEnd', null, 'sessionend'],
  ['PermissionRequest', null, 'permreq', { timeout: 610 }],
  ['Stop', null, 'replywait', { asyncRewake: true, timeout: 14700 }]
];

function isOurs(hook) {
  return !!hook && typeof hook.command === 'string' && hook.command.indexOf(MARKER) >= 0;
}

// Чистая функция: возвращает новые настройки (объект) после install/uninstall.
function mergeHooks(settings, mode, hookPath) {
  var s = settings && typeof settings === 'object' && !Array.isArray(settings) ? settings : {};
  var hooks = s.hooks && typeof s.hooks === 'object' && !Array.isArray(s.hooks) ? s.hooks : {};
  Object.keys(hooks).forEach(function (ev) {
    if (!Array.isArray(hooks[ev])) return;
    var groups = [];
    hooks[ev].forEach(function (g) {
      if (!g || !Array.isArray(g.hooks)) { groups.push(g); return; }
      var kept = g.hooks.filter(function (h) { return !isOurs(h); });
      if (kept.length === 0 && g.hooks.length > 0) return;
      g.hooks = kept;
      groups.push(g);
    });
    if (groups.length) hooks[ev] = groups; else delete hooks[ev];
  });
  if (mode === 'install') {
    var quoted = "'" + hookPath.replace(/'/g, "'\\''") + "'";
    SPECS.forEach(function (spec) {
      var group = {};
      if (spec[1]) group.matcher = spec[1];
      var hook = { type: 'command', command: quoted + ' ' + spec[2] };
      var opts = spec[3];
      if (opts) Object.keys(opts).forEach(function (k) { hook[k] = opts[k]; }); else hook.async = true;
      group.hooks = [hook];
      if (!Array.isArray(hooks[spec[0]])) hooks[spec[0]] = [];
      hooks[spec[0]].push(group);
    });
  }
  if (Object.keys(hooks).length) s.hooks = hooks; else delete s.hooks;
  return s;
}

function run(argv) {
  ObjC.import('Foundation');
  var mode = argv[0], path = argv[1], hookPath = argv[2];
  if ((mode !== 'install' && mode !== 'uninstall') || !path || !hookPath) {
    throw new Error('usage: settings.js install|uninstall <settings.json> <hook.sh>');
  }
  var fm = $.NSFileManager.defaultManager;
  var settings = {};
  if (fm.fileExistsAtPath(path)) {
    var text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null));
    if (text && text.trim()) {
      try { settings = JSON.parse(text); }
      catch (e) { throw new Error('settings.json не является корректным JSON (' + path + '): исправьте файл и запустите установку снова'); }
    }
    var stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
    fm.copyItemAtPathToPathError(path, path + '.bak-' + stamp, null);
  }
  var result = mergeHooks(settings, mode, hookPath);
  var out = $(JSON.stringify(result, null, 2) + '\n');
  if (!out.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
    throw new Error('не удалось записать ' + path);
  }
  return mode === 'install' ? 'хуки добавлены в ' + path : 'хуки удалены из ' + path;
}

if (typeof module !== 'undefined') module.exports = { mergeHooks: mergeHooks };

// Linux и WSL: тот же файл под Node.js — node settings.js install|uninstall <settings.json> <hook.sh>.
if (typeof require === 'function' && typeof module !== 'undefined' && require.main === module) {
  var fs = require('fs');
  var argv = process.argv.slice(2);
  var mode = argv[0], path = argv[1], hookPath = argv[2];
  if ((mode !== 'install' && mode !== 'uninstall') || !path || !hookPath) {
    console.error('usage: node settings.js install|uninstall <settings.json> <hook.sh>');
    process.exit(2);
  }
  var settings = {};
  if (fs.existsSync(path)) {
    var text = fs.readFileSync(path, 'utf8');
    if (text.trim()) {
      try { settings = JSON.parse(text); }
      catch (e) { console.error('settings.json не является корректным JSON (' + path + '): исправьте файл и запустите установку снова'); process.exit(1); }
    }
    var stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
    fs.copyFileSync(path, path + '.bak-' + stamp);
  }
  var tmp = path + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(mergeHooks(settings, mode, hookPath), null, 2) + '\n', 'utf8');
  fs.renameSync(tmp, path);
  console.log(mode === 'install' ? 'хуки добавлены в ' + path : 'хуки удалены из ' + path);
}
