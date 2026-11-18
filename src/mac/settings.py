#!/usr/bin/env python3
# claude-notifier: добавляет или убирает хуки в ~/.claude/settings.json на Linux и в WSL, где нет Node.js.
#   python3 settings.py install|uninstall <путь к settings.json> <путь к hook.sh>
# То же, что settings.js (macOS — osascript, иначе node): чужие хуки не трогаются, рядом — settings.json.bak-<время>.
import json, os, shutil, sys, time

MARKER = '.claude-notifier/hook.sh'
SPECS = [
    ('Stop', None, 'stop', None),
    ('Notification', 'permission_prompt|elicitation_dialog|agent_needs_input', 'notification', None),
    ('StopFailure', None, 'stopfailure', None),
    ('SessionStart', None, 'sessionstart', None),
    ('UserPromptSubmit', None, 'prompt', None),
    ('SessionEnd', None, 'sessionend', None),
    ('PermissionRequest', None, 'permreq', {'timeout': 610}),
    ('Stop', None, 'replywait', {'asyncRewake': True, 'timeout': 14700}),
]


def is_ours(h):
    return isinstance(h, dict) and isinstance(h.get('command'), str) and MARKER in h['command']


def merge_hooks(settings, mode, hook_path):
    s = settings if isinstance(settings, dict) else {}
    hooks = s.get('hooks') if isinstance(s.get('hooks'), dict) else {}
    for ev in list(hooks.keys()):
        if not isinstance(hooks[ev], list):
            continue
        groups = []
        for g in hooks[ev]:
            if not isinstance(g, dict) or not isinstance(g.get('hooks'), list):
                groups.append(g)
                continue
            kept = [h for h in g['hooks'] if not is_ours(h)]
            if not kept and g['hooks']:
                continue
            g['hooks'] = kept
            groups.append(g)
        if groups:
            hooks[ev] = groups
        else:
            del hooks[ev]
    if mode == 'install':
        quoted = "'" + hook_path.replace("'", "'\\''") + "'"
        for ev, matcher, kind, opts in SPECS:
            group = {}
            if matcher:
                group['matcher'] = matcher
            hook = {'type': 'command', 'command': quoted + ' ' + kind}
            if opts:
                hook.update(opts)
            else:
                hook['async'] = True
            group['hooks'] = [hook]
            if not isinstance(hooks.get(ev), list):
                hooks[ev] = []
            hooks[ev].append(group)
    if hooks:
        s['hooks'] = hooks
    else:
        s.pop('hooks', None)
    return s


def main(argv):
    if len(argv) != 3 or argv[0] not in ('install', 'uninstall'):
        print('usage: settings.py install|uninstall <settings.json> <hook.sh>', file=sys.stderr)
        return 2
    mode, path, hook_path = argv
    settings = {}
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            text = f.read()
        if text.strip():
            try:
                settings = json.loads(text)
            except ValueError:
                print('settings.json не является корректным JSON (%s): исправьте файл и запустите установку снова' % path, file=sys.stderr)
                return 1
        shutil.copyfile(path, path + '.bak-' + time.strftime('%Y%m%d%H%M%S'))
    tmp = '%s.tmp-%d' % (path, os.getpid())
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(json.dumps(merge_hooks(settings, mode, hook_path), ensure_ascii=False, indent=2) + '\n')
    os.replace(tmp, path)
    print(('хуки добавлены в ' if mode == 'install' else 'хуки удалены из ') + path)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
