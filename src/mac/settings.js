// claude-notifier: добавляет или убирает хуки в ~/.claude/settings.json на Mac.
// Запуск (JavaScript for Automation, есть в каждой macOS):
//   osascript -l JavaScript settings.js install|uninstall <путь к settings.json> <путь к hook.sh>
// Чужие хуки и настройки не трогаются; перед изменением рядом сохраняется settings.json.bak-<время>.

var MARKER = '.claude-notifier/hook.sh';
var SPECS = [
  ['Stop', null, 'stop'],
  ['Notification', 'permission_prompt|elicitation_dialog|agent_needs_input', 'notification'],
  ['StopFailure', null, 'stopfailure'],
  ['SessionStart', null, 'sessionstart'],
  ['UserPromptSubmit', null, 'prompt'],
  ['SessionEnd', null, 'sessionend']
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
      group.hooks = [{ type: 'command', command: quoted + ' ' + spec[2], async: true }];
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
